-- lifecycle: users SELECT own-agent; primary SELECT own (via anon membership) +
-- INSERT own; subconscious SELECT own + INSERT own (SELECT via service membership
-- -- log_event's INSERT ... RETURNING reads the row back under a SELECT policy);
-- service SELECT-only despite BYPASSRLS; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- Superuser setup (in-txn): one lifecycle row per agent.
INSERT INTO attobot.lifecycle(agent_id, event) VALUES (1, 'lc.primary'), (2, 'lc.subconscious');

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( has_table_privilege('attobot_anonymous','attobot.lifecycle','SELECT'),             'anonymous can SELECT lifecycle');
SELECT ok( NOT has_table_privilege('attobot_anonymous','attobot.lifecycle','INSERT'),         'anonymous CANNOT INSERT lifecycle');
SELECT ok( has_table_privilege('attobot_agent_primary','attobot.lifecycle','SELECT,INSERT'),  'primary can SELECT/INSERT lifecycle');
SELECT ok( has_table_privilege('attobot_agent_subconscious','attobot.lifecycle','SELECT,INSERT'), 'subconscious can SELECT/INSERT lifecycle (SELECT via service-granted policy)');
SELECT ok( NOT has_table_privilege('attobot_agent_primary','attobot.lifecycle','DELETE'),     'primary CANNOT DELETE lifecycle');
SELECT ok( has_table_privilege('attobot_service','attobot.lifecycle','SELECT'),               'service can SELECT lifecycle');
SELECT ok( NOT has_table_privilege('attobot_service','attobot.lifecycle','INSERT'),           'service CANNOT INSERT lifecycle (grant is SELECT-only)');
SELECT ok( has_table_privilege('attobot_dashboard','attobot.lifecycle','SELECT'),             'dashboard can SELECT lifecycle');

-- ===== READS (before any can() write) =======================================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.lifecycle$$),
          1::bigint, 'anonymous sees its own agent''s lifecycle');
SELECT is(pgtap_test.visible_count('attobot_anonymous', $$SELECT 1 FROM attobot.lifecycle WHERE agent_id=2$$),
          0::bigint, 'anonymous cannot see another agent''s lifecycle');
SELECT is(pgtap_test.visible_count('attobot_agent_primary', $$SELECT 1 FROM attobot.lifecycle$$),
          1::bigint, 'primary SELECT lifecycle works via inherited anonymous-policy membership');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.lifecycle$$),
          1::bigint, 'subconscious sees its OWN lifecycle (SELECT via service membership; log_event RETURNING needs it)');
SELECT is(pgtap_test.visible_count('attobot_agent_subconscious', $$SELECT 1 FROM attobot.lifecycle WHERE agent_id=1$$),
          0::bigint, 'subconscious cannot see primary''s lifecycle');

SELECT is(pgtap_test.visible_count('attobot_service', $$SELECT 1 FROM attobot.lifecycle$$),
          2::bigint, 'service sees all lifecycle');
SELECT is(pgtap_test.visible_count('attobot_dashboard', $$SELECT 1 FROM attobot.lifecycle$$),
          2::bigint, 'dashboard sees all lifecycle');

-- ===== WRITES ===============================================================
SELECT set_config('attobot.current_agent_id', '1', true);
SELECT ok(pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.lifecycle(agent_id, event) VALUES (1, 'lc.p.new')$$),
  'primary can INSERT its own lifecycle event');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$INSERT INTO attobot.lifecycle(agent_id, event) VALUES (2, 'lc.p.x')$$),
  'primary CANNOT INSERT lifecycle for another agent (RLS WITH CHECK)');
SELECT ok(NOT pgtap_test.can('attobot_agent_primary',
  $$DELETE FROM attobot.lifecycle WHERE agent_id = 1$$),
  'primary CANNOT DELETE lifecycle');

SELECT set_config('attobot.current_agent_id', '2', true);
SELECT ok(pgtap_test.can('attobot_agent_subconscious',
  $$INSERT INTO attobot.lifecycle(agent_id, event) VALUES (2, 'lc.s.new')$$),
  'subconscious can INSERT its own lifecycle event');

SELECT ok(NOT pgtap_test.can('attobot_service',
  $$INSERT INTO attobot.lifecycle(agent_id, event) VALUES (1, 'lc.svc')$$),
  'service CANNOT INSERT lifecycle (SELECT-only grant)');
SELECT ok(NOT pgtap_test.can('attobot_dashboard',
  $$INSERT INTO attobot.lifecycle(agent_id, event) VALUES (1, 'lc.d')$$),
  'dashboard CANNOT insert lifecycle');

SELECT * FROM finish();
ROLLBACK;
