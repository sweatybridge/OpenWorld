\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();
\ir ../robot-runtime-fixture.sql

SELECT ok(NOT has_function_privilege('ow_anonymous','robot_runtime.process_one()','EXECUTE'),'end user cannot process activities');
SELECT ok(NOT has_function_privilege('rr_owner','robot_runtime._enqueue(uuid,bigint,text,jsonb,text,uuid,timestamptz,timestamptz)','EXECUTE'),'operators cannot forge internal sources');
SELECT ok(NOT has_table_privilege('rr_owner','robot_runtime.activity_instance','UPDATE'),'operators cannot mutate runtime tables');
SELECT ok(NOT has_function_privilege('rr_adapter','robot_runtime.send(robot_runtime.activity_ref,text,jsonb,uuid,timestamptz,timestamptz)','EXECUTE'),'adapter is not a general operator');
SELECT ok(NOT has_function_privilege('robot_runtime_observer','robot_runtime.register_adapter(text,name,text[],integer[])','EXECUTE'),'observer cannot register adapters via PUBLIC defaults');
SELECT ok(NOT has_function_privilege('robot_runtime_observer','robot_runtime.prune_diagnostics(timestamptz,integer)','EXECUTE'),'observer cannot delete diagnostics');
SELECT throws_ok($$SELECT robot_runtime._schema('{"enum":[{"operation":"move","approved":true}]}','{"operation":"move"}')$$,'P0001','schema enum mismatch','object enum uses equality, not containment');
SELECT throws_ok($$SELECT robot_runtime.define('bad',1,'rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)','{}','{"state_schema":{"$ref":"remote"}}')$$,'P0001','unsupported schema keyword: $ref','unknown schema vocabulary rejected');
SELECT throws_ok($$SELECT robot_runtime.define('counter',1,'rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)','{"count":1}','{}')$$,'P0001','definition versions are immutable','definition version cannot change');

SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1,'{}','test','00000000-0000-0000-0000-000000000001')).activity_id AS aid \gset
SELECT is((robot_runtime.start('counter',1,'{}','test','00000000-0000-0000-0000-000000000001')).activity_id,:'aid'::uuid,'start retry returns same activity');
SELECT throws_ok($$SELECT robot_runtime.start('counter',1,'{"different":true}','test','00000000-0000-0000-0000-000000000001')$$,'P0001','idempotency_key reused with different content','conflicting start rejected');
-- Ordinary sends immediately after start must queue behind its initial intent.
SELECT is(robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":2}','00000000-0000-0000-0000-000000000002')->>'status','pending','send immediately after start accepted');
SELECT is(robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":2}','00000000-0000-0000-0000-000000000002')->>'duplicate','true','duplicate send ignores generated observed timestamp');
SELECT throws_ok(format('SELECT robot_runtime.send(ROW(%L,1)::robot_runtime.activity_ref,''add'',''{"value":3}'',''00000000-0000-0000-0000-000000000002'')',:'aid'),'P0001','message_id reused with different content','conflicting send rejected');
RESET ROLE;
SELECT ok(robot_runtime.process_one(),'initial reduction processed');
SELECT ok(robot_runtime.process_one(),'queued add processed');
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'aid'),'2','reducer changed state');
SELECT is((SELECT count(*) FROM robot_runtime.activity_history WHERE activity_id=:'aid'),2::bigint,'exactly two history revisions');
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'aid'),'active','start activates activity');
SET LOCAL ROLE rr_other;
SELECT is((SELECT count(*) FROM robot_runtime.activity_instance WHERE id=:'aid'),0::bigint,'RLS hides another owners activity');
SELECT throws_ok(format('SELECT robot_runtime.inspect(%L)',:'aid'),'42501','activity unavailable','inspect rejects another owner');
SELECT throws_ok(format('SELECT robot_runtime.send(ROW(%L,1)::robot_runtime.activity_ref,''add'',''{"value":1}'')',:'aid'),'42501','activity unavailable','send rejects another owner');
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'who');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT state->>'effective_owner' FROM robot_runtime.activity_instance WHERE id=:'aid'),'rr_owner','reducer runs as activity owner, not store or worker');

