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
SELECT ok( has_table_privilege('attobot_anonymous','attobot.messages','SELECT'),             'anonymous can SELECT messages');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.messages','INSERT'),         'anonymous CANNOT INSERT messages [DRIFT: README says INSERT/UPDATE own]');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.messages','UPDATE'),         'anonymous CANNOT UPDATE messages');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.messages','DELETE'),         'anonymous CANNOT DELETE messages');
SELECT ok( has_table_privilege('attobot_agent_primary','attobot.messages','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE messages');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.messages','DELETE'),     'primary CANNOT DELETE messages');
SELECT ok( has_table_privilege('attobot_agent_subconscious','attobot.messages','SELECT,INSERT,UPDATE'), 'subconscious can SELECT/INSERT/UPDATE messages');
SELECT ok( has_table_privilege('attobot_service','attobot.messages','SELECT,INSERT,UPDATE,DELETE'),    'service has ALL on messages');
SELECT ok( has_table_privilege('attobot_dashboard','attobot.messages','SELECT'),             'dashboard can SELECT messages');
SELECT ok( NOT has_table_privilege('attobot_dashboard','attobot.messages','INSERT'),         'dashboard CANNOT INSERT messages');

-- ===== READS (before any can() write) =======================================
-- anonymous / authenticated (symmetric): chat-wide SELECT, fail-closed
SELECT set_config('attobot.current_agent_id', '', true);
SELECT set_config('attobot.current_chat_id', '', true);
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.messages$$),
          0::bigint, 'anonymous with no context sees nothing (fail-closed)');

SELECT set_config('attobot.current_agent_id', '1', true);
SELECT set_config('attobot.current_chat_id', 'CZ1', true);
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.messages WHERE agent_id=1 AND chat_id='CZ1'$$),
          2::bigint, 'anonymous sees the whole configured chat (user+assistant)');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.messages WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s messages');
SELECT is(pgtap_test.visible_count('attobot_authenticated', $$SELECT 1 FROM attobot.messages$$),
          2::bigint, 'authenticated sees the same configured chat as anonymous');

SELECT set_config('attobot.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.messages$$),
          2::bigint, 'primary sees its own agent''s messages');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.messages WHERE agent_id=2$$),
          0::bigint, 'primary cannot see subconscious''s messages');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.messages$$),
          1::bigint, 'subconscious sees its own agent''s messages');
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.messages WHERE agent_id=1$$),
          0::bigint, 'subconscious cannot see primary''s messages');

SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attobot.messages$$),
          3::bigint, 'service (BYPASSRLS) sees every message');
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attobot.messages$$),
          3::bigint, 'dashboard (BYPASSRLS) sees every message');

-- ===== WRITES ===============================================================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT set_config('attobot.current_chat_id', 'CZ1', true);
SELECT ok(NOT pgtap_test.can('attobot_anonymous',
  $$INSERT INTO attobot.messages(agent_id,role,content,chat_id,channel) VALUES (1,'user','x','CZ1','telegram')$$),
  'anonymous CANNOT insert a message (no INSERT grant)');

SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.messages(agent_id,role,content,chat_id,channel) VALUES (1,'assistant','t','CZ1','telegram')$$),
  'primary can INSERT its own-agent message');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.messages(agent_id,role,content,chat_id,channel) VALUES (2,'assistant','t','CZ2','telegram')$$),
  'primary CANNOT INSERT a message for another agent (RLS WITH CHECK)');
SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$UPDATE attobot.messages SET content = content WHERE agent_id = 1$$),
  'primary can UPDATE its own-agent messages');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$DELETE FROM attobot.messages WHERE agent_id = 1$$),
  'primary CANNOT DELETE messages');

SELECT ok(pgtap_test.can('attobot_service',
  $$DELETE FROM attobot.messages WHERE id < 0$$),
  'service can DELETE messages');

SELECT ok(NOT pgtap_test.can('attobot_dashboard',
  $$INSERT INTO attobot.messages(agent_id,role,content,chat_id,channel) VALUES (1,'user','x','CZ1','telegram')$$),
  'dashboard CANNOT insert messages');

SELECT * FROM finish();
ROLLBACK;
