-- users (identity ledger): tiers SELECT their own row; primary SELECT all +
-- INSERT/UPDATE (no DELETE); subconscious SELECT all (inherited write GRANTs are
-- RLS-denied); service ALL; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- Bind the requesting user to alice (id looked up as superuser).
SELECT set_config('attobot.current_user_id',
                  (SELECT id::text FROM attobot.users WHERE external_id = '9001'), true);

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('attobot_anonymous','attobot.users','SELECT'),              'anonymous can SELECT users');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.users','INSERT'),          'anonymous CANNOT INSERT users');
SELECT ok( has_table_privilege('attobot_agent_primary','attobot.users','SELECT,INSERT,UPDATE'), 'primary can SELECT/INSERT/UPDATE users');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.users','DELETE'),      'primary CANNOT DELETE users');
SELECT ok( has_table_privilege('attobot_agent_subconscious','attobot.users','SELECT'),     'subconscious can SELECT users');
-- NB: subconscious INHERITS service's INSERT/UPDATE/DELETE grants (membership),
-- so the privilege check is true even though RLS denies the actual writes below.
SELECT ok( has_table_privilege('attobot_agent_subconscious','attobot.users','INSERT'),     'subconscious INHERITS INSERT on users from service (grant present; RLS still denies the write)');
SELECT ok( has_table_privilege('attobot_service','attobot.users','SELECT,INSERT,UPDATE,DELETE'), 'service has ALL on users');
SELECT ok( has_table_privilege('attobot_dashboard','attobot.users','SELECT'),              'dashboard can SELECT users');
SELECT ok( NOT has_table_privilege('attobot_dashboard','attobot.users','DELETE'),          'dashboard CANNOT DELETE users');

-- ===== READS (before any can() write) =======================================
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.users$$),
          1::bigint, 'anonymous sees only its own user row');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.users WHERE external_id='9002'$$),
          0::bigint, 'anonymous cannot see another user''s row');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.users$$),
          2::bigint, 'primary sees ALL users (resolve the requesting user during a turn)');
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.users$$),
          2::bigint, 'subconscious sees all users');
SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attobot.users$$),
          2::bigint, 'service sees all users');
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attobot.users$$),
          2::bigint, 'dashboard sees all users');

-- ===== WRITES ===============================================================
SELECT ok(NOT pgtap_test.can('attobot_anonymous',
  $$INSERT INTO attobot.users(channel, external_id, tier) VALUES ('telegram','9003','anonymous')$$),
  'anonymous CANNOT insert a user');

SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.users(channel, external_id, tier) VALUES ('telegram','9003','authenticated')$$),
  'primary can INSERT a user (e.g. promote tier)');
SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$UPDATE attobot.users SET display_name = 'Alice' WHERE external_id='9001'$$),
  'primary can UPDATE a user');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$DELETE FROM attobot.users WHERE external_id='9003'$$),
  'primary CANNOT delete a user');

SELECT ok(NOT pgtap_test.can('attobot_agent_subconscious',
  $$INSERT INTO attobot.users(channel, external_id, tier) VALUES ('telegram','9004','anonymous')$$),
  'subconscious CANNOT insert a user (RLS denies the inherited grant)');

SELECT ok(pgtap_test.can('attobot_service',
  $$DELETE FROM attobot.users WHERE external_id='9003'$$),
  'service can DELETE a user');

SELECT ok(NOT pgtap_test.can('attobot_dashboard',
  $$INSERT INTO attobot.users(channel, external_id, tier) VALUES ('telegram','9005','anonymous')$$),
  'dashboard CANNOT insert a user');

SELECT * FROM finish();
ROLLBACK;