-- All state and side effects roll back if a later timer is invalid.
SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1)).activity_id AS bad \gset
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'bad',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect()),'timers','[{"timer_id":"broken"}]'::jsonb));
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'bad'),'faulted','invalid timer faults activity');
SELECT is((SELECT count(*) FROM robot_runtime.effect_outbox WHERE activity_id=:'bad'),0::bigint,'earlier effect insert rolled back');
SELECT ok(EXISTS(SELECT FROM robot_runtime.activity_history WHERE activity_id=:'bad' AND error_code IS NOT NULL),'fault metadata persists');

SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'observe','{"value":1}');
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'observe','{"value":2}');
RESET ROLE;
SELECT is((SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=:'aid' AND kind='observe' AND status='pending'),1::bigint,'latest observations coalesce');
SELECT robot_runtime.process_one();
SELECT is((SELECT state#>>'{observation,value}' FROM robot_runtime.activity_instance WHERE id=:'aid'),'2','latest observation reduced');
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":1}');
SELECT is(robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'busy')->>'status','rejected','reject_if_busy returns durable rejection');
SELECT throws_ok(format('SELECT robot_runtime.send(ROW(%L,1)::robot_runtime.activity_ref,''lifecycle.pause'',''{}'',NULL,NULL,clock_timestamp()+interval ''1 second'')',:'aid'),'P0001','lifecycle barriers cannot expire','expiring barriers cannot strand an activity');
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":1}');
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":1}');
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":1}');
SELECT is(robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":1}')->>'status','rejected','mailbox has enforced bound');
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'lifecycle.pause');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'aid'),'paused','pause barrier preempts queued commands');
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'lifecycle.resume');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT generation FROM robot_runtime.activity_instance WHERE id=:'aid'),2::bigint,'resume advances generation');
SELECT is((SELECT state->>'resume_generation' FROM robot_runtime.activity_instance WHERE id=:'aid'),'2','resume reducer context describes new generation');
SET LOCAL ROLE rr_owner;
SELECT is(robot_runtime.send(ROW(:'aid',1)::robot_runtime.activity_ref,'add','{"value":99}')->>'status','stale','obsolete generation cannot alter state');
SELECT robot_runtime.send(ROW(:'aid',2)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect())));
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT (robot_runtime.acquire_capability('mock','arm','r1','gateway')->>'fence')::bigint AS fence \gset
SELECT is(robot_runtime.acquire_capability('mock','arm','r1','other')->>'status','busy','exclusive capability denies second gateway');
SELECT id AS eid,claim_token AS token FROM robot_runtime.claim_effects('mock','arm','r1','gateway',:fence) \gset
SELECT is(robot_runtime.complete_effect(:'eid',:'token','mock','gateway',:fence,'succeeded','{"ok":true}')->>'status','succeeded','effect completion accepted');
SELECT is(robot_runtime.complete_effect(:'eid',:'token','mock','gateway',:fence,'succeeded','{"ok":true}')->>'duplicate','true','identical completion is idempotent');
SELECT is(robot_runtime.complete_effect(:'eid',:'token','mock','gateway',:fence,'failed')->>'status','conflict','conflicting completion returns auditable rejection');
SELECT throws_ok(format('SELECT robot_runtime.publish_intent(''mock'',ROW(%L,2)::robot_runtime.activity_ref,''add'',''{"value":100}'',gen_random_uuid())',:'aid'),'42501','adapter cannot publish this intent kind','adapter cannot publish operator command');
SELECT is(robot_runtime.publish_intent('mock',ROW(:'aid',2)::robot_runtime.activity_ref,'observe','{"adapter":true}',gen_random_uuid())->>'status','pending','adapter may publish allowlisted observations');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT robot_runtime.process_one();
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'aid'),'12','completion routed back through reducer once');
SELECT ok(EXISTS(SELECT FROM robot_runtime.effect_attempt WHERE effect_id=:'eid' AND outcome='conflicting_completion'),'conflicting completion audit committed');

