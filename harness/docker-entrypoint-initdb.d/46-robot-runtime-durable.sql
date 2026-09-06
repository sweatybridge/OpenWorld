BEGIN;
SELECT df.grant_usage('robot_runtime_worker', include_http => false);
SET LOCAL ROLE robot_runtime_store;

CREATE FUNCTION robot_runtime.scheduler_enabled(p_slot integer DEFAULT 0) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
  SELECT enabled AND p_slot BETWEEN 0 AND executors FROM robot_runtime.settings
$$;
CREATE FUNCTION robot_runtime.tick(p_slot integer) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE worked boolean:=false;
BEGIN
  IF NOT robot_runtime.scheduler_enabled(p_slot) OR p_slot=0 THEN RETURN false; END IF;
  BEGIN
    worked:=robot_runtime.process_one();
    UPDATE robot_runtime.worker_epoch SET last_seen_at=clock_timestamp(),transitions=transitions+worked::integer,last_error=NULL WHERE slot=p_slot;
  EXCEPTION WHEN query_canceled THEN
    UPDATE robot_runtime.worker_epoch SET last_seen_at=clock_timestamp(),last_error='57014' WHERE slot=p_slot;
    WHEN OTHERS THEN
    UPDATE robot_runtime.worker_epoch SET last_seen_at=clock_timestamp(),last_error=SQLSTATE WHERE slot=p_slot;
    RAISE LOG 'robot_runtime worker_slot=% error=%',p_slot,SQLSTATE;
  END;
  RETURN worked;
END $$;

CREATE FUNCTION robot_runtime._launch(p_slot integer) RETURNS text LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE instance text; body text; v_label text:='robot_runtime:executor:'||p_slot;
BEGIN
  SELECT id INTO instance FROM df.instances WHERE df.instances.label=v_label AND status IN ('pending','running') ORDER BY updated_at DESC LIMIT 1;
  IF instance IS NOT NULL THEN RETURN instance; END IF;
  IF p_slot=0 THEN
    body:=df.seq('SELECT robot_runtime.ensure_scheduler(false)',df.sleep(5));
  ELSE
    -- A successful tick immediately processes the next intent. Idle ticks wait
    -- using a durable timer, never pg_sleep or an open SQL transaction.
    body:=df.if(format('SELECT robot_runtime.tick(%s)',p_slot),'SELECT true',df.sleep(1));
  END IF;
  RETURN df.start(df.loop(body,format('SELECT robot_runtime.scheduler_enabled(%s)',p_slot)),v_label);
END $$;
CREATE FUNCTION robot_runtime.ensure_scheduler(p_supervisor boolean DEFAULT true) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE s robot_runtime.settings; v_slot integer; instance text; result jsonb:='{}';
BEGIN
  SELECT * INTO s FROM robot_runtime.settings FOR UPDATE;
  IF NOT s.enabled THEN RETURN jsonb_build_object('enabled',false); END IF;
  FOR v_slot IN SELECT generate_series(CASE WHEN p_supervisor THEN 0 ELSE 1 END,s.executors) LOOP
    instance:=robot_runtime._launch(v_slot);
    INSERT INTO robot_runtime.worker_epoch(slot,instance_id) VALUES(v_slot,instance)
      ON CONFLICT(slot) DO UPDATE SET instance_id=excluded.instance_id,epoch=robot_runtime.worker_epoch.epoch+1,
        started_at=clock_timestamp(),last_error=NULL WHERE robot_runtime.worker_epoch.instance_id IS DISTINCT FROM excluded.instance_id;
    result:=result||jsonb_build_object(v_slot::text,instance);
  END LOOP;
  UPDATE robot_runtime.worker_epoch SET last_seen_at=clock_timestamp() WHERE slot=0;
  RETURN result;
END $$;

