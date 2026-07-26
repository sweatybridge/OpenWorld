-- tracing: instance_index label parser + turn_trigger_id resolution + the
-- dashboard read grants on the new tracing objects.
--
-- The RBAC test harness never creates df.instances (superuser-owned instances
-- are forbidden and the message triggers are disabled), so the loop/dedup
-- behaviour is verified end-to-end against the live DB instead. What we CAN pin
-- down here are the pure units the view and trace_turn delegate to — the label
-- parser and the trigger resolver — plus the grant shape. Those are exactly the
-- pieces a regex typo or message-walk regression would break.
--
-- Fixtures (00_fixtures.sql, ids are deterministic): primary=agent 1 has
-- user@1 + assistant@2; sidecar=agent 2 has user@3.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- ===== object presence (built-in catalog lookups; has_view/has_function in
-- this pgTAP build return text, so wrap regclass/regprocedure checks in ok) ==
SELECT ok(to_regclass('OpenWorld.instance_index') IS NOT NULL, 'instance_index view exists');
SELECT ok(to_regprocedure('OpenWorld.trace_turn(bigint)') IS NOT NULL, 'trace_turn(bigint) exists');
SELECT ok(to_regprocedure('OpenWorld.turn_trigger_id(bigint)') IS NOT NULL, 'turn_trigger_id(bigint) exists');
SELECT ok(to_regprocedure('OpenWorld.parse_instance_label(text)') IS NOT NULL, 'parse_instance_label(text) exists');

-- ===== parse_instance_label ================================================
-- legacy loop label (no id) — must still classify, backward compat
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop')), 'loop',     'legacy loop: kind');
SELECT is((SELECT agent_slug FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop')), 'primary',  'legacy loop: agent');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop')), NULL::bigint, 'legacy loop: no message_id');

-- new loop label embeds the trigger message id (the whole point of this change)
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop:42')), 'loop',    'loop:<id>: kind');
SELECT is((SELECT agent_slug FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop:42')), 'primary', 'loop:<id>: agent');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:primary:loop:42')), 42::bigint, 'loop:<id>: message_id');

SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:sidecar:loop:99')), 'loop',         'sidecar loop:<id>: kind');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:sidecar:loop:99')), 99::bigint,     'sidecar loop:<id>: message_id');

-- inbox / cron carry agent but no message id
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:primary:inbox')),     'inbox',    'inbox: kind');
SELECT is((SELECT agent_slug FROM OpenWorld.parse_instance_label('OpenWorld:primary:inbox')),     'primary',  'inbox: agent');
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:sidecar:cron:review')), 'cron',        'cron: kind');
SELECT is((SELECT agent_slug FROM OpenWorld.parse_instance_label('OpenWorld:sidecar:cron:review')), 'sidecar', 'cron: agent');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:sidecar:cron:review')), NULL::bigint, 'cron: no message_id');

-- send / typing: message id, no agent
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:send:42')),   'send',    'send: kind');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:send:42')),   42::bigint,'send: message_id');
SELECT is((SELECT agent_slug FROM OpenWorld.parse_instance_label('OpenWorld:send:42')),   NULL,      'send: no agent');
SELECT is((SELECT kind       FROM OpenWorld.parse_instance_label('OpenWorld:typing:7')),  'typing',  'typing: kind');
SELECT is((SELECT message_id FROM OpenWorld.parse_instance_label('OpenWorld:typing:7')),  7::bigint, 'typing: message_id');

-- tool: message id + tool_call_id, no agent
SELECT is((SELECT kind        FROM OpenWorld.parse_instance_label('OpenWorld:tool:42:call_abc')), 'tool',      'tool: kind');
SELECT is((SELECT message_id  FROM OpenWorld.parse_instance_label('OpenWorld:tool:42:call_abc')), 42::bigint,  'tool: message_id');
SELECT is((SELECT tool_call_id FROM OpenWorld.parse_instance_label('OpenWorld:tool:42:call_abc')), 'call_abc',  'tool: tool_call_id');
SELECT is((SELECT agent_slug  FROM OpenWorld.parse_instance_label('OpenWorld:tool:42:call_abc')), NULL,        'tool: no agent');

-- fallback buckets
SELECT is((SELECT kind FROM OpenWorld.parse_instance_label('OpenWorld:weird:thing')), 'OpenWorld', 'unknown OpenWorld:* → OpenWorld');
SELECT is((SELECT kind FROM OpenWorld.parse_instance_label('totally-unrelated')),   'other',   'non-OpenWorld label → other');

-- ===== turn_trigger_id =====================================================
SELECT is(OpenWorld.turn_trigger_id(1),     1::bigint, 'user message is its own trigger (primary user@1)');
SELECT is(OpenWorld.turn_trigger_id(2),     1::bigint, 'assistant resolves back to its turn trigger (assistant@2 → user@1)');
SELECT is(OpenWorld.turn_trigger_id(3),     3::bigint, 'sidecar user@3 is its own trigger');
SELECT is(OpenWorld.turn_trigger_id(99999), NULL,      'unknown message id → NULL');

-- ===== trace_turn (executes the RETURN QUERY — catches OUT-column type       =====
--       mismatches, e.g. df.instances.id is varchar not text). No instances exist
--       in the test DB, so every call yields zero rows without error.
SELECT is((SELECT count(*)::bigint FROM OpenWorld.trace_turn(1)),     0::bigint, 'trace_turn(trigger) runs clean, 0 rows (no instances)');
SELECT is((SELECT count(*)::bigint FROM OpenWorld.trace_turn(2)),     0::bigint, 'trace_turn(assistant) runs clean, 0 rows');
SELECT is((SELECT count(*)::bigint FROM OpenWorld.trace_turn(99999)), 0::bigint, 'trace_turn(unknown id) → 0 rows (NULL trigger short-circuits)');

-- ===== dashboard grants ====================================================
SELECT ok( has_table_privilege('OpenWorld_dashboard','OpenWorld.instance_index','SELECT'),     'dashboard SELECT instance_index');
SELECT ok( NOT has_table_privilege('OpenWorld_dashboard','OpenWorld.instance_index','INSERT'), 'dashboard CANNOT INSERT instance_index (read-only)');
SELECT ok( has_function_privilege('OpenWorld_dashboard','OpenWorld.trace_turn(bigint)','EXECUTE'),           'dashboard EXECUTE trace_turn');
SELECT ok( has_function_privilege('OpenWorld_dashboard','OpenWorld.turn_trigger_id(bigint)','EXECUTE'),      'dashboard EXECUTE turn_trigger_id');
SELECT ok( has_function_privilege('OpenWorld_dashboard','OpenWorld.parse_instance_label(text)','EXECUTE'),   'dashboard EXECUTE parse_instance_label');
-- Note: like all OpenWorld functions these are EXECUTE-by-PUBLIC (Postgres default),
-- which is safe — they are read-only SECURITY INVOKER, so a caller only sees rows
-- RLS already permits. The meaningful gate is the SELECT on the view, asserted above.

SELECT * FROM finish();
ROLLBACK;
