BEGIN;
SET LOCAL ROLE robot_runtime_store;

CREATE FUNCTION robot_runtime._cancel(p_id uuid) RETURNS void LANGUAGE sql
SET search_path = pg_catalog, pg_temp AS $$
  UPDATE robot_runtime.effect_outbox SET status='cancelled' WHERE activity_id=p_id AND status IN ('pending','claimed');
  UPDATE robot_runtime.activity_timer SET status='cancelled' WHERE activity_id=p_id AND status='pending';
$$;
CREATE FUNCTION robot_runtime._effect_result(p_effect uuid, p_status text, p_result jsonb DEFAULT '{}') RETURNS void
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE e robot_runtime.effect_outbox; a robot_runtime.activity_instance;
BEGIN
  SELECT * INTO STRICT e FROM robot_runtime.effect_outbox WHERE id=p_effect;
  SELECT * INTO STRICT a FROM robot_runtime.activity_instance WHERE id=e.activity_id;
  UPDATE robot_runtime.effect_outbox SET status=p_status,outcome=p_result WHERE id=e.id;
  IF a.generation=e.generation AND a.effect_epoch=e.effect_epoch AND NOT a.barrier_pending AND a.lifecycle IN ('active','paused') THEN
    PERFORM robot_runtime._enqueue(a.id,a.generation,
      CASE WHEN p_status='succeeded' THEN 'effect.succeeded' WHEN p_status IN ('expired','timed_out') THEN 'effect.timed_out' ELSE 'effect.failed' END,
      jsonb_build_object('effect_id',e.id,'outcome',p_status,'result',p_result),'runtime:effect',
      CASE WHEN p_status='ambiguous' THEN robot_runtime._id(e.id::text||':ambiguous') ELSE e.id END);
  END IF;
END $$;

CREATE FUNCTION robot_runtime._maintain(p_id uuid) RETURNS boolean LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance; t robot_runtime.activity_timer; e robot_runtime.effect_outbox;
  stamp timestamptz:=clock_timestamp(); worked boolean:=false; result text;
BEGIN
  SELECT * INTO STRICT a FROM robot_runtime.activity_instance WHERE id=p_id;
  FOR t IN SELECT * FROM robot_runtime.activity_timer WHERE activity_id=p_id AND status='pending' AND due_at<=stamp ORDER BY due_at,timer_id LIMIT 32 LOOP
    EXIT WHEN (SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND status='pending' AND source LIKE 'runtime:%') >=
      (SELECT max_effects+max_timers FROM robot_runtime.settings);
    IF t.generation=a.generation AND a.lifecycle='active' AND NOT a.barrier_pending THEN
      PERFORM robot_runtime._enqueue(p_id,t.generation,'timer.fired',jsonb_build_object('timer_id',t.timer_id,'payload',t.payload),
        'runtime:timer',robot_runtime._id(p_id::text||':'||t.generation||':timer:'||t.timer_id),t.due_at);
      UPDATE robot_runtime.activity_timer SET status='fired' WHERE activity_id=p_id AND generation=t.generation AND timer_id=t.timer_id;
    ELSE
      UPDATE robot_runtime.activity_timer SET status='cancelled' WHERE activity_id=p_id AND generation=t.generation AND timer_id=t.timer_id;
    END IF;
    worked:=true;
  END LOOP;
  FOR e IN SELECT * FROM robot_runtime.effect_outbox WHERE activity_id=p_id AND status IN ('pending','claimed')
    AND (expires_at<=stamp OR deadline_at<=stamp OR (status='claimed' AND claim_expires_at<=stamp)) ORDER BY id LIMIT 32 LOOP
    EXIT WHEN (SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=p_id AND status='pending' AND source LIKE 'runtime:%') >=
      (SELECT max_effects+max_timers FROM robot_runtime.settings);
    IF e.deadline_at<=stamp THEN result:='timed_out';
    ELSIF e.expires_at<=stamp THEN result:='expired';
    ELSIF e.retry_class='idempotent' THEN result:='pending';
    ELSE result:='ambiguous'; END IF;
    INSERT INTO robot_runtime.effect_attempt(effect_id,claim_token,gateway,fence,outcome) VALUES(e.id,e.claim_token,e.gateway,e.fence,result);
    IF result='pending' THEN
      UPDATE robot_runtime.effect_outbox SET status='pending',claim_token=NULL,claim_expires_at=NULL WHERE id=e.id;
    ELSE PERFORM robot_runtime._effect_result(e.id,result); END IF;
    worked:=true;
  END LOOP;
  RETURN worked;
