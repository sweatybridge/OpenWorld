-- tools: the df.result() envelope unwrap. await_tool_calls pulls each tool call's
-- result from df.result(v_id), which wraps the one-row node SELECT
-- `SELECT ... AS result` as {"rows":[{"result": <text>}],"row_count":1}. The
-- tool's own output (_tool_sql's {"rows":...,"row_count":...}, BASH stdout, an
-- error string) lives at rows[0].result; _unwrap_tool_result must extract it.
-- A prior version read a nonexistent top-level `result` key, so coalesce fell
-- through and the whole envelope was stored — replaying a double-wrapped blob
-- ({"rows":[{"result":"{\"rows\":...}"}]}) to the LLM every turn.
--
-- Pure unit: await_tool_calls itself needs df.start / wait_for_completion, which
-- the test harness can't run (superuser-owned durable instances are forbidden),
-- so we drive _unwrap_tool_result directly with df.result-shaped inputs.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- SQL tool: envelope around _tool_sql's {"rows":...,"row_count":...}. Build both
-- sides with jsonb so key order/whitespace can't cause a spurious mismatch; the
-- expected string is exactly rows[0].result, so equality means no double nesting.
WITH env AS (
  SELECT jsonb_build_object(
           'rows', jsonb_build_array(jsonb_build_object('result',
             jsonb_build_object('rows', jsonb_build_array(jsonb_build_object('tablename','agents')),
                                'row_count', 1)::text)),
           'row_count', 1
         )::text AS v
)
SELECT is(
  attotools._unwrap_tool_result((SELECT v FROM env)),
  jsonb_build_object('rows', jsonb_build_array(jsonb_build_object('tablename','agents')),
                     'row_count', 1)::text,
  'SQL: extracts rows[0].result, leaving the tool''s own {rows,row_count} flat'
);

-- BASH tool: envelope around plain stdout text.
SELECT is(
  attotools._unwrap_tool_result('{"rows":[{"result":"Linux 6.8.0"}],"row_count":1}'),
  'Linux 6.8.0',
  'BASH: extracts rows[0].result for a plain-text tool result'
);

-- df.result raised on failure → await_tool_calls' EXCEPTION branch stored an
-- 'error: ...' string with no envelope. rows[0].result is absent → pass through.
SELECT is(
  attotools._unwrap_tool_result('error: tool cancelled'),
  'error: tool cancelled',
  'a non-envelope error string passes through unchanged'
);

SELECT * FROM finish();
ROLLBACK;
