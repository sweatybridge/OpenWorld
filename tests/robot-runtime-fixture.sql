-- Shared by transactional pgTAP and committed worker/restart integration tests.
CREATE ROLE rr_owner NOLOGIN;
CREATE ROLE rr_other NOLOGIN;
CREATE ROLE rr_adapter NOLOGIN;
GRANT robot_runtime_operator,robot_runtime_observer TO rr_owner,rr_other;
GRANT robot_runtime_adapter TO rr_adapter;
CREATE SCHEMA rr_test;
GRANT USAGE ON SCHEMA rr_test TO rr_owner,robot_runtime_store;
CREATE FUNCTION rr_test.reduce(s jsonb,i robot_runtime.intent,c robot_runtime.reduce_context)
RETURNS robot_runtime.transition LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE effects jsonb:='[]'; timers jsonb:='[]';
BEGIN
  CASE i.kind
    WHEN 'add' THEN s:=jsonb_set(s,'{count}',to_jsonb((s->>'count')::integer+(i.payload->>'value')::integer));
    WHEN 'observe' THEN s:=s||jsonb_build_object('observation',i.payload);
    WHEN 'who' THEN s:=s||jsonb_build_object('effective_owner',current_user);
    WHEN 'timer.fired' THEN s:=jsonb_set(s,'{count}',to_jsonb((s->>'count')::integer+100));
    WHEN 'effect.succeeded' THEN s:=jsonb_set(s,'{count}',to_jsonb((s->>'count')::integer+10));
    WHEN 'fail' THEN RAISE EXCEPTION 'fixture reducer failure';
    WHEN 'invalid' THEN s:='"bad state"';
    WHEN 'slow' THEN PERFORM pg_sleep(10);
    ELSE NULL;
  END CASE;
  IF i.kind IN ('emit','lifecycle.stop','lifecycle.fault') THEN
    effects:=coalesce(i.payload->'effects','[]'); timers:=coalesce(i.payload->'timers','[]');
  END IF;
  RETURN (s,NULL,effects,timers,'[]')::robot_runtime.transition;
END $$;
ALTER FUNCTION rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) OWNER TO rr_owner;
REVOKE ALL ON FUNCTION rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) TO robot_runtime_store;
SELECT robot_runtime.define('counter',1,'rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)',
  '{"count":0}', '{"state_schema":{"type":"object","required":["count"],"properties":{"count":{"type":"integer"}}},
  "max_mailbox":4,"max_effects":4,"max_timers":4,"intents":{
    "add":{"schema":{"type":"object","required":["value"],"properties":{"value":{"type":"integer"}},"additionalProperties":false}},
    "observe":{"delivery":"latest","replace_key":"state","adapters":["mock"]},
    "busy":{"delivery":"reject_if_busy"},"who":{},"emit":{},"fail":{},"invalid":{},"slow":{}}}');
SELECT robot_runtime.register_adapter('mock','rr_adapter',ARRAY['arm']);
CREATE FUNCTION rr_test.effect(p_retry text DEFAULT 'idempotent',p_deadline timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$ SELECT jsonb_build_object('adapter','mock','capability','arm','resource_key','r1',
  'operation','move','payload','{}'::jsonb,'retry_class',p_retry,'deadline_at',p_deadline) $$;
GRANT EXECUTE ON FUNCTION rr_test.effect(text,timestamptz) TO rr_owner;
