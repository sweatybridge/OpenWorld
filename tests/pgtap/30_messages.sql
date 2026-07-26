-- messages: users SELECT their whole configured chat (no writes); agent roles
-- SELECT/INSERT/UPDATE their own agent (no DELETE); service ALL; dashboard
-- read-all.
--
-- Structure: GRANT checks, then READ visibility (deterministic, run before any
-- can() write so counts reflect only fixtures), then WRITE capability.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('OpenWorld_anonymous','OpenWorld.messages','SELECT'),             'anonymous can SELECT messages');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.messages','INSERT'),         'anonymous CANNOT INSERT messages (users are SELECT-only; the agent appends on their behalf)');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.messages','UPDATE'),         'anonymous CANNOT UPDATE messages');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.messages','DELETE'),         'anonymous CANNOT DELETE messages');
SELECT ok( has_table_privilege('OpenWorld_agent_primary','OpenWorld.messages','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE messages');
SELECT ok( NOT has_table_privilege('OpenWorld_agent_primary','OpenWorld.messages','DELETE'),     'primary CANNOT DELETE messages');
SELECT ok( has_table_privilege('OpenWorld_agent_sidecar','OpenWorld.messages','SELECT,INSERT,UPDATE'), 'sidecar can SELECT/INSERT/UPDATE messages');
SELECT ok( has_table_privilege('OpenWorld_service','OpenWorld.messages','SELECT,INSERT,UPDATE,DELETE'),    'service has ALL on messages');
SELECT ok( has_table_privilege('OpenWorld_dashboard','OpenWorld.messages','SELECT'),             'dashboard can SELECT messages');
SELECT ok( NOT has_table_privilege('OpenWorld_dashboard','OpenWorld.messages','INSERT'),         'dashboard CANNOT INSERT messages');

-- ===== READS (before any can() write) =======================================
-- anonymous / authenticated (symmetric): chat-wide SELECT, fail-closed
SELECT set_config('OpenWorld.current_agent_id', '', true);
SELECT set_config('OpenWorld.current_chat_id', '', true);
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.messages$$),
          0::bigint, 'anonymous with no context sees nothing (fail-closed)');

SELECT set_config('OpenWorld.current_agent_id', '1', true);
SELECT set_config('OpenWorld.current_chat_id', 'CZ1', true);
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.messages WHERE agent_id=1 AND chat_id='CZ1'$$),
          2::bigint, 'anonymous sees the whole configured chat (user+assistant)');
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.messages WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s messages');
SELECT is(pgtap_test.visible_count('OpenWorld_authenticated', $$SELECT 1 FROM OpenWorld.messages$$),
          2::bigint, 'authenticated sees the same configured chat as anonymous');

SELECT set_config('OpenWorld.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('OpenWorld_agent_primary', $$SELECT 1 FROM OpenWorld.messages$$),
          2::bigint, 'primary sees its own agent''s messages');
SELECT is(pgtap_test.visible_count('OpenWorld_agent_primary', $$SELECT 1 FROM OpenWorld.messages WHERE agent_id=2$$),
          0::bigint, 'primary cannot see sidecar''s messages');

SELECT set_config('OpenWorld.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('OpenWorld_agent_sidecar', $$SELECT 1 FROM OpenWorld.messages$$),
          1::bigint, 'sidecar sees its own agent''s messages');
SELECT is(pgtap_test.visible_count('OpenWorld_agent_sidecar', $$SELECT 1 FROM OpenWorld.messages WHERE agent_id=1$$),
          0::bigint, 'sidecar cannot see primary''s messages');

SELECT is(pgtap_test.visible_count('OpenWorld_service', $$SELECT 1 FROM OpenWorld.messages$$),
          3::bigint, 'service (BYPASSRLS) sees every message');
SELECT is(pgtap_test.visible_count('OpenWorld_dashboard', $$SELECT 1 FROM OpenWorld.messages$$),
          3::bigint, 'dashboard (BYPASSRLS) sees every message');

-- ===== WRITES ===============================================================
SELECT set_config('OpenWorld.current_agent_id', '1', true);
SELECT set_config('OpenWorld.current_chat_id', 'CZ1', true);
SELECT ok(NOT pgtap_test.can('OpenWorld_anonymous',
  $$INSERT INTO OpenWorld.messages(agent_id,role,content,chat_id,channel) VALUES (1,'user','x','CZ1','telegram')$$),
  'anonymous CANNOT insert a message (no INSERT grant)');

SELECT ok(pgtap_test.can('OpenWorld_agent_primary',
  $$INSERT INTO OpenWorld.messages(agent_id,role,content,chat_id,channel) VALUES (1,'assistant','t','CZ1','telegram')$$),
  'primary can INSERT its own-agent message');
SELECT ok(NOT pgtap_test.can('OpenWorld_agent_primary',
  $$INSERT INTO OpenWorld.messages(agent_id,role,content,chat_id,channel) VALUES (2,'assistant','t','CZ2','telegram')$$),
  'primary CANNOT INSERT a message for another agent (RLS WITH CHECK)');
SELECT ok(pgtap_test.can('OpenWorld_agent_primary',
  $$UPDATE OpenWorld.messages SET content = content WHERE agent_id = 1$$),
  'primary can UPDATE its own-agent messages');
SELECT ok(NOT pgtap_test.can('OpenWorld_agent_primary',
  $$DELETE FROM OpenWorld.messages WHERE agent_id = 1$$),
  'primary CANNOT DELETE messages');

SELECT ok(pgtap_test.can('OpenWorld_service',
  $$DELETE FROM OpenWorld.messages WHERE id < 0$$),
  'service can DELETE messages');

SELECT ok(NOT pgtap_test.can('OpenWorld_dashboard',
  $$INSERT INTO OpenWorld.messages(agent_id,role,content,chat_id,channel) VALUES (1,'user','x','CZ1','telegram')$$),
  'dashboard CANNOT insert messages');

SELECT * FROM finish();
ROLLBACK;
