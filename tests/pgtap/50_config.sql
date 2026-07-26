-- config: users read non-secret own rows only; agent roles read own INCLUDING
-- secrets and write own (no DELETE); service (the sidecar's LLM-SQL scope)
-- has NO grant on the base table and reads non-secret rows only via the
-- config_public view; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('OpenWorld_anonymous','OpenWorld.config','SELECT'),             'anonymous can SELECT config');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.config','INSERT'),         'anonymous CANNOT INSERT config');
SELECT ok( NOT has_table_privilege('OpenWorld_anonymous','OpenWorld.config','UPDATE'),         'anonymous CANNOT UPDATE config');
SELECT ok( has_table_privilege('OpenWorld_agent_primary','OpenWorld.config','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE config');
SELECT ok( NOT has_table_privilege('OpenWorld_agent_primary','OpenWorld.config','DELETE'),     'primary CANNOT DELETE config');
SELECT ok( NOT has_table_privilege('OpenWorld_service','OpenWorld.config','SELECT'), 'service has NO SELECT on base config (secrets kept out of the tool scope)');
SELECT ok( has_table_privilege('OpenWorld_service','OpenWorld.config_public','SELECT'), 'service can SELECT config_public (non-secret view)');
SELECT ok( has_table_privilege('OpenWorld_dashboard','OpenWorld.config','SELECT'),             'dashboard can SELECT config');
SELECT ok( NOT has_table_privilege('OpenWorld_dashboard','OpenWorld.config','UPDATE'),         'dashboard CANNOT UPDATE config');

-- ===== anonymous: non-secret own only, secrets hidden =======================
SELECT set_config('OpenWorld.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.config WHERE secret$$),
          0::bigint, 'anonymous sees NO secret config rows (RLS hides them)');
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.config WHERE key='probe_public' AND agent_id=1$$),
          1::bigint, 'anonymous sees its own non-secret config');
SELECT is(pgtap_test.visible_count('OpenWorld_anonymous', $$SELECT 1 FROM OpenWorld.config WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s config');
SELECT ok(NOT pgtap_test.can('OpenWorld_anonymous',
  $$UPDATE OpenWorld.config SET value = '"y"' WHERE agent_id=1 AND key='probe_public'$$),
  'anonymous CANNOT update config');

-- ===== agent roles: own incl. secrets, write own, no DELETE ==================
SELECT set_config('OpenWorld.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('OpenWorld_agent_primary', $$SELECT 1 FROM OpenWorld.config WHERE secret AND agent_id=1$$),
          1::bigint, 'primary reads its OWN secret config (api_key shape)');
SELECT is(pgtap_test.visible_count('OpenWorld_agent_primary', $$SELECT 1 FROM OpenWorld.config WHERE agent_id=2$$),
          0::bigint, 'primary cannot read sidecar''s config');
SELECT ok(pgtap_test.can('OpenWorld_agent_primary',
  $$INSERT INTO OpenWorld.config(agent_id, key, value, secret) VALUES (1, 'live_key', '"v"', false)$$),
  'primary can INSERT its own config');
SELECT ok(pgtap_test.can('OpenWorld_agent_primary',
  $$UPDATE OpenWorld.config SET value = '"v2"' WHERE agent_id=1 AND key='live_key'$$),
  'primary can UPDATE its own config');
SELECT ok(NOT pgtap_test.can('OpenWorld_agent_primary',
  $$DELETE FROM OpenWorld.config WHERE agent_id=1 AND key='live_key'$$),
  'primary CANNOT DELETE config');
SELECT ok(NOT pgtap_test.can('OpenWorld_agent_primary',
  $$INSERT INTO OpenWorld.config(agent_id, key, value, secret) VALUES (2, 'live_key', '"v"', false)$$),
  'primary CANNOT write another agent''s config (RLS WITH CHECK)');

SELECT set_config('OpenWorld.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('OpenWorld_agent_sidecar', $$SELECT 1 FROM OpenWorld.config WHERE secret$$),
          1::bigint, 'sidecar reads only its OWN secret config (RLS-bound, not bypass)');

-- ===== service: secret-free tool scope (non-secret via config_public) =========
-- service has NO grant on the base config table, so it cannot reach secret rows
-- at all — the LLM SQL tool (which runs as service) must never see api_key /
-- telegram_token. It reads non-secret rows only through the config_public view.
SELECT is(pgtap_test.visible_count('OpenWorld_service', $$SELECT 1 FROM OpenWorld.config$$),
          -1::bigint, 'service has no SELECT on base config (permission denied; secrets unreachable)');
SELECT is(pgtap_test.visible_count('OpenWorld_service', $$SELECT 1 FROM OpenWorld.config_public WHERE key='probe_public'$$),
          2::bigint, 'service reads non-secret config via config_public (2 probe_public rows)');
SELECT is(pgtap_test.visible_count('OpenWorld_service', $$SELECT 1 FROM OpenWorld.config_public WHERE key='probe_secret'$$),
          0::bigint, 'config_public hides the secret probe_secret rows (view filters them out)');
SELECT ok(NOT pgtap_test.can('OpenWorld_service',
  $$DELETE FROM OpenWorld.config WHERE agent_id=1 AND key='probe_public'$$),
  'service CANNOT delete config (no grant on the base table)');

-- ===== dashboard: read-all incl. secrets (app-layer redacts, DB does not) ====
SELECT is(pgtap_test.visible_count('OpenWorld_dashboard', $$SELECT 1 FROM OpenWorld.config WHERE secret AND key='probe_secret'$$),
          2::bigint, 'dashboard reads all config incl. secret rows (redaction is app-layer)');
SELECT ok(NOT pgtap_test.can('OpenWorld_dashboard',
  $$DELETE FROM OpenWorld.config WHERE agent_id=1 AND key='probe_public'$$),
  'dashboard CANNOT delete config (read-only)');

SELECT * FROM finish();
ROLLBACK;
