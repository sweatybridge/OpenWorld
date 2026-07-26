-- memory + memory_sources: anonymous none; primary ALL own-agent; sidecar
-- ALL across agents; service ALL; dashboard read-all.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- Superuser setup (in-txn): link exactly one message to each agent's memory so
-- memory_sources visibility is testable without PK collisions later.
INSERT INTO ow.memory_sources(memory_id, agent_id, message_id)
SELECT DISTINCT ON (m.agent_id) m.id, m.agent_id, msg.id
FROM ow.memory m
JOIN ow.messages msg ON msg.agent_id = m.agent_id
WHERE m.agent_id IN (1, 2)
ORDER BY m.agent_id;

-- ----- GRANT shape -----------------------------------------------------------
SELECT ok( NOT has_table_privilege('ow_anonymous','ow.memory','SELECT'), 'anonymous has NO SELECT on memory');
SELECT ok( has_table_privilege('ow_agent_primary','ow.memory','SELECT,INSERT,UPDATE,DELETE'), 'primary has ALL on memory');
SELECT ok( has_table_privilege('ow_agent_sidecar','ow.memory','SELECT,INSERT,UPDATE,DELETE'), 'sidecar has ALL on memory');
SELECT ok( has_table_privilege('ow_service','ow.memory','SELECT,INSERT,UPDATE,DELETE'), 'service has ALL on memory');
SELECT ok( has_table_privilege('ow_dashboard','ow.memory','SELECT'), 'dashboard can SELECT memory');
SELECT ok( NOT has_table_privilege('ow_dashboard','ow.memory','INSERT'), 'dashboard CANNOT INSERT memory');
SELECT ok( NOT has_table_privilege('ow_anonymous','ow.memory_sources','SELECT'), 'anonymous has NO SELECT on memory_sources');

-- ===== READS (before any can() write) =======================================
-- anonymous: no grant -> statement raises -> visible_count = -1
SELECT is(pgtap_test.visible_count('ow_anonymous', $$SELECT 1 FROM ow.memory$$),
          -1::bigint, 'anonymous SELECT memory is denied (no grant)');

SELECT set_config('ow.current_agent_id', '1', true);
SELECT is(pgtap_test.visible_count('ow_agent_primary', $$SELECT 1 FROM ow.memory$$),
          1::bigint, 'primary sees its own memory');
SELECT is(pgtap_test.visible_count('ow_agent_primary', $$SELECT 1 FROM ow.memory WHERE agent_id=2$$),
          0::bigint, 'primary cannot see sidecar''s memory');
SELECT is(pgtap_test.visible_count('ow_agent_primary', $$SELECT 1 FROM ow.memory_sources$$),
          1::bigint, 'primary sees its own memory_sources');

SELECT set_config('ow.current_agent_id', '2', true);
SELECT is(pgtap_test.visible_count('ow_agent_sidecar', $$SELECT 1 FROM ow.memory$$),
          2::bigint, 'sidecar sees EVERY agent''s memory');
SELECT is(pgtap_test.visible_count('ow_agent_sidecar', $$SELECT 1 FROM ow.memory_sources$$),
          2::bigint, 'sidecar sees EVERY agent''s memory_sources');

SELECT is(pgtap_test.visible_count('ow_service', $$SELECT 1 FROM ow.memory$$),
          2::bigint, 'service sees all memory');
SELECT is(pgtap_test.visible_count('ow_service', $$SELECT 1 FROM ow.memory_sources$$),
          2::bigint, 'service sees all memory_sources');
SELECT is(pgtap_test.visible_count('ow_dashboard', $$SELECT 1 FROM ow.memory$$),
          2::bigint, 'dashboard sees all memory');

-- ===== WRITES ===============================================================
SELECT set_config('ow.current_agent_id', '1', true);
SELECT ok(pgtap_test.can('ow_agent_primary',
  $$INSERT INTO ow.memory(agent_id, content) VALUES (1, 'p-mem')$$),
  'primary can INSERT its own memory');
SELECT ok(NOT pgtap_test.can('ow_agent_primary',
  $$INSERT INTO ow.memory(agent_id, content) VALUES (2, 'p-mem-x')$$),
  'primary CANNOT INSERT memory for another agent (RLS WITH CHECK)');
SELECT ok(pgtap_test.can('ow_agent_primary',
  $$UPDATE ow.memory SET content = content WHERE agent_id = 1$$),
  'primary can UPDATE its own memory');
SELECT ok(pgtap_test.can('ow_agent_primary',
  $$DELETE FROM ow.memory WHERE agent_id = 1 AND content = 'p-mem'$$),
  'primary can DELETE its own memory');
-- INSERT a memory_source via a fresh memory row (avoids the (memory_id,message_id) PK conflict)
SELECT ok(pgtap_test.can('ow_agent_primary',
  $$WITH nm AS (INSERT INTO ow.memory(agent_id, content) VALUES (1,'ms-new') RETURNING id)
    INSERT INTO ow.memory_sources(memory_id, agent_id, message_id)
    SELECT nm.id, 1, (SELECT id FROM ow.messages WHERE agent_id=1 LIMIT 1) FROM nm$$),
  'primary can INSERT its own memory_sources');

SELECT set_config('ow.current_agent_id', '2', true);
SELECT ok(pgtap_test.can('ow_agent_sidecar',
  $$INSERT INTO ow.memory(agent_id, content) VALUES (1, 's-corrects-primary')$$),
  'sidecar can INSERT memory for primary (review/correct)');

SELECT * FROM finish();
ROLLBACK;
