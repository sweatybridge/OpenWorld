-- attotools.blobs: anonymous/authenticated full CRUD on own agent [DRIFT: README
-- says none]; primary same via anonymous membership; subconscious DENIED despite
-- grant [DRIFT]; service ALL; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('attobot_anonymous','attotools.blobs','SELECT,INSERT,UPDATE,DELETE'), '[DRIFT] anonymous has full CRUD on blobs (README says none)');
SELECT ok( has_table_privilege('attobot_agent_primary','attotools.blobs','SELECT,INSERT,UPDATE,DELETE'), 'primary has full CRUD on blobs (via anonymous membership)');
SELECT ok( has_table_privilege('attobot_service','attotools.blobs','SELECT,INSERT,UPDATE,DELETE'), 'service has full CRUD on blobs');
SELECT ok( has_table_privilege('attobot_dashboard','attotools.blobs','SELECT'), 'dashboard can SELECT blobs');
SELECT ok( NOT has_table_privilege('attobot_dashboard','attotools.blobs','INSERT'), 'dashboard CANNOT INSERT blobs');

-- ===== READS (before any can() write) =======================================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attotools.blobs$$),
          1::bigint, 'anonymous sees its own agent''s blobs');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attotools.blobs WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s blobs');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attotools.blobs$$),
          1::bigint, 'primary sees its own blobs');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attotools.blobs$$),
          0::bigint, '[DRIFT] subconscious CANNOT see blobs (policy is TO anon/auth; README claims own-agent)');

SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attotools.blobs$$),
          2::bigint, 'service sees all blobs');
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attotools.blobs$$),
          2::bigint, 'dashboard sees all blobs');

-- ===== WRITES ===============================================================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT ok(pgtap_test.can('attobot_anonymous',
  $$INSERT INTO attotools.blobs(agent_id, hash, content) VALUES (1, 'anon-ins', decode('00','hex'))$$),
  'anonymous can INSERT its own blob (WRITE_BLOB path)');
SELECT ok(pgtap_test.can('attobot_anonymous',
  $$UPDATE attotools.blobs SET content = content WHERE agent_id = 1$$),
  'anonymous can UPDATE its own blob');
SELECT ok(pgtap_test.can('attobot_anonymous',
  $$DELETE FROM attotools.blobs WHERE agent_id = 1 AND hash = 'anon-ins'$$),
  'anonymous can DELETE its own blob');

SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attotools.blobs(agent_id, hash, content) VALUES (1, 'pri-ins', decode('00','hex'))$$),
  'primary can INSERT its own blob');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT ok(NOT pgtap_test.can('attobot_agent_subconscious',
  $$INSERT INTO attotools.blobs(agent_id, hash, content) VALUES (2, 'sub-ins', decode('00','hex'))$$),
  '[DRIFT] subconscious CANNOT insert blobs (RLS denies despite inherited grant)');

SELECT ok(pgtap_test.can('attobot_service',
  $$DELETE FROM attotools.blobs WHERE agent_id = 2 AND hash = 'probe-subconscious'$$),
  'service can DELETE any blob');

SELECT ok(NOT pgtap_test.can('attobot_dashboard',
  $$INSERT INTO attotools.blobs(agent_id, hash, content) VALUES (1, 'd', decode('00','hex'))$$),
  'dashboard CANNOT insert blobs');

SELECT * FROM finish();
ROLLBACK;