-- Ambiguous delivery requires reconciliation, never blind replay.
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',2)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect('reconcile'))));
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT id AS ambiguous_id,claim_token AS ambiguous_token FROM robot_runtime.claim_effects('mock','arm','r1','gateway',:fence) \gset
SELECT robot_runtime.complete_effect(:'ambiguous_id',:'ambiguous_token','mock','gateway',:fence,'ambiguous');
SELECT is(robot_runtime.reconcile_effect(:'ambiguous_id','mock','gateway',:fence,'succeeded')->>'status','reconciled','ambiguous result can be reconciled without dedup conflict');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT robot_runtime.process_one();
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'aid'),'22','reconciliation result reaches current activity');

SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',2)::robot_runtime.activity_ref,'emit',jsonb_build_object('timers',jsonb_build_array(jsonb_build_object('timer_id','alarm','due_at',clock_timestamp()))));
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT robot_runtime.process_one();
SELECT robot_runtime.process_one();
SELECT is((SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=:'aid' AND kind='timer.fired'),1::bigint,'timer materializes one logical intent');
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'aid'),'122','timer routed through reducer');

-- Already claimed effects become stale as soon as stop is accepted.
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',2)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect())));
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT id AS late_id,claim_token AS late_token FROM robot_runtime.claim_effects('mock','arm','r1','gateway',:fence) \gset
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'aid',2)::robot_runtime.activity_ref,'lifecycle.stop');
SET LOCAL ROLE rr_adapter;
SELECT is(robot_runtime.complete_effect(:'late_id',:'late_token','mock','gateway',:fence,'succeeded')->>'status','stale','late completion cannot cross accepted stop barrier');
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'aid'),'stopped','stop reaches terminal lifecycle');
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'aid'),'122','late result did not mutate activity');
UPDATE robot_runtime.capability_lease SET expires_at=clock_timestamp()-interval '1 second' WHERE adapter='mock';
SET LOCAL ROLE rr_adapter;
SELECT ok(NOT robot_runtime.renew_capability('mock','arm','r1','gateway',:fence),'expired holder cannot renew');
SELECT ok((robot_runtime.acquire_capability('mock','arm','r1','other')->>'fence')::bigint>:fence,'new holder advances fence');
SELECT (robot_runtime.acquire_capability('mock','arm','r1','other')->>'fence')::bigint AS fence2 \gset
SELECT (robot_runtime.acquire_capability('mock','arm','shared','one',30,'shared')->>'fence')::bigint AS shared1 \gset
SELECT ok((robot_runtime.acquire_capability('mock','arm','shared','two',30,'shared')->>'fence')::bigint>:shared1,'shared owners receive increasing fences');
SELECT ok(robot_runtime.renew_capability('mock','arm','shared','one',:shared1),'new shared holder does not revoke existing shared lease');
SELECT is(robot_runtime.acquire_capability('mock','arm','shared','exclusive',30)->>'status','busy','exclusive lease cannot overlap shared holders');
RESET ROLE;

SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1)).activity_id AS retry_activity \gset
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'retry_activity',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect())));
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT id AS retry_effect,claim_token AS old_token FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2) \gset
RESET ROLE;
UPDATE robot_runtime.effect_outbox SET claim_expires_at=clock_timestamp()-interval '1 second' WHERE id=:'retry_effect';
SELECT robot_runtime.process_one();
SELECT is((SELECT status FROM robot_runtime.effect_outbox WHERE id=:'retry_effect'),'pending','idempotent expired claim becomes retryable');
SET LOCAL ROLE rr_adapter;
SELECT claim_token AS new_token FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2) \gset
SELECT isnt(:'old_token'::text,:'new_token'::text,'retry issues a fresh claim token');
SELECT is(robot_runtime.complete_effect(:'retry_effect',:'old_token','mock','other',:fence2,'succeeded')->>'status','stale','previous attempt cannot finish a reclaimed effect');
SELECT is(robot_runtime.complete_effect(:'retry_effect',:'new_token','mock','other',:fence2,'succeeded')->>'status','succeeded','current retry can complete');
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'retry_activity',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect('never'))));
RESET ROLE;
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT id AS never_effect,claim_token AS never_token FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2) \gset
RESET ROLE;
UPDATE robot_runtime.effect_outbox SET claim_expires_at=clock_timestamp()-interval '1 second' WHERE id=:'never_effect';
SELECT robot_runtime.process_one();
SELECT is((SELECT status FROM robot_runtime.effect_outbox WHERE id=:'never_effect'),'ambiguous','never-retry expiry preserves uncertainty');
SET LOCAL ROLE rr_adapter;
SELECT is((SELECT count(*) FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2)),0::bigint,'ambiguous effect is not blindly retried');
SELECT robot_runtime.reconcile_effect(:'never_effect','mock','other',:fence2,'failed');
RESET ROLE;
SELECT robot_runtime.process_one();

-- Replacement delivery cancels only pending work; ambiguous PL/pgSQL names
-- must not turn this normal transition into a reducer fault.
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'retry_activity',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(
  rr_test.effect()||'{"delivery":"latest_wins","replace_key":"position"}',
  rr_test.effect()||'{"delivery":"latest_wins","replace_key":"position"}')));
RESET ROLE;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'retry_activity'),'active','replacement effect transition remains valid');
SELECT is((SELECT count(*) FROM robot_runtime.effect_outbox WHERE activity_id=:'retry_activity' AND status='pending'),1::bigint,'latest_wins retains only last pending effect');
SET LOCAL ROLE rr_adapter;
SELECT id AS deadline_effect,claim_token AS deadline_token FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2) \gset
RESET ROLE;
UPDATE robot_runtime.effect_outbox SET deadline_at=clock_timestamp()-interval '1 second' WHERE id=:'deadline_effect';
SELECT robot_runtime.process_one();
SET LOCAL ROLE rr_adapter;
SELECT is(robot_runtime.complete_effect(:'deadline_effect',:'deadline_token','mock','other',:fence2,'succeeded')->>'status','stale','timeout winner rejects late success');
RESET ROLE;
SELECT is((SELECT status FROM robot_runtime.effect_outbox WHERE id=:'deadline_effect'),'timed_out','deadline does not imply success');

-- Explicit transaction abort must restore both inbox acknowledgement and state.
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'retry_activity',1)::robot_runtime.activity_ref,'add','{"value":5}');
RESET ROLE;
SAVEPOINT before_reduce;
SELECT robot_runtime.process_one();
ROLLBACK TO before_reduce;
SELECT is((SELECT count(*) FROM robot_runtime.activity_inbox WHERE activity_id=:'retry_activity' AND kind='add' AND status='pending'),1::bigint,'aborted reduction leaves intent pending');
SELECT robot_runtime.process_one();
SELECT is((SELECT state->>'count' FROM robot_runtime.activity_instance WHERE id=:'retry_activity'),'15','retried reduction commits exactly once');

-- Ownership and privilege changes do not change pg_get_functiondef.
SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1)).activity_id AS transferred \gset
RESET ROLE;
ALTER FUNCTION rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) OWNER TO rr_other;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'transferred'),'faulted','transferred reducer is rejected before execution');
ALTER FUNCTION rr_test.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) OWNER TO rr_owner;
SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1)).activity_id AS privileged \gset
RESET ROLE;
ALTER ROLE rr_owner BYPASSRLS;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'privileged'),'faulted','BYPASSRLS promotion invalidates registered reducer');
ALTER ROLE rr_owner NOBYPASSRLS;
SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1)).activity_id AS superowner \gset
RESET ROLE;
ALTER ROLE rr_owner SUPERUSER;
SELECT robot_runtime.process_one();
SELECT is((SELECT lifecycle FROM robot_runtime.activity_instance WHERE id=:'superowner'),'faulted','superuser promotion invalidates registered reducer');
ALTER ROLE rr_owner NOSUPERUSER;