-- Diagnostic retention never deletes deduplication identities, pending work,
-- ambiguous effects, or activity history. Terminal activity export/removal is
-- an explicit operator action; defaults preserve replay and retry contracts.
CREATE FUNCTION robot_runtime.prune_diagnostics(p_before timestamptz DEFAULT clock_timestamp()-interval '30 days',p_limit integer DEFAULT 1000)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE n integer; m integer;
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 10000 OR p_before>clock_timestamp()-interval '1 day' THEN RAISE EXCEPTION 'invalid retention bounds'; END IF;
  DELETE FROM robot_runtime.dead_letter WHERE id IN
    (SELECT d.id FROM robot_runtime.dead_letter d JOIN robot_runtime.activity_instance a ON a.id=d.activity_id
      WHERE a.lifecycle IN ('stopped','faulted') AND d.created_at<p_before ORDER BY d.id LIMIT p_limit);
  GET DIAGNOSTICS n=ROW_COUNT;
  -- Keep claims and completion receipts: old retry tokens still need validation.
  DELETE FROM robot_runtime.effect_attempt WHERE id IN
    (SELECT x.id FROM robot_runtime.effect_attempt x JOIN robot_runtime.effect_outbox e ON e.id=x.effect_id
      JOIN robot_runtime.activity_instance a ON a.id=e.activity_id WHERE a.lifecycle IN ('stopped','faulted')
      AND e.status NOT IN ('pending','claimed','ambiguous') AND x.created_at<p_before
      AND x.outcome NOT IN ('claimed','completed','stale_completion') ORDER BY x.id LIMIT p_limit);
  GET DIAGNOSTICS m=ROW_COUNT; RETURN n+m;
END $$;

CREATE FUNCTION robot_runtime._can_adapter(p_name text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT FROM robot_runtime.adapter_registration WHERE name=p_name AND robot_runtime._owns(owner))
$$;
ALTER TABLE robot_runtime.activity_definition ENABLE ROW LEVEL SECURITY;
CREATE POLICY definition_read ON robot_runtime.activity_definition FOR SELECT USING (robot_runtime._owns(owner));
ALTER TABLE robot_runtime.activity_instance ENABLE ROW LEVEL SECURITY;
CREATE POLICY instance_read ON robot_runtime.activity_instance FOR SELECT USING (robot_runtime._owns(owner));
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['activity_inbox','activity_history','activity_timer','dead_letter'] LOOP
    EXECUTE format('ALTER TABLE robot_runtime.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY owner_read ON robot_runtime.%I FOR SELECT USING (robot_runtime._can_access(activity_id))',t);
  END LOOP;
END $$;
ALTER TABLE robot_runtime.effect_outbox ENABLE ROW LEVEL SECURITY;
CREATE POLICY effect_read ON robot_runtime.effect_outbox FOR SELECT USING (robot_runtime._can_access(activity_id) OR robot_runtime._can_adapter(adapter));
ALTER TABLE robot_runtime.effect_attempt ENABLE ROW LEVEL SECURITY;
CREATE POLICY attempt_read ON robot_runtime.effect_attempt FOR SELECT USING (EXISTS (SELECT FROM robot_runtime.effect_outbox e WHERE e.id=effect_id));
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['adapter_registration','capability_resource','capability_lease'] LOOP
    EXECUTE format('ALTER TABLE robot_runtime.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY adapter_read ON robot_runtime.%I FOR SELECT USING (robot_runtime._can_adapter(%I))',t,CASE WHEN t='adapter_registration' THEN 'name' ELSE 'adapter' END);
  END LOOP;
END $$;
CREATE VIEW robot_runtime.activities WITH (security_invoker=true) AS
  SELECT a.id,a.definition_name,a.definition_version,a.owner,a.label,a.lifecycle,a.generation,a.effect_epoch,a.revision,a.updated_at,
    (SELECT count(*) FROM robot_runtime.activity_inbox i WHERE i.activity_id=a.id AND i.status='pending') AS mailbox_depth,
    (SELECT min(accepted_at) FROM robot_runtime.activity_inbox i WHERE i.activity_id=a.id AND i.status='pending') AS oldest_intent_at
  FROM robot_runtime.activity_instance a;
