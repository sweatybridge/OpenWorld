-- config: users read non-secret own rows only; agent roles read own INCLUDING
-- secrets and write own (no DELETE); service is BYPASSRLS and reads ALL secrets
-- [DRIFT: RBAC comment + README claim non-secret only]; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('attobot_anonymous','attobot.config','SELECT'),             'anonymous can SELECT config');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.config','INSERT'),         'anonymous CANNOT INSERT config');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.config','UPDATE'),         'anonymous CANNOT UPDATE config');
SELECT ok( has_table_privilege('attobot_agent_primary','attobot.config','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE config');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.config','DELETE'),     'primary CANNOT DELETE config');
SELECT ok( has_table_privilege('attobot_service','attobot.config','SELECT,INSERT,UPDATE,DELETE'), 'service has ALL on config');
SELECT ok( has_table_privilege('attobot_dashboard','attobot.config','SELECT'),             'dashboard can SELECT config');
SELECT ok( NOT has_table_privilege('attobot_dashboard','attobot.config','UPDATE'),         'dashboard CANNOT UPDATE config');

-- ===== anonymous: non-secret own only, secrets hidden =======================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.config WHERE secret$$),
          0::bigint, 'anonymous sees NO secret config rows (RLS hides them)');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.config WHERE key='probe_public' AND agent_id=1$$),
          1::bigint, 'anonymous sees its own non-secret config');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.config WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s config');
SELECT ok(NOT pgtap_test.can('attobot_anonymous',
  $$UPDATE attobot.config SET value = '"y"' WHERE agent_id=1 AND key='probe_public'$$),
  'anonymous CANNOT update config');

-- ===== agent roles: own incl. secrets, write own, no DELETE ==================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.config WHERE secret AND agent_id=1$$),
          1::bigint, 'primary reads its OWN secret config (api_key shape)');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.config WHERE agent_id=2$$),
          0::bigint, 'primary cannot read subconscious''s config');
SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.config(agent_id, key, value, secret) VALUES (1, 'live_key', '"v"', false)$$),
  'primary can INSERT its own config');
SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$UPDATE attobot.config SET value = '"v2"' WHERE agent_id=1 AND key='live_key'$$),
  'primary can UPDATE its own config');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$DELETE FROM attobot.config WHERE agent_id=1 AND key='live_key'$$),
  'primary CANNOT DELETE config');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.config(agent_id, key, value, secret) VALUES (2, 'live_key', '"v"', false)$$),
  'primary CANNOT write another agent''s config (RLS WITH CHECK)');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.config WHERE secret$$),
          1::bigint, 'subconscious reads only its OWN secret config (RLS-bound, not bypass)');

-- ===== service: BYPASSRLS reads ALL secrets [DRIFT] ==========================
SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attobot.config WHERE secret AND key='probe_secret'$$),
          2::bigint, '[DRIFT] service reads BOTH agents'' secret config (comment claims non-secret only)');
SELECT ok(pgtap_test.can('attobot_service',
  $$DELETE FROM attobot.config WHERE agent_id=1 AND key='live_key'$$),
  'service can DELETE config (full grant)');

-- ===== dashboard: read-all incl. secrets (app-layer redacts, DB does not) ====
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attobot.config WHERE secret AND key='probe_secret'$$),
          2::bigint, 'dashboard reads all config incl. secret rows (redaction is app-layer)');
SELECT ok(NOT pgtap_test.can('attobot_dashboard',
  $$DELETE FROM attobot.config WHERE agent_id=1 AND key='probe_public'$$),
  'dashboard CANNOT delete config (read-only)');

SELECT * FROM finish();
ROLLBACK;
