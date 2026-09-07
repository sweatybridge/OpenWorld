BEGIN;
SET LOCAL ROLE robot_runtime_store;
CREATE FUNCTION robot_runtime.register_adapter(p_name text,p_owner name,p_capabilities text[],p_protocol_versions integer[] DEFAULT ARRAY[1])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF coalesce(length(p_name),0) NOT BETWEEN 1 AND 128 OR coalesce(cardinality(p_capabilities),0) NOT BETWEEN 1 AND 64
    OR p_protocol_versions IS DISTINCT FROM ARRAY[1] OR NOT EXISTS (SELECT FROM pg_roles WHERE rolname=p_owner AND NOT rolsuper AND NOT rolbypassrls)
    OR EXISTS (SELECT FROM unnest(p_capabilities) c WHERE c IS NULL OR length(c) NOT BETWEEN 1 AND 128) THEN RAISE EXCEPTION 'invalid adapter registration (SQL protocol 1 required)'; END IF;
  INSERT INTO robot_runtime.adapter_registration(name,owner,capabilities,protocol_versions) VALUES(p_name,p_owner,p_capabilities,p_protocol_versions);
END $$;
CREATE FUNCTION robot_runtime._adapter(p_name text) RETURNS void LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF NOT EXISTS (SELECT FROM robot_runtime.adapter_registration WHERE name=p_name AND robot_runtime._owns(owner)) THEN RAISE EXCEPTION 'adapter unavailable' USING ERRCODE='42501'; END IF;
END $$;
CREATE FUNCTION robot_runtime.adapter_heartbeat(p_adapter text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM robot_runtime._adapter(p_adapter); UPDATE robot_runtime.adapter_registration SET last_seen_at=clock_timestamp() WHERE name=p_adapter; END $$;

CREATE FUNCTION robot_runtime.acquire_capability(p_adapter text,p_capability text,p_resource_key text,p_gateway text,
  p_ttl_seconds integer DEFAULT 30,p_mode text DEFAULT 'exclusive') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE l robot_runtime.capability_lease; token bigint; stamp timestamptz:=clock_timestamp();
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_ttl_seconds IS NULL OR p_ttl_seconds NOT BETWEEN 1 AND 60 OR p_mode IS NULL OR p_mode NOT IN ('exclusive','shared')
    OR coalesce(length(p_resource_key),0) NOT BETWEEN 1 AND 128 OR coalesce(length(p_gateway),0) NOT BETWEEN 1 AND 128
    OR NOT EXISTS(SELECT FROM robot_runtime.adapter_registration WHERE name=p_adapter AND p_capability=ANY(capabilities)) THEN RAISE EXCEPTION 'invalid capability request'; END IF;
  INSERT INTO robot_runtime.capability_resource(adapter,capability,resource_key) VALUES(p_adapter,p_capability,p_resource_key) ON CONFLICT DO NOTHING;
  PERFORM 1 FROM robot_runtime.capability_resource WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key FOR UPDATE;
  stamp:=clock_timestamp();
  -- Holder rows are transient; the resource retains the monotonic fence.
  DELETE FROM robot_runtime.capability_lease WHERE adapter=p_adapter AND capability=p_capability
    AND resource_key=p_resource_key AND expires_at<=stamp;
  SELECT * INTO l FROM robot_runtime.capability_lease WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key AND gateway=p_gateway;
  IF FOUND AND l.expires_at>stamp THEN
    IF l.mode<>p_mode THEN RAISE EXCEPTION 'cannot change live lease mode'; END IF;
    RETURN to_jsonb(l);
  END IF;
  IF EXISTS (SELECT FROM robot_runtime.capability_lease WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key
    AND expires_at>stamp AND (p_mode='exclusive' OR mode='exclusive')) THEN RETURN jsonb_build_object('status','busy'); END IF;
  UPDATE robot_runtime.capability_resource SET fence=fence+1 WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key RETURNING fence INTO token;
  INSERT INTO robot_runtime.capability_lease VALUES(p_adapter,p_capability,p_resource_key,p_gateway,p_mode,token,stamp+make_interval(secs=>p_ttl_seconds))
    ON CONFLICT(adapter,capability,resource_key,gateway) DO UPDATE SET mode=excluded.mode,fence=excluded.fence,expires_at=excluded.expires_at RETURNING * INTO l;
  RETURN to_jsonb(l);
END $$;
CREATE FUNCTION robot_runtime.renew_capability(p_adapter text,p_capability text,p_resource_key text,p_gateway text,p_fence bigint,p_ttl_seconds integer DEFAULT 30)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_ttl_seconds IS NULL OR p_ttl_seconds NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid lease TTL'; END IF;
  PERFORM 1 FROM robot_runtime.capability_resource WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key FOR UPDATE;
  UPDATE robot_runtime.capability_lease SET expires_at=clock_timestamp()+make_interval(secs=>p_ttl_seconds)
    WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key AND gateway=p_gateway AND fence=p_fence AND expires_at>clock_timestamp();
  RETURN FOUND;
END $$;

CREATE FUNCTION robot_runtime.claim_effects(p_adapter text,p_capability text,p_resource_key text,p_gateway text,p_fence bigint,
  p_limit integer DEFAULT 16,p_claim_seconds integer DEFAULT 10) RETURNS SETOF robot_runtime.effect_outbox
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE a robot_runtime.activity_instance; e robot_runtime.effect_outbox; l robot_runtime.capability_lease;
  total integer:=0; stamp timestamptz;
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR p_claim_seconds IS NULL OR p_claim_seconds NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'invalid claim bounds'; END IF;
  -- Global lock order: activities in UUID order, capability resource, effects.
  -- The activity lock is also the serialization point with lifecycle barriers.
  FOR a IN SELECT * FROM robot_runtime.activity_instance x WHERE NOT barrier_pending AND EXISTS
    (SELECT FROM robot_runtime.effect_outbox y WHERE y.activity_id=x.id AND y.status='pending' AND y.adapter=p_adapter AND y.capability=p_capability AND y.resource_key=p_resource_key)
    -- Count claims, not candidate activities: blocked lanes must not consume
    -- the batch limit and starve eligible work in later activities.
    ORDER BY id FOR UPDATE SKIP LOCKED LOOP
    PERFORM 1 FROM robot_runtime.capability_resource WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key FOR UPDATE;
    SELECT * INTO l FROM robot_runtime.capability_lease WHERE adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key AND gateway=p_gateway AND fence=p_fence AND expires_at>clock_timestamp();
    IF NOT FOUND THEN RAISE EXCEPTION 'capability lease is stale'; END IF;
    FOR e IN SELECT * FROM robot_runtime.effect_outbox x WHERE activity_id=a.id AND status='pending'
      AND adapter=p_adapter AND capability=p_capability AND resource_key=p_resource_key
      AND generation=a.generation AND effect_epoch=a.effect_epoch
      AND (a.lifecycle='active' AND scope='ordinary' OR a.lifecycle='stopped' AND scope='stop' OR a.lifecycle='faulted' AND scope='fault')
      AND (expires_at IS NULL OR expires_at>clock_timestamp()) AND (deadline_at IS NULL OR deadline_at>clock_timestamp())
      ORDER BY priority DESC,revision,effect_index LOOP
      -- One in-flight effect per activity/adapter/lane. Ambiguity blocks the lane
      -- until explicit reconciliation; higher priority cannot jump a FIFO item.
      IF EXISTS (SELECT FROM robot_runtime.effect_outbox older WHERE older.activity_id=e.activity_id AND older.adapter=e.adapter AND older.lane=e.lane
        AND older.id<>e.id AND (older.status IN ('claimed','ambiguous') OR older.status='pending' AND (older.revision,older.effect_index)<(e.revision,e.effect_index))) THEN CONTINUE; END IF;
      stamp:=clock_timestamp();
      UPDATE robot_runtime.effect_outbox SET status='claimed',claim_token=gen_random_uuid(),gateway=p_gateway,fence=p_fence,
        claim_expires_at=least(stamp+make_interval(secs=>p_claim_seconds),l.expires_at,e.expires_at,e.deadline_at) WHERE id=e.id RETURNING * INTO e;
      INSERT INTO robot_runtime.effect_attempt(effect_id,claim_token,gateway,fence,outcome) VALUES(e.id,e.claim_token,e.gateway,e.fence,'claimed');
      RETURN NEXT e; total:=total+1;
      IF total>=p_limit THEN RETURN; END IF;
    END LOOP;
  END LOOP;
END $$;

CREATE FUNCTION robot_runtime.complete_effect(p_effect uuid,p_claim_token uuid,p_adapter text,p_gateway text,p_fence bigint,
  p_outcome text,p_result jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e robot_runtime.effect_outbox; a robot_runtime.activity_instance; prior jsonb; req jsonb; accepted boolean; stamp timestamptz;
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_outcome IS NULL OR p_outcome NOT IN ('succeeded','failed','ambiguous') OR p_result IS NULL
    OR octet_length(p_result::text)>(SELECT max_payload_bytes FROM robot_runtime.settings) THEN RAISE EXCEPTION 'invalid completion'; END IF;
  SELECT * INTO e FROM robot_runtime.effect_outbox WHERE id=p_effect AND adapter=p_adapter;
  IF NOT FOUND THEN RAISE EXCEPTION 'effect unavailable'; END IF;
  SELECT * INTO a FROM robot_runtime.activity_instance WHERE id=e.activity_id FOR UPDATE;
  PERFORM 1 FROM robot_runtime.capability_resource WHERE adapter=e.adapter AND capability=e.capability AND resource_key=e.resource_key FOR UPDATE;
  SELECT * INTO e FROM robot_runtime.effect_outbox WHERE id=p_effect FOR UPDATE;
  IF NOT EXISTS (SELECT FROM robot_runtime.effect_attempt WHERE effect_id=e.id AND claim_token=p_claim_token AND gateway=p_gateway AND fence=p_fence AND outcome='claimed') THEN RAISE EXCEPTION 'unknown claim'; END IF;
  req:=jsonb_build_object('outcome',p_outcome,'result',p_result);
  SELECT result INTO prior FROM robot_runtime.effect_attempt WHERE effect_id=e.id AND claim_token=p_claim_token AND outcome IN ('completed','stale_completion') ORDER BY id LIMIT 1;
  IF FOUND THEN
    IF prior->'request'=req THEN RETURN prior->'receipt' || jsonb_build_object('duplicate',true); END IF;
    INSERT INTO robot_runtime.effect_attempt(effect_id,claim_token,gateway,fence,outcome) VALUES(e.id,p_claim_token,p_gateway,p_fence,'conflicting_completion');
    RETURN jsonb_build_object('status','conflict');
  END IF;
  stamp:=clock_timestamp();
  accepted:=e.status='claimed' AND e.claim_token=p_claim_token AND e.claim_expires_at>stamp
    AND (e.expires_at IS NULL OR e.expires_at>stamp) AND (e.deadline_at IS NULL OR e.deadline_at>stamp)
    AND e.generation=a.generation AND e.effect_epoch=a.effect_epoch AND NOT a.barrier_pending
    AND EXISTS (SELECT FROM robot_runtime.capability_lease WHERE adapter=e.adapter AND capability=e.capability AND resource_key=e.resource_key AND gateway=p_gateway AND fence=p_fence AND expires_at>stamp);
  prior:=jsonb_build_object('status',CASE WHEN accepted THEN p_outcome ELSE 'stale' END,'duplicate',false);
  INSERT INTO robot_runtime.effect_attempt(effect_id,claim_token,gateway,fence,outcome,result)
    VALUES(e.id,p_claim_token,p_gateway,p_fence,CASE WHEN accepted THEN 'completed' ELSE 'stale_completion' END,jsonb_build_object('request',req,'receipt',prior));
  IF accepted THEN PERFORM robot_runtime._effect_result(e.id,p_outcome,p_result); END IF;
  RETURN prior;
END $$;

CREATE FUNCTION robot_runtime.reconcile_effect(p_effect uuid,p_adapter text,p_gateway text,p_fence bigint,p_outcome text,p_result jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE e robot_runtime.effect_outbox; a robot_runtime.activity_instance;
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_outcome IS NULL OR p_outcome NOT IN ('succeeded','failed') OR p_result IS NULL OR octet_length(p_result::text)>(SELECT max_payload_bytes FROM robot_runtime.settings) THEN RAISE EXCEPTION 'invalid reconciliation'; END IF;
  SELECT * INTO e FROM robot_runtime.effect_outbox WHERE id=p_effect AND adapter=p_adapter;
  IF NOT FOUND THEN RAISE EXCEPTION 'effect unavailable'; END IF;
  SELECT * INTO a FROM robot_runtime.activity_instance WHERE id=e.activity_id FOR UPDATE;
  PERFORM 1 FROM robot_runtime.capability_resource WHERE adapter=e.adapter AND capability=e.capability AND resource_key=e.resource_key FOR UPDATE;
  SELECT * INTO e FROM robot_runtime.effect_outbox WHERE id=p_effect FOR UPDATE;
  IF NOT EXISTS (SELECT FROM robot_runtime.capability_lease WHERE adapter=e.adapter AND capability=e.capability AND resource_key=e.resource_key AND gateway=p_gateway AND fence=p_fence AND expires_at>clock_timestamp()) THEN RAISE EXCEPTION 'stale reconciliation lease'; END IF;
  IF e.status='reconciled' THEN
    IF e.outcome=jsonb_build_object('outcome',p_outcome,'result',p_result) THEN RETURN jsonb_build_object('status','reconciled','duplicate',true); END IF;
    INSERT INTO robot_runtime.effect_attempt(effect_id,gateway,fence,outcome) VALUES(e.id,p_gateway,p_fence,'conflicting_reconciliation'); RETURN jsonb_build_object('status','conflict');
  END IF;
  IF e.status<>'ambiguous' THEN RETURN jsonb_build_object('status','not_ambiguous'); END IF;
  PERFORM robot_runtime._effect_result(e.id,p_outcome,p_result);
  UPDATE robot_runtime.effect_outbox SET status='reconciled',outcome=jsonb_build_object('outcome',p_outcome,'result',p_result) WHERE id=e.id;
  INSERT INTO robot_runtime.effect_attempt(effect_id,gateway,fence,outcome,result) VALUES(e.id,p_gateway,p_fence,'reconciled',p_result);
  RETURN jsonb_build_object('status','reconciled','duplicate',false);
END $$;

-- An adapter can publish only declared observations to activities referencing
-- one of its effects. Ownership of an adapter does not grant general operator access.
CREATE FUNCTION robot_runtime.publish_intent(p_adapter text,p_activity robot_runtime.activity_ref,p_kind text,p_payload jsonb,
  p_message_id uuid,p_observed_at timestamptz DEFAULT NULL,p_expires_at timestamptz DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  PERFORM robot_runtime._adapter(p_adapter);
  IF p_message_id IS NULL OR p_kind ~ '^(lifecycle|timer|effect)\.' THEN RAISE EXCEPTION 'invalid adapter intent'; END IF;
  IF NOT EXISTS (SELECT FROM robot_runtime.activity_instance a JOIN robot_runtime.activity_definition d
    ON (d.name,d.version)=(a.definition_name,a.definition_version) WHERE a.id=p_activity.activity_id
      AND coalesce(d.contract->'intents'->p_kind->'adapters','[]') ? p_adapter) THEN
    RAISE EXCEPTION 'adapter cannot publish this intent kind' USING ERRCODE='42501';
  END IF;
  IF NOT EXISTS (SELECT FROM robot_runtime.effect_outbox WHERE adapter=p_adapter AND activity_id=p_activity.activity_id AND generation=p_activity.generation) THEN RAISE EXCEPTION 'adapter is not bound to activity' USING ERRCODE='42501'; END IF;
  RETURN robot_runtime._enqueue(p_activity.activity_id,p_activity.generation,p_kind,p_payload,'adapter:'||p_adapter,p_message_id,p_observed_at,p_expires_at);
END $$;
COMMIT;