CREATE VIEW robot_runtime.worker_health AS SELECT w.*,s.enabled,s.executors,clock_timestamp()-w.last_seen_at AS heartbeat_age
  FROM robot_runtime.worker_epoch w CROSS JOIN robot_runtime.settings s;
CREATE VIEW robot_runtime.pending_timers WITH (security_invoker=true) AS SELECT *,clock_timestamp()-due_at AS overdue FROM robot_runtime.activity_timer WHERE status='pending';
CREATE VIEW robot_runtime.effects WITH (security_invoker=true) AS SELECT * FROM robot_runtime.effect_outbox;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA robot_runtime FROM PUBLIC;
GRANT EXECUTE ON FUNCTION robot_runtime._actor(),robot_runtime._owns(name),robot_runtime._can_access(uuid),robot_runtime._can_adapter(text)
  TO robot_runtime_admin,robot_runtime_operator,robot_runtime_observer,robot_runtime_adapter;
GRANT EXECUTE ON FUNCTION robot_runtime.define(text,integer,regprocedure,jsonb,jsonb),
  robot_runtime.register_adapter(text,name,text[],integer[]),robot_runtime.ensure_scheduler(boolean),robot_runtime.prune_diagnostics(timestamptz,integer)
  TO robot_runtime_admin;
GRANT EXECUTE ON FUNCTION robot_runtime.start(text,integer,jsonb,text,uuid),robot_runtime.send(robot_runtime.activity_ref,text,jsonb,uuid,timestamptz,timestamptz)
  TO robot_runtime_operator;
GRANT EXECUTE ON FUNCTION robot_runtime.inspect(uuid) TO robot_runtime_operator,robot_runtime_observer;
GRANT EXECUTE ON FUNCTION robot_runtime.adapter_heartbeat(text),robot_runtime.acquire_capability(text,text,text,text,integer,text),
  robot_runtime.renew_capability(text,text,text,text,bigint,integer),robot_runtime.claim_effects(text,text,text,text,bigint,integer,integer),
  robot_runtime.complete_effect(uuid,uuid,text,text,bigint,text,jsonb),robot_runtime.reconcile_effect(uuid,text,text,bigint,text,jsonb),
  robot_runtime.publish_intent(text,robot_runtime.activity_ref,text,jsonb,uuid,timestamptz,timestamptz) TO robot_runtime_adapter;
GRANT EXECUTE ON FUNCTION robot_runtime.process_one(),robot_runtime.tick(integer),robot_runtime.scheduler_enabled(integer),robot_runtime.ensure_scheduler(boolean) TO robot_runtime_worker;
GRANT SELECT ON robot_runtime.activity_definition,robot_runtime.activity_instance,robot_runtime.activity_inbox,robot_runtime.activity_history,
  robot_runtime.activity_timer,robot_runtime.effect_outbox,robot_runtime.effect_attempt,robot_runtime.dead_letter,
  robot_runtime.adapter_registration,robot_runtime.capability_resource,robot_runtime.capability_lease,
  robot_runtime.activities,robot_runtime.pending_timers,robot_runtime.effects,robot_runtime.worker_health
  TO robot_runtime_operator,robot_runtime_observer,robot_runtime_adapter,robot_runtime_admin;
GRANT SELECT,UPDATE ON robot_runtime.settings TO robot_runtime_admin;
RESET ROLE;
ALTER FUNCTION robot_runtime._launch(integer) OWNER TO robot_runtime_worker;
GRANT EXECUTE ON FUNCTION robot_runtime._launch(integer) TO robot_runtime_store;
GRANT robot_runtime_operator TO ow_agent_primary,ow_agent_sidecar;
-- Dashboard has BYPASSRLS already; observer grants intentionally permit its
-- existing administrator to inspect all runtime state without mutation rights.
GRANT robot_runtime_observer TO ow_dashboard;
SELECT robot_runtime.ensure_scheduler();
COMMIT;
