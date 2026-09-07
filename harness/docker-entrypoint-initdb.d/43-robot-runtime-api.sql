BEGIN;
SET LOCAL ROLE robot_runtime_store;

-- current_user inside a SECURITY DEFINER function is the store role. The role
-- setting is PostgreSQL's permission-checked SET ROLE, not a custom caller GUC.
CREATE FUNCTION robot_runtime._actor() RETURNS name LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT CASE WHEN current_setting('role') = 'none' THEN session_user
              ELSE current_setting('role')::name END
$$;
CREATE FUNCTION robot_runtime._owns(p_owner name) RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp AS $$
  SELECT pg_has_role(robot_runtime._actor(), p_owner, 'USAGE')
      OR pg_has_role(robot_runtime._actor(), 'robot_runtime_admin', 'USAGE')
$$;
CREATE FUNCTION robot_runtime._can_access(p_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT FROM robot_runtime.activity_instance WHERE id = p_id AND robot_runtime._owns(owner))
$$;
CREATE FUNCTION robot_runtime._id(p_key text) RETURNS uuid LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp AS $$ SELECT md5('robot_runtime:v1:' || p_key)::uuid $$;

-- Deliberately small, recursively validated JSON Schema vocabulary. Unsupported
-- keywords fail at define time instead of being silently ignored.
CREATE FUNCTION robot_runtime._schema(p_schema jsonb, p_value jsonb, p_check boolean DEFAULT true, p_depth integer DEFAULT 0)
RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE k text; s jsonb; v jsonb; t text;
BEGIN
  IF p_depth > 16 OR jsonb_typeof(p_schema) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'invalid schema'; END IF;
  FOR k IN SELECT jsonb_object_keys(p_schema) LOOP
    IF k NOT IN ('type','properties','required','additionalProperties','items','enum','minimum','maximum','maxLength','maxItems') THEN
      RAISE EXCEPTION 'unsupported schema keyword: %', k;
    END IF;
  END LOOP;
  t := p_schema->>'type';
  IF t IS NOT NULL AND t NOT IN ('object','array','string','number','integer','boolean','null') THEN RAISE EXCEPTION 'invalid schema type'; END IF;
  IF p_schema ? 'properties' AND jsonb_typeof(p_schema->'properties') <> 'object' THEN RAISE EXCEPTION 'invalid properties'; END IF;
  IF p_schema ? 'required' AND (jsonb_typeof(p_schema->'required') <> 'array' OR
      EXISTS (SELECT FROM jsonb_array_elements(p_schema->'required') x WHERE jsonb_typeof(x) <> 'string')) THEN RAISE EXCEPTION 'invalid required'; END IF;
  IF p_schema ? 'additionalProperties' AND jsonb_typeof(p_schema->'additionalProperties') <> 'boolean' THEN RAISE EXCEPTION 'additionalProperties must be boolean'; END IF;
  IF p_schema ? 'enum' AND (jsonb_typeof(p_schema->'enum') <> 'array' OR jsonb_array_length(p_schema->'enum') = 0) THEN RAISE EXCEPTION 'invalid enum'; END IF;
  FOREACH k IN ARRAY ARRAY['minimum','maximum','maxLength','maxItems'] LOOP
    IF p_schema ? k AND jsonb_typeof(p_schema->k) <> 'number' THEN RAISE EXCEPTION 'invalid schema bound'; END IF;
    IF k IN ('maxLength','maxItems') AND p_schema ? k AND ((p_schema->>k)::numeric < 0 OR trunc((p_schema->>k)::numeric) <> (p_schema->>k)::numeric) THEN RAISE EXCEPTION 'invalid schema bound'; END IF;
  END LOOP;
  IF p_check THEN
    IF p_value IS NULL THEN RAISE EXCEPTION 'SQL NULL is not JSON'; END IF;
    IF t IS NOT NULL AND NOT (jsonb_typeof(p_value) = t OR
      (t = 'integer' AND jsonb_typeof(p_value) = 'number' AND trunc(p_value::text::numeric) = p_value::text::numeric)) THEN RAISE EXCEPTION 'schema type mismatch: expected %', t; END IF;
    IF p_schema ? 'enum' AND NOT EXISTS(SELECT FROM jsonb_array_elements(p_schema->'enum') x WHERE x=p_value) THEN RAISE EXCEPTION 'schema enum mismatch'; END IF;
    IF jsonb_typeof(p_value) = 'object' THEN
      IF EXISTS (SELECT FROM jsonb_array_elements_text(coalesce(p_schema->'required','[]')) r WHERE NOT p_value ? r) THEN RAISE EXCEPTION 'missing required property'; END IF;
      IF p_schema->'additionalProperties' = 'false'::jsonb AND EXISTS
        (SELECT FROM jsonb_object_keys(p_value) r WHERE NOT coalesce(p_schema->'properties','{}') ? r) THEN RAISE EXCEPTION 'unexpected property'; END IF;
    ELSIF jsonb_typeof(p_value) = 'number' THEN
      IF p_value::text::numeric < (p_schema->>'minimum')::numeric OR p_value::text::numeric > (p_schema->>'maximum')::numeric THEN RAISE EXCEPTION 'number outside schema bounds'; END IF;
    ELSIF jsonb_typeof(p_value) = 'string' THEN
      IF length(p_value #>> '{}') > (p_schema->>'maxLength')::integer THEN RAISE EXCEPTION 'string too long'; END IF;
    ELSIF jsonb_typeof(p_value) = 'array' THEN
      IF jsonb_array_length(p_value) > (p_schema->>'maxItems')::integer THEN RAISE EXCEPTION 'array too long'; END IF;
    END IF;
  END IF;
  FOR k,s IN SELECT * FROM jsonb_each(coalesce(p_schema->'properties','{}')) LOOP
    PERFORM robot_runtime._schema(s, p_value->k, p_check AND jsonb_typeof(p_value) = 'object' AND p_value ? k, p_depth+1);
  END LOOP;
  IF p_schema ? 'items' THEN
    PERFORM robot_runtime._schema(p_schema->'items', NULL, false, p_depth+1);
    IF p_check AND jsonb_typeof(p_value) = 'array' THEN
      FOR v IN SELECT * FROM jsonb_array_elements(p_value) LOOP PERFORM robot_runtime._schema(p_schema->'items',v,true,p_depth+1); END LOOP;
    END IF;
  END IF;
END $$;

CREATE FUNCTION robot_runtime.define(p_name text, p_version integer, p_reducer regprocedure,
  p_initial_state jsonb, p_contract jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p record; c jsonb; k text; v jsonb; lim robot_runtime.settings; old robot_runtime.activity_definition;
BEGIN
  SELECT * INTO lim FROM robot_runtime.settings;
  IF p_initial_state IS NULL OR octet_length(p_initial_state::text) > lim.max_payload_bytes
    OR p_contract IS NULL OR octet_length(p_contract::text) > lim.max_payload_bytes OR jsonb_typeof(p_contract) <> 'object' THEN RAISE EXCEPTION 'invalid or oversized definition'; END IF;
  SELECT f.*, n.nspname, r.rolname, r.rolsuper, r.rolbypassrls INTO p
    FROM pg_proc f JOIN pg_namespace n ON n.oid=f.pronamespace JOIN pg_roles r ON r.oid=f.proowner WHERE f.oid=p_reducer;
  IF NOT FOUND OR p.pronargs <> 3 OR p.proargtypes[0] <> 'jsonb'::regtype
    OR p.proargtypes[1] <> 'robot_runtime.intent'::regtype OR p.proargtypes[2] <> 'robot_runtime.reduce_context'::regtype
    OR p.prorettype <> 'robot_runtime.transition'::regtype OR p.proretset OR p.provolatile <> 'i'
    OR NOT p.prosecdef OR p.rolsuper OR p.rolbypassrls OR p.rolname LIKE 'robot_runtime_%'
    OR NOT coalesce(p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp'],false)
    OR NOT has_function_privilege('robot_runtime_store',p_reducer,'EXECUTE') THEN
    RAISE EXCEPTION 'reducer must be an approved IMMUTABLE SECURITY DEFINER function with the runtime signature, safe search_path and an unprivileged owner';
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_contract) LOOP
    IF k NOT IN ('intents','state_schema','max_payload_bytes','max_mailbox','max_effects','max_timers','max_rate') THEN RAISE EXCEPTION 'unsupported contract key: %',k; END IF;
  END LOOP;
  c := jsonb_build_object('intents','{}'::jsonb,'state_schema','{}'::jsonb,
    'max_payload_bytes',lim.max_payload_bytes,'max_mailbox',lim.max_mailbox,
    'max_effects',lim.max_effects,'max_timers',lim.max_timers,'max_rate',lim.max_rate) || p_contract;
  FOREACH k IN ARRAY ARRAY['max_payload_bytes','max_mailbox','max_effects','max_timers','max_rate'] LOOP
    IF (c->>k)::integer < 1 OR (c->>k)::integer > (to_jsonb(lim)->>k)::integer THEN RAISE EXCEPTION 'contract exceeds global limit: %',k; END IF;
  END LOOP;
  PERFORM robot_runtime._schema(c->'state_schema',p_initial_state);
  IF jsonb_typeof(c->'intents') <> 'object' THEN RAISE EXCEPTION 'intents must be an object'; END IF;
  FOR k,v IN SELECT * FROM jsonb_each(c->'intents') LOOP
    IF k ~ '^(lifecycle|timer|effect)\.' OR length(k) NOT BETWEEN 1 AND 128 OR jsonb_typeof(v) <> 'object' THEN RAISE EXCEPTION 'invalid intent contract'; END IF;
    IF EXISTS (SELECT FROM jsonb_object_keys(v) x WHERE x NOT IN ('schema','delivery','replace_key','priority','adapters')) THEN RAISE EXCEPTION 'unsupported intent option'; END IF;
    IF v ? 'adapters' AND (jsonb_typeof(v->'adapters') <> 'array' OR jsonb_array_length(v->'adapters')>64
      OR EXISTS(SELECT FROM jsonb_array_elements(v->'adapters') x WHERE jsonb_typeof(x)<>'string')) THEN RAISE EXCEPTION 'invalid adapter allowlist'; END IF;
    IF coalesce(v->>'delivery','fifo') NOT IN ('fifo','latest','reject_if_busy') THEN RAISE EXCEPTION 'invalid intent delivery'; END IF;
    IF v->>'delivery' = 'latest' AND nullif(v->>'replace_key','') IS NULL THEN RAISE EXCEPTION 'latest delivery needs replace_key'; END IF;
    IF coalesce((v->>'priority')::integer,0) NOT BETWEEN -100 AND 100 THEN RAISE EXCEPTION 'invalid priority'; END IF;
    PERFORM robot_runtime._schema(coalesce(v->'schema','{}'),NULL,false);
  END LOOP;
  SELECT * INTO old FROM robot_runtime.activity_definition WHERE name=p_name AND version=p_version;
  IF FOUND THEN
    IF old.reducer <> p_reducer OR old.reducer_fingerprint <> md5(pg_get_functiondef(p_reducer)) OR old.initial_state <> p_initial_state OR old.contract <> c THEN RAISE EXCEPTION 'definition versions are immutable'; END IF;
  ELSE
    INSERT INTO robot_runtime.activity_definition VALUES (p_name,p_version,p_reducer,
      format('%I.%I(jsonb,robot_runtime.intent,robot_runtime.reduce_context)',p.nspname,p.proname),
      md5(pg_get_functiondef(p_reducer)),p.rolname,p_initial_state,c,clock_timestamp());
  END IF;
  RETURN jsonb_build_object('name',p_name,'version',p_version);
END $$;

-- Caller holds the activity row lock. Internal source is never client supplied.
CREATE FUNCTION robot_runtime._enqueue(p_id uuid, p_generation bigint, p_kind text, p_payload jsonb,
  p_source text, p_message uuid, p_observed timestamptz DEFAULT NULL, p_expires timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance; d robot_runtime.activity_definition; i robot_runtime.activity_inbox;
  cfg jsonb; req jsonb; policy text := 'fifo'; key text; pri smallint := 0; reason text;
  stamp timestamptz := clock_timestamp(); internal boolean := p_source LIKE 'runtime:%'; lim robot_runtime.settings;
BEGIN
  SELECT * INTO STRICT a FROM robot_runtime.activity_instance WHERE id=p_id FOR UPDATE;
  SELECT * INTO STRICT d FROM robot_runtime.activity_definition WHERE name=a.definition_name AND version=a.definition_version;
  SELECT * INTO lim FROM robot_runtime.settings;
  IF p_payload IS NULL OR octet_length(p_payload::text) > least((d.contract->>'max_payload_bytes')::integer,lim.max_payload_bytes)
    OR p_kind IS NULL OR length(p_kind) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'invalid or oversized intent'; END IF;
  req := jsonb_build_object('generation',p_generation,'kind',p_kind,'payload',p_payload,'observed_at',extract(epoch FROM p_observed),'expires_at',extract(epoch FROM p_expires));
  SELECT * INTO i FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND source=p_source AND message_id=p_message;
  IF FOUND THEN
    IF i.request <> req THEN RAISE EXCEPTION 'message_id reused with different content'; END IF;
    RETURN jsonb_build_object('intent_id',i.id,'message_id',i.message_id,'status',i.status,'duplicate',true);
  END IF;
  IF p_kind IN ('lifecycle.start','lifecycle.pause','lifecycle.resume','lifecycle.stop','lifecycle.fault') THEN
    IF p_expires IS NOT NULL THEN RAISE EXCEPTION 'lifecycle barriers cannot expire'; END IF;
    policy := 'barrier'; pri := CASE p_kind WHEN 'lifecycle.fault' THEN 1003 WHEN 'lifecycle.stop' THEN 1002 ELSE 1001 END;
  ELSIF internal THEN pri := 500;
  ELSE
    cfg := d.contract->'intents'->p_kind;
    IF cfg IS NULL THEN RAISE EXCEPTION 'intent kind is not allowed'; END IF;
    PERFORM robot_runtime._schema(coalesce(cfg->'schema','{}'),p_payload);
    policy := coalesce(cfg->>'delivery','fifo'); pri := coalesce((cfg->>'priority')::smallint,0);
    key := CASE WHEN policy='latest' THEN p_kind || ':' || (cfg->>'replace_key') END;
  END IF;
  IF p_generation IS DISTINCT FROM a.generation THEN reason := 'stale';
  ELSIF p_expires <= stamp THEN reason := 'expired';
  ELSIF a.lifecycle IN ('stopped','faulted','stopping') THEN reason := 'rejected';
  ELSIF p_kind='lifecycle.resume' AND a.lifecycle <> 'paused' THEN reason := 'rejected';
  ELSIF p_kind='lifecycle.pause' AND a.lifecycle <> 'active' THEN reason := 'rejected';
  ELSIF a.barrier_pending AND policy <> 'barrier' AND NOT internal THEN reason := 'rejected';
  END IF;
  IF reason IS NULL AND NOT internal AND policy <> 'barrier' THEN
    IF a.rate_window + interval '1 second' <= stamp THEN a.rate_count:=0; a.rate_window:=stamp; END IF;
    a.rate_count := a.rate_count+1;
    UPDATE robot_runtime.activity_instance SET rate_count=a.rate_count,rate_window=a.rate_window WHERE id=p_id;
    IF a.rate_count > least((d.contract->>'max_rate')::integer,lim.max_rate) THEN reason:='rejected'; END IF;
  END IF;
  IF reason IS NULL AND policy='latest' THEN
    UPDATE robot_runtime.activity_inbox SET status='superseded',processed_at=stamp WHERE activity_id=p_id AND status='pending' AND replace_key=key;
  END IF;
  IF reason IS NULL AND policy='barrier' THEN
    -- Stop/fault can preempt pause/resume. A second pause cannot erase stop.
    IF EXISTS (SELECT FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND status='pending' AND priority>pri) THEN reason:='rejected';
    ELSE
      UPDATE robot_runtime.activity_inbox SET status='superseded',processed_at=stamp WHERE activity_id=p_id AND status='pending' AND priority<=pri;
      UPDATE robot_runtime.activity_instance SET barrier_pending=(p_kind<>'lifecycle.start'),
        effect_epoch=effect_epoch+CASE WHEN p_kind IN ('lifecycle.pause','lifecycle.stop','lifecycle.fault') THEN 1 ELSE 0 END WHERE id=p_id;
      IF p_kind IN ('lifecycle.pause','lifecycle.stop','lifecycle.fault') THEN
        UPDATE robot_runtime.effect_outbox SET status='cancelled' WHERE activity_id=p_id AND status IN ('pending','claimed');
        UPDATE robot_runtime.activity_timer SET status='cancelled' WHERE activity_id=p_id AND status='pending';
      END IF;
    END IF;
  END IF;
  IF reason IS NULL AND policy <> 'barrier' AND NOT internal AND
    (SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND status='pending') >=
      (CASE WHEN policy='reject_if_busy' THEN 1 ELSE least((d.contract->>'max_mailbox')::integer,lim.max_mailbox) END) THEN reason:='rejected'; END IF;
  -- Internal completions/timers have a separate bounded reserve. Never lose a
  -- completion just because ordinary traffic fills the user mailbox.
  IF reason IS NULL AND internal AND policy <> 'barrier' AND
    (SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND status='pending' AND source LIKE 'runtime:%') >= lim.max_effects+lim.max_timers THEN
    RAISE EXCEPTION 'internal mailbox full' USING ERRCODE='54000';
  END IF;
  IF reason IS NOT NULL THEN
    UPDATE robot_runtime.activity_instance SET rejected_count=rejected_count+1,last_rejection=reason,last_rejected_at=stamp WHERE id=p_id;
    -- Rejected messages were never accepted: retain no payload or dedup identity.
    -- A bounded, payload-free trail plus counters makes overload observable
    -- without letting rejected traffic allocate an unbounded second mailbox.
    IF a.last_rejected_at IS NULL OR a.last_rejected_at<stamp-interval '1 second' OR a.last_rejection IS DISTINCT FROM reason THEN
      INSERT INTO robot_runtime.dead_letter(activity_id,reason) VALUES(p_id,reason);
      DELETE FROM robot_runtime.dead_letter WHERE id IN (SELECT id FROM robot_runtime.dead_letter
        WHERE activity_id=p_id AND intent_id IS NULL AND effect_id IS NULL ORDER BY id DESC OFFSET 16);
    END IF;
    RETURN jsonb_build_object('intent_id',NULL,'message_id',p_message,'status',reason,'duplicate',false);
  END IF;
  UPDATE robot_runtime.activity_instance SET next_sequence=next_sequence+1 WHERE id=p_id RETURNING next_sequence INTO a.next_sequence;
  INSERT INTO robot_runtime.activity_inbox(activity_id,generation,sequence,source,message_id,kind,payload,request,observed_at,expires_at,priority,delivery,replace_key,status)
    VALUES(p_id,p_generation,a.next_sequence,p_source,p_message,p_kind,p_payload,req,coalesce(p_observed,stamp),p_expires,pri,policy,key,coalesce(reason,'pending')) RETURNING * INTO i;
  IF reason IS NOT NULL THEN INSERT INTO robot_runtime.dead_letter(activity_id,intent_id,reason) VALUES(p_id,i.id,reason); END IF;
  RETURN jsonb_build_object('intent_id',i.id,'message_id',i.message_id,'status',i.status,'duplicate',false);
END $$;

CREATE FUNCTION robot_runtime.start(p_name text, p_version integer DEFAULT NULL, p_input jsonb DEFAULT '{}',
  p_label text DEFAULT NULL, p_idempotency_key uuid DEFAULT NULL) RETURNS robot_runtime.activity_ref
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE d robot_runtime.activity_definition; a robot_runtime.activity_instance; key uuid:=coalesce(p_idempotency_key,gen_random_uuid()); req jsonb;
BEGIN
  req:=jsonb_build_object('name',p_name,'version',p_version,'input',p_input,'label',p_label);
  -- Serializes retries even before an activity row exists. Hash collisions only
  -- serialize unrelated starts; the unique constraint defines real identity.
  PERFORM pg_advisory_xact_lock(hashtextextended(robot_runtime._actor()::text || ':' || key::text,0));
  SELECT * INTO a FROM robot_runtime.activity_instance WHERE started_by=robot_runtime._actor() AND idempotency_key=key;
  IF FOUND THEN
    IF a.start_request <> req THEN RAISE EXCEPTION 'idempotency_key reused with different content'; END IF;
    RETURN (a.id,a.generation)::robot_runtime.activity_ref;
  END IF;
  SELECT * INTO d FROM robot_runtime.activity_definition WHERE name=p_name AND (p_version IS NULL OR version=p_version) ORDER BY version DESC LIMIT 1;
  IF NOT FOUND OR NOT robot_runtime._owns(d.owner) THEN RAISE EXCEPTION 'definition unavailable' USING ERRCODE='42501'; END IF;
  IF length(p_label)>256 THEN RAISE EXCEPTION 'label too long'; END IF;
  INSERT INTO robot_runtime.activity_instance(definition_name,definition_version,owner,started_by,idempotency_key,start_request,label,state)
    VALUES(d.name,d.version,d.owner,robot_runtime._actor(),key,req,p_label,d.initial_state) RETURNING * INTO a;
  PERFORM robot_runtime._enqueue(a.id,1,'lifecycle.start',p_input,'runtime:start',key);
  RETURN (a.id,1)::robot_runtime.activity_ref;
END $$;
CREATE FUNCTION robot_runtime.send(p_activity robot_runtime.activity_ref, p_kind text, p_payload jsonb DEFAULT '{}',
  p_message_id uuid DEFAULT NULL, p_observed_at timestamptz DEFAULT NULL, p_expires_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT robot_runtime._can_access(p_activity.activity_id) THEN RAISE EXCEPTION 'activity unavailable' USING ERRCODE='42501'; END IF;
  IF p_kind ~ '^(effect|timer)\.' OR (p_kind LIKE 'lifecycle.%' AND p_kind NOT IN ('lifecycle.pause','lifecycle.resume','lifecycle.stop','lifecycle.fault')) THEN RAISE EXCEPTION 'reserved intent kind'; END IF;
  RETURN robot_runtime._enqueue(p_activity.activity_id,p_activity.generation,p_kind,p_payload,
    'user:' || robot_runtime._actor(),coalesce(p_message_id,gen_random_uuid()),p_observed_at,p_expires_at);
END $$;
CREATE FUNCTION robot_runtime.inspect(p_activity_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE result jsonb;
BEGIN
  IF NOT robot_runtime._can_access(p_activity_id) THEN RAISE EXCEPTION 'activity unavailable' USING ERRCODE='42501'; END IF;
  SELECT to_jsonb(a)-'start_request' || jsonb_build_object('mailbox_depth',
    (SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=a.id AND status='pending')) INTO result FROM robot_runtime.activity_instance a WHERE id=p_activity_id;
  RETURN result;
END $$;
COMMIT;
