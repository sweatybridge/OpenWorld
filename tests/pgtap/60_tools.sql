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
  ow_tools._unwrap_tool_result((SELECT v FROM env)),
  jsonb_build_object('rows', jsonb_build_array(jsonb_build_object('tablename','agents')),
                     'row_count', 1)::text,
  'SQL: extracts rows[0].result, leaving the tool''s own {rows,row_count} flat'
);

-- BASH tool: envelope around plain stdout text.
SELECT is(
  ow_tools._unwrap_tool_result('{"rows":[{"result":"Linux 6.8.0"}],"row_count":1}'),
  'Linux 6.8.0',
  'BASH: extracts rows[0].result for a plain-text tool result'
);

-- df.result raised on failure → await_tool_calls' EXCEPTION branch stored an
-- 'error: ...' string with no envelope. rows[0].result is absent → pass through.
SELECT is(
  ow_tools._unwrap_tool_result('error: tool cancelled'),
  'error: tool cancelled',
  'a non-envelope error string passes through unchanged'
);

-- ============================================================================
-- send_photo/send_video/send_audio plumbing.
--   _hls_media: reconstruct media from an HLS playlist (ffmpeg.hls output).
--   _queue_send: shared tail — force the kind, queue, return a JSON summary.
--   _opt_*: read optional fields from the jsonb options bag.
-- The happy path needs ffmpeg.hls(url) (network) so it is NOT exercised here;
-- we cover the pure pieces: the error guards, kind-forcing (forced kind must
-- win over _attachment_kind's detection), and option parsing. The 1x1 PNG is a
-- real image so detection returns 'photo' (verified manually against
-- _attachment_kind), letting us assert forced 'video' != detected 'photo'.
-- ============================================================================

-- _hls_media rejects a NULL / unknown playlist before touching ffmpeg.concat
-- (so these are network-free). The error text is what the model sees via
-- run_tool_call_as_role's 'error: ...' wrapping.
SELECT throws_ok(
  $$SELECT ow_tools._hls_media(NULL)$$,
  'playlist_id is required',
  '_hls_media(NULL) raises before any ffmpeg call'
);
SELECT throws_ok(
  $$SELECT ow_tools._hls_media(999999)$$,
  'no HLS segments found for playlist_id 999999',
  '_hls_media(unknown id) raises with the id in the message'
);

-- _opt_* return the default when the key/options are absent, and the parsed
-- value when present. Guards the transform-option reads in the three tools.
SELECT is(ow_tools._opt_int(NULL, 'seconds', 7), 7,
  '_opt_int(NULL options) -> default');
SELECT is(ow_tools._opt_int('{"seconds":"3"}'::jsonb, 'seconds', 7), 3,
  '_opt_int reads a numeric-as-string value');
SELECT is(ow_tools._opt_float('{"t":"2.5"}'::jsonb, 't', 0.0), 2.5::float8,
  '_opt_float reads a float');
SELECT is(ow_tools._opt_bool('{"hwaccel":"true"}'::jsonb, 'hwaccel', false), true,
  '_opt_bool reads true');
SELECT is(ow_tools._opt_text('{"fmt":"jpeg"}'::jsonb, 'fmt', 'png'), 'jpeg',
  '_opt_text reads a string');

-- _queue_send: bind the primary agent (fixture id=1, which has a user message
-- in chat CZ1) and call it directly with a real PNG. forced kind 'video' must
-- be reported as kind even though detected is 'photo' — proving kind is fixed
-- by which tool was called, not by detection. The queued message insert runs
-- inside this BEGIN/ROLLBACK and the message triggers are disabled in setup.
\set png '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c63000100000005000100c0e9080a0000000049454e44ae426082'
SELECT set_config('ow.current_agent_id', '1', true);
CREATE TEMP TABLE _qr(j jsonb);
INSERT INTO _qr
SELECT ow_tools._queue_send('video', decode(:'png','hex'), 'raw', '', '', '')::jsonb;
SELECT is(j->>'queued', 'true', '_queue_send returns queued=true') FROM _qr;
SELECT is(j->>'kind', 'video', '_queue_send forces kind=video regardless of bytes') FROM _qr;
SELECT is(j->>'detected', 'photo', '_queue_send still reports detected=photo for a PNG') FROM _qr;
SELECT is(j->>'transform', 'raw', '_queue_send echoes the applied transform') FROM _qr;

SELECT * FROM finish();
ROLLBACK;