END $$;

CREATE FUNCTION robot_runtime._apply(p_activity robot_runtime.activity_instance, p_intent robot_runtime.activity_inbox,
  p_transition robot_runtime.transition) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance:=p_activity; i robot_runtime.activity_inbox:=p_intent;
  d robot_runtime.activity_definition; lim robot_runtime.settings; tr robot_runtime.transition:=p_transition;
  item jsonb; ids uuid[]:='{}'; eid uuid; idx integer:=0; life text; scope text; v_delivery text; timer_key text;
  exp timestamptz; deadline timestamptz; due timestamptz; cap integer; k text;
BEGIN
  SELECT * INTO d FROM robot_runtime.activity_definition WHERE name=a.definition_name AND version=a.definition_version;
  SELECT * INTO lim FROM robot_runtime.settings;
  cap:=least(lim.max_payload_bytes,(d.contract->>'max_payload_bytes')::integer);
  IF tr.new_state IS NULL OR octet_length(to_jsonb(tr)::text)>cap THEN RAISE EXCEPTION 'invalid or oversized transition'; END IF;
  PERFORM robot_runtime._schema(d.contract->'state_schema',tr.new_state);
  tr.effects:=coalesce(tr.effects,'[]'); tr.timers:=coalesce(tr.timers,'[]'); tr.events:=coalesce(tr.events,'[]');
  IF jsonb_typeof(tr.effects)<>'array' OR jsonb_typeof(tr.timers)<>'array' OR jsonb_typeof(tr.events)<>'array' THEN RAISE EXCEPTION 'transition collections must be arrays'; END IF;
  IF jsonb_array_length(tr.effects)>least(lim.max_effects,(d.contract->>'max_effects')::integer)
    OR jsonb_array_length(tr.timers)>least(lim.max_timers,(d.contract->>'max_timers')::integer) OR jsonb_array_length(tr.events)>32 THEN RAISE EXCEPTION 'transition quota exceeded'; END IF;
  life:=CASE i.kind WHEN 'lifecycle.start' THEN 'active' WHEN 'lifecycle.pause' THEN 'paused'
    WHEN 'lifecycle.resume' THEN 'active' WHEN 'lifecycle.stop' THEN 'stopped' WHEN 'lifecycle.fault' THEN 'faulted' ELSE a.lifecycle END;
  IF tr.next_lifecycle IS NOT NULL THEN
    IF i.kind LIKE 'lifecycle.%' AND tr.next_lifecycle<>life THEN RAISE EXCEPTION 'reducer cannot override lifecycle intent'; END IF;
    IF i.kind NOT LIKE 'lifecycle.%' AND tr.next_lifecycle NOT IN (a.lifecycle,'stopped','faulted') THEN RAISE EXCEPTION 'invalid lifecycle transition'; END IF;
    life:=tr.next_lifecycle;
  END IF;
  IF i.kind='lifecycle.resume' THEN a.generation:=a.generation+1; a.effect_epoch:=a.effect_epoch+1; END IF;
  IF life IN ('stopped','faulted') AND i.kind NOT IN ('lifecycle.stop','lifecycle.fault') THEN
    a.effect_epoch:=a.effect_epoch+1; PERFORM robot_runtime._cancel(a.id);
  END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(tr.effects) LOOP
    IF jsonb_typeof(item)<>'object' THEN RAISE EXCEPTION 'effect must be an object'; END IF;
    FOR k IN SELECT jsonb_object_keys(item) LOOP
      IF k NOT IN ('adapter','protocol_version','capability','resource_key','operation','payload','lane','delivery','replace_key','priority','expires_at','deadline_at','retry_class','scope') THEN RAISE EXCEPTION 'unknown effect field: %',k; END IF;
    END LOOP;
    FOREACH k IN ARRAY ARRAY['adapter','capability','resource_key','operation'] LOOP
      IF coalesce(length(item->>k),0) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'missing or invalid effect field: %',k; END IF;
    END LOOP;
    scope:=coalesce(item->>'scope','ordinary'); v_delivery:=coalesce(item->>'delivery','fifo');
    IF life='paused' OR (life IN ('stopped','faulted') AND scope<>(CASE life WHEN 'stopped' THEN 'stop' ELSE 'fault' END))
      OR (life='active' AND scope<>'ordinary') THEN RAISE EXCEPTION 'effect not allowed in lifecycle %',life; END IF;
    exp:=(item->>'expires_at')::timestamptz; deadline:=(item->>'deadline_at')::timestamptz;
    IF scope<>'ordinary' THEN
      IF deadline IS NULL OR deadline>i.accepted_at+interval '5 seconds' THEN RAISE EXCEPTION 'stop/fault effects require a deadline within five seconds'; END IF;
    END IF;
    IF v_delivery='latest_wins' AND nullif(item->>'replace_key','') IS NULL THEN RAISE EXCEPTION 'latest_wins needs replace_key'; END IF;
    IF coalesce((item->>'priority')::integer,0) NOT BETWEEN -100 AND 100 THEN RAISE EXCEPTION 'invalid effect priority'; END IF;
    IF NOT EXISTS (SELECT FROM robot_runtime.adapter_registration WHERE name=item->>'adapter'
      AND coalesce((item->>'protocol_version')::integer,1)=ANY(protocol_versions) AND item->>'capability'=ANY(capabilities)) THEN RAISE EXCEPTION 'unsupported adapter protocol or capability'; END IF;
    IF v_delivery IN ('latest_wins','barrier') THEN
      UPDATE robot_runtime.effect_outbox SET status='cancelled' WHERE activity_id=a.id AND status='pending'
        AND adapter=item->>'adapter' AND lane=coalesce(item->>'lane','default')
        AND (v_delivery='barrier' AND priority<=coalesce((item->>'priority')::smallint,0) OR replace_key=item->>'replace_key');
    END IF;
    idx:=idx+1; eid:=robot_runtime._id(a.id::text||':'||a.generation||':'||(a.revision+1)||':effect:'||idx); ids:=array_append(ids,eid);
    INSERT INTO robot_runtime.effect_outbox(id,activity_id,generation,effect_epoch,revision,effect_index,
      adapter,protocol_version,capability,resource_key,operation,payload,lane,delivery,replace_key,priority,scope,expires_at,deadline_at,retry_class)
    VALUES(eid,a.id,a.generation,a.effect_epoch,a.revision+1,idx,item->>'adapter',coalesce((item->>'protocol_version')::integer,1),
      item->>'capability',item->>'resource_key',item->>'operation',coalesce(item->'payload','{}'),coalesce(item->>'lane','default'),
      v_delivery,item->>'replace_key',coalesce((item->>'priority')::smallint,0),scope,exp,deadline,coalesce(item->>'retry_class','never'));
  END LOOP;
  FOR item IN SELECT * FROM jsonb_array_elements(tr.timers) LOOP
    IF jsonb_typeof(item)<>'object' OR EXISTS (SELECT FROM jsonb_object_keys(item) x WHERE x NOT IN ('timer_id','due_at','payload','cancel')) THEN RAISE EXCEPTION 'invalid timer'; END IF;
    timer_key:=item->>'timer_id';
    IF coalesce(length(timer_key),0) NOT BETWEEN 1 AND 128 THEN RAISE EXCEPTION 'invalid timer_id'; END IF;
    IF coalesce((item->>'cancel')::boolean,false) THEN
      UPDATE robot_runtime.activity_timer SET status='cancelled' WHERE activity_id=a.id AND generation=a.generation AND timer_id=timer_key AND status='pending';
    ELSE
      IF life<>'active' THEN RAISE EXCEPTION 'timers require active lifecycle'; END IF;
      due:=(item->>'due_at')::timestamptz;
      -- IDs identify one logical firing per generation. Pending timers may be
      -- rescheduled; a fired/cancelled ID cannot silently create a second firing.
      INSERT INTO robot_runtime.activity_timer(activity_id,generation,timer_id,due_at,payload)
        VALUES(a.id,a.generation,timer_key,due,coalesce(item->'payload','{}'))
      ON CONFLICT(activity_id,generation,timer_id) DO UPDATE SET due_at=excluded.due_at,payload=excluded.payload
        WHERE robot_runtime.activity_timer.status='pending';
      IF NOT FOUND THEN RAISE EXCEPTION 'timer_id already consumed'; END IF;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM robot_runtime.effect_outbox WHERE activity_id=a.id AND status IN ('pending','claimed','ambiguous'))>least(lim.max_effects,(d.contract->>'max_effects')::integer)
    OR (SELECT count(*) FROM robot_runtime.activity_timer WHERE activity_id=a.id AND status='pending')>least(lim.max_timers,(d.contract->>'max_timers')::integer) THEN RAISE EXCEPTION 'outstanding work quota exceeded'; END IF;
  UPDATE robot_runtime.activity_instance SET state=tr.new_state,lifecycle=life,generation=a.generation,effect_epoch=a.effect_epoch,
    revision=a.revision+1,barrier_pending=false,updated_at=clock_timestamp() WHERE id=a.id;
  INSERT INTO robot_runtime.activity_history(activity_id,generation,revision,intent_id,old_revision,lifecycle,state_hash,effect_ids,events)
    VALUES(a.id,a.generation,a.revision+1,i.id,a.revision,life,md5(tr.new_state::text),ids,tr.events);
  UPDATE robot_runtime.activity_inbox SET status='processed',processed_at=clock_timestamp() WHERE id=i.id;
  IF life IN ('stopped','faulted') THEN
    UPDATE robot_runtime.activity_inbox SET status='stale',processed_at=clock_timestamp() WHERE activity_id=a.id AND status='pending';
  END IF;