-- Repeated gateway rotation removes expired holders but retains the fence.
SELECT robot_runtime.acquire_capability('mock','arm','rotation','old',30,'shared');
SELECT robot_runtime.acquire_capability('mock','arm','rotation','live',30,'shared');
SELECT fence AS rotation_fence FROM robot_runtime.capability_resource WHERE resource_key='rotation' \gset
UPDATE robot_runtime.capability_lease SET expires_at=clock_timestamp()-interval '1 second' WHERE resource_key='rotation' AND gateway='old';
SELECT robot_runtime.acquire_capability('mock','arm','rotation','new',30,'shared');
SELECT is((SELECT count(*) FROM robot_runtime.capability_lease WHERE resource_key='rotation'),2::bigint,'acquisition deletes expired holders and preserves live shared holders');
SELECT ok((SELECT fence>:rotation_fence FROM robot_runtime.capability_lease WHERE resource_key='rotation' AND gateway='new'),'pruning preserves monotonic fencing');
SELECT ok(NOT robot_runtime.renew_capability('mock','arm','rotation','old',:rotation_fence),'pruned holder cannot renew');

-- Two lower-UUID activities have blocked lanes. A batch of one must reach
-- the third activity even though the first two still contain pending effects.
SET LOCAL ROLE rr_owner;
SELECT (robot_runtime.start('counter',1,'{}','starvation')).activity_id;
SELECT (robot_runtime.start('counter',1,'{}','starvation')).activity_id;
SELECT (robot_runtime.start('counter',1,'{}','starvation')).activity_id;
RESET ROLE;
SELECT robot_runtime.process_one() FROM generate_series(1,3);
SELECT id AS blocked1 FROM robot_runtime.activity_instance WHERE label='starvation' ORDER BY id LIMIT 1 \gset
SELECT id AS blocked2 FROM robot_runtime.activity_instance WHERE label='starvation' ORDER BY id OFFSET 1 LIMIT 1 \gset
SELECT id AS eligible FROM robot_runtime.activity_instance WHERE label='starvation' ORDER BY id DESC LIMIT 1 \gset
SET LOCAL ROLE rr_owner;
SELECT robot_runtime.send(ROW(:'blocked1',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect(),rr_test.effect())));
SELECT robot_runtime.send(ROW(:'blocked2',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect(),rr_test.effect())));
SELECT robot_runtime.send(ROW(:'eligible',1)::robot_runtime.activity_ref,'emit',jsonb_build_object('effects',jsonb_build_array(rr_test.effect())));
RESET ROLE;
SELECT robot_runtime.process_one() FROM generate_series(1,3);
SET LOCAL ROLE rr_adapter;
SELECT robot_runtime.claim_effects('mock','arm','r1','other',:fence2,2);
RESET ROLE;
UPDATE robot_runtime.effect_outbox SET status='ambiguous' WHERE activity_id=:'blocked2' AND status='claimed';
SET LOCAL ROLE rr_adapter;
SELECT is((SELECT activity_id FROM robot_runtime.claim_effects('mock','arm','r1','other',:fence2,1)),:'eligible'::uuid,'blocked claimed and ambiguous lanes do not starve a later activity');
RESET ROLE;
SELECT is((SELECT count(*) FROM robot_runtime.effect_outbox WHERE activity_id IN (:'blocked1',:'blocked2') AND status='pending'),2::bigint,'blocked lane successors remain pending');

SELECT * FROM finish();
ROLLBACK;
