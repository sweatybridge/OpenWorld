-- users (identity ledger): tiers SELECT their own row; primary SELECT all +
-- INSERT/UPDATE (no DELETE); sidecar SELECT all (inherited write GRANTs are
-- RLS-denied); service ALL; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- Bind the requesting user to alice (id looked up as superuser).
SELECT set_config('ow.current_user_id',
                  (SELECT id::text FROM ow.users WHERE external_id = '9001'), true);

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('ow_anonymous','ow.users','SELECT'),              'anonymous can SELECT users');
SELECT ok( NOT has_table_privilege('ow_anonymous','ow.users','INSERT'),          'anonymous CANNOT INSERT users');
SELECT ok( has_table_privilege('ow_agent_primary','ow.users','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE users');
SELECT ok( NOT has_table_privilege('ow_agent_primary','ow.users','DELETE'),      'primary CANNOT DELETE users');
SELECT ok( has_table_privilege('ow_agent_sidecar','ow.users','SELECT'),     'sidecar can SELECT users');
-- NB: sidecar INHERITS service's INSERT/UPDATE/DELETE grants (membership),
-- so the privilege check is true even though RLS denies the actual writes below.
SELECT ok( has_table_privilege('ow_agent_sidecar','ow.users','INSERT'),     'sidecar INHERITS INSERT on users from service (grant present; RLS still denies the write)');
SELECT ok( has_table_privilege('ow_service','ow.users','SELECT,INSERT,UPDATE,DELETE'), 'service has ALL on users');
SELECT ok( has_table_privilege('ow_dashboard','ow.users','SELECT'),              'dashboard can SELECT users');
SELECT ok( NOT has_table_privilege('ow_dashboard','ow.users','DELETE'),          'dashboard CANNOT DELETE users');

-- ===== READS (before any can() write) =======================================
SELECT is(pgtap_test.visible_count('ow_anonymous', $$SELECT 1 FROM ow.users$$),
          1::bigint, 'anonymous sees only its own user row');
SELECT is(pgtap_test.visible_count('ow_anonymous', $$SELECT 1 FROM ow.users WHERE external_id='9002'$$),
          0::bigint, 'anonymous cannot see another user''s row');
SELECT is(pgtap_test.visible_count('ow_agent_primary', $$SELECT 1 FROM ow.users$$),
          2::bigint, 'primary sees ALL users (resolve the requesting user during a turn)');
SELECT is(pgtap_test.visible_count('ow_agent_sidecar', $$SELECT 1 FROM ow.users$$),
          2::bigint, 'sidecar sees all users');
SELECT is(pgtap_test.visible_count('ow_service', $$SELECT 1 FROM ow.users$$),
          2::bigint, 'service sees all users');
SELECT is(pgtap_test.visible_count('ow_dashboard', $$SELECT 1 FROM ow.users$$),
          2::bigint, 'dashboard sees all users');

-- ===== WRITES ===============================================================
SELECT ok(NOT pgtap_test.can('ow_anonymous',
  $$INSERT INTO ow.users(channel, external_id, tier) VALUES ('telegram','9003','anonymous')$$),
  'anonymous CANNOT insert a user');

SELECT ok(pgtap_test.can('ow_agent_primary',
  $$INSERT INTO ow.users(channel, external_id, tier) VALUES ('telegram','9003','authenticated')$$),
  'primary can INSERT a user (e.g. promote tier)');
SELECT ok(pgtap_test.can('ow_agent_primary',
  $$UPDATE ow.users SET display_name = 'Alice' WHERE external_id='9001'$$),
  'primary can UPDATE a user');
SELECT ok(NOT pgtap_test.can('ow_agent_primary',
  $$DELETE FROM ow.users WHERE external_id='9003'$$),
  'primary CANNOT delete a user');

SELECT ok(NOT pgtap_test.can('ow_agent_sidecar',
  $$INSERT INTO ow.users(channel, external_id, tier) VALUES ('telegram','9004','anonymous')$$),
  'sidecar CANNOT insert a user (RLS denies the inherited grant)');

SELECT ok(pgtap_test.can('ow_service',
  $$DELETE FROM ow.users WHERE external_id='9003'$$),
  'service can DELETE a user');

SELECT ok(NOT pgtap_test.can('ow_dashboard',
  $$INSERT INTO ow.users(channel, external_id, tier) VALUES ('telegram','9005','anonymous')$$),
  'dashboard CANNOT insert a user');

SELECT * FROM finish();
ROLLBACK;