END $$;

CREATE FUNCTION robot_runtime._fault(p_id uuid,p_intent uuid,p_code text) RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance;
BEGIN
  UPDATE robot_runtime.activity_instance SET lifecycle='faulted',effect_epoch=effect_epoch+1,revision=revision+1,
    barrier_pending=false,updated_at=clock_timestamp() WHERE id=p_id RETURNING * INTO a;
  PERFORM robot_runtime._cancel(p_id);
  UPDATE robot_runtime.activity_inbox SET status=CASE WHEN id=p_intent THEN 'failed' ELSE 'stale' END,processed_at=clock_timestamp() WHERE activity_id=p_id AND status='pending';
  INSERT INTO robot_runtime.activity_history(activity_id,generation,revision,intent_id,old_revision,lifecycle,state_hash,error_code)
    VALUES(a.id,a.generation,a.revision,p_intent,a.revision-1,'faulted',md5(a.state::text),p_code);
  INSERT INTO robot_runtime.dead_letter(activity_id,intent_id,reason) VALUES(p_id,p_intent,'reducer:'||p_code);
  RAISE LOG 'robot_runtime activity=% generation=% revision=% intent=% error=%',a.id,a.generation,a.revision,p_intent,p_code;
END $$;

CREATE FUNCTION robot_runtime.process_one() RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance; i robot_runtime.activity_inbox; d robot_runtime.activity_definition;
  tr robot_runtime.transition; worked boolean; reducer_oid regprocedure; n text; f text;
BEGIN
  SELECT * INTO a FROM robot_runtime.activity_instance x WHERE
    EXISTS (SELECT FROM robot_runtime.activity_inbox q WHERE q.activity_id=x.id AND q.status='pending'
      AND (x.lifecycle<>'paused' OR q.kind LIKE 'lifecycle.%' OR q.kind LIKE 'effect.%' OR q.expires_at<=clock_timestamp()))
    OR EXISTS (SELECT FROM robot_runtime.activity_timer t WHERE t.activity_id=x.id AND t.status='pending' AND t.due_at<=clock_timestamp())
    OR EXISTS (SELECT FROM robot_runtime.effect_outbox e WHERE e.activity_id=x.id AND e.status IN ('pending','claimed')
      AND (e.deadline_at<=clock_timestamp() OR e.expires_at<=clock_timestamp() OR (e.status='claimed' AND e.claim_expires_at<=clock_timestamp())))
    ORDER BY x.last_scheduled_at,x.id FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN false; END IF;
  UPDATE robot_runtime.activity_instance SET last_scheduled_at=clock_timestamp() WHERE id=a.id;
  worked:=robot_runtime._maintain(a.id);
  SELECT * INTO i FROM robot_runtime.activity_inbox WHERE activity_id=a.id AND status='pending'
    AND (a.lifecycle<>'paused' OR kind LIKE 'lifecycle.%' OR kind LIKE 'effect.%' OR expires_at<=clock_timestamp()) ORDER BY priority DESC,sequence LIMIT 1;
  IF NOT FOUND THEN RETURN worked; END IF;
  IF i.generation<>a.generation OR i.expires_at<=clock_timestamp() THEN
    UPDATE robot_runtime.activity_inbox SET status=CASE WHEN i.generation<>a.generation THEN 'stale' ELSE 'expired' END,processed_at=clock_timestamp() WHERE id=i.id;
    INSERT INTO robot_runtime.dead_letter(activity_id,intent_id,reason) VALUES(a.id,i.id,'stale_or_expired'); RETURN true;
  END IF;
  -- Exception block is a subtransaction: reducer writes and partial application
  -- roll back before fault metadata is recorded in the outer transaction.
  BEGIN
    SELECT * INTO STRICT d FROM robot_runtime.activity_definition WHERE name=a.definition_name AND version=a.definition_version;
    reducer_oid:=to_regprocedure(d.reducer_signature);
    IF reducer_oid IS NULL OR md5(pg_get_functiondef(reducer_oid))<>d.reducer_fingerprint THEN RAISE EXCEPTION 'registered reducer changed'; END IF;
    -- Ownership and role attributes are not part of pg_get_functiondef.
    IF NOT EXISTS (SELECT FROM pg_proc p JOIN pg_roles r ON r.oid=p.proowner
      WHERE p.oid=reducer_oid AND r.rolname=d.owner AND NOT r.rolsuper
        AND NOT r.rolbypassrls AND r.rolname NOT LIKE 'robot_runtime_%') THEN
      RAISE EXCEPTION 'registered reducer owner changed or became privileged';
    END IF;
    SELECT ns.nspname,p.proname INTO n,f FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace WHERE p.oid=reducer_oid;
    EXECUTE format('SELECT r.* FROM %I.%I($1,$2,$3) r',n,f) INTO tr USING a.state,
      ROW(i.id,i.kind,1,i.payload,i.source,i.message_id,i.observed_at,i.expires_at)::robot_runtime.intent,
      ROW(a.id,a.generation+CASE WHEN i.kind='lifecycle.resume' THEN 1 ELSE 0 END,
        a.effect_epoch+CASE WHEN i.kind='lifecycle.resume' THEN 1 ELSE 0 END,a.revision+1,i.accepted_at)::robot_runtime.reduce_context;
    PERFORM robot_runtime._apply(a,i,tr);
  EXCEPTION WHEN query_canceled THEN PERFORM robot_runtime._fault(a.id,i.id,'57014');
    WHEN OTHERS THEN PERFORM robot_runtime._fault(a.id,i.id,SQLSTATE);
  END;
  RETURN true;
END $$;
COMMIT;
