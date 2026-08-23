-- GENERATE_VIDEO: the sdcpp video-generation tool. The happy path needs a live
-- stable-diffusion.cpp server + df.start (polling a real job), which the test
-- harness can't run. So we cover the pure pieces: the df.http-envelope status
-- terminality check, poll-URL construction, the error-result builder, the
-- finalize branches (including completed queueing under RLS), and the graph
-- BUILD (config-gated, endpoint/chat_id baked in as literals — no df.start).
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

-- _sdcpp_job_terminal: a df.http envelope {status, body, ok, ...}. Terminal when
-- the call did not succeed (ok=false, e.g. 404 gone) OR the job body status is
-- completed/failed/cancelled.
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":200,"ok":true,"body":"{\"id\":\"j1\",\"status\":\"queued\"}"}'::jsonb), false,
  'queued job is not terminal');
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":200,"ok":true,"body":"{\"id\":\"j1\",\"status\":\"generating\"}"}'::jsonb), false,
  'generating job is not terminal');
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":200,"ok":true,"body":"{\"id\":\"j1\",\"status\":\"completed\"}"}'::jsonb), true,
  'completed job is terminal');
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":200,"ok":true,"body":"{\"id\":\"j1\",\"status\":\"failed\"}"}'::jsonb), true,
  'failed job is terminal');
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":200,"ok":true,"body":"{\"id\":\"j1\",\"status\":\"cancelled\"}"}'::jsonb), true,
  'cancelled job is terminal');
SELECT is(ow_tools._sdcpp_job_terminal(
  '{"status":404,"ok":false,"body":""}'::jsonb), true,
  'non-ok http (404 gone) is terminal');

-- _sdcpp_job_url: prefix the configured base onto the submission's poll_url.
SELECT is(ow_tools._sdcpp_job_url('http://sdcpp.test',
  '{"ok":true,"body":"{\"poll_url\":\"/sdcpp/v1/jobs/j1\"}"}'::jsonb),
  'http://sdcpp.test/sdcpp/v1/jobs/j1',
  'poll_url is prefixed with the base');
SELECT is(ow_tools._sdcpp_job_url('http://sdcpp.test/',
  '{"ok":true,"body":"{\"poll_url\":\"/sdcpp/v1/jobs/j1\"}"}'::jsonb),
  'http://sdcpp.test/sdcpp/v1/jobs/j1',
  'a trailing slash on the base is trimmed');
SELECT throws_ok(
  $$SELECT ow_tools._sdcpp_job_url('http://sdcpp.test', '{"ok":true,"body":"{}"}'::jsonb)$$,
  'vid_gen submission returned no poll_url',
  'raises when the submission returned no poll_url');

-- _sdcpp_error_result: tool result for a non-202 submission.
SELECT is((ow_tools._sdcpp_error_result(
  '{"status":400,"ok":false,"body":"unsupported model mode"}'::jsonb)::jsonb)->>'error',
  'vid_gen submission failed',
  'error_result labels the submission failure');
SELECT is((ow_tools._sdcpp_error_result(
  '{"status":429,"ok":false,"body":"queue full"}'::jsonb)::jsonb)->>'http_status',
  '429',
  'error_result echoes the http status');

-- _sdcpp_finalize_video: the failed/cancelled branch returns a summary WITHOUT
-- raising and never reaches queue_outbound (no agent/chat context required).
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"failed\",\"error\":{\"code\":\"generation_failed\",\"message\":\"boom\"}}"}'::jsonb)::jsonb)->>'queued',
  'false',
  'finalize on a failed job returns queued=false');
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"failed\",\"error\":{\"code\":\"generation_failed\",\"message\":\"boom\"}}"}'::jsonb)::jsonb)->>'status',
  'failed',
  'finalize echoes the job status');
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"failed\",\"error\":{\"code\":\"generation_failed\",\"message\":\"boom\"}}"}'::jsonb)::jsonb)->'error'->>'code',
  'generation_failed',
  'finalize surfaces the sdcpp error code');

-- _sdcpp_finalize_video: the completed branch queues an outbound video. Runs in
-- the BEGIN/ROLLBACK so the queued system message is discarded. queue_outbound_
-- attachment is SECURITY DEFINER under agent-scoped RLS. Clear the agent GUC to
-- model the polling node's fresh transaction and prove finalize binds it itself.
SELECT set_config('ow.current_agent_id', '', true);
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"completed\",\"result\":{\"b64_json\":\"AAAA\",\"mime_type\":\"video/webm\",\"output_format\":\"webm\",\"fps\":16,\"frame_count\":33}}"}'::jsonb,
  p_caption => 'a clip')::jsonb)->>'queued',
  'true',
  'finalize on a completed job queues the video (queued=true)');
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"completed\",\"result\":{\"b64_json\":\"AAAA\",\"mime_type\":\"video/webm\",\"output_format\":\"webm\",\"fps\":16,\"frame_count\":33}}"}'::jsonb,
  p_caption => 'a clip')::jsonb)->>'output_format',
  'webm',
  'finalize result echoes the container output_format');
SELECT is((ow_tools._sdcpp_finalize_video('primary',
  '{"ok":true,"body":"{\"status\":\"completed\",\"result\":{\"b64_json\":\"AAAA\",\"mime_type\":\"image/webp\",\"output_format\":\"webp\",\"fps\":8,\"frame_count\":9}}"}'::jsonb)::jsonb)->>'mime_type',
  'image/webp',
  'finalize result echoes the container mime_type (webp)');

-- _tool_generate_video: error returns + graph build. The build reads agent
-- config under RLS+GUC; we run as the superuser test session (BYPASSRLS) and
-- bind the agent GUC to the fixture primary (id=1).
SELECT set_config('ow.current_agent_id', '1', true);

SELECT matches(ow_tools._tool_generate_video(p_prompt => ''),
  'error: GENERATE_VIDEO requires prompt',
  'empty prompt short-circuits to an error result');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'error: GENERATE_VIDEO requires sdcpp_api_base config',
  'no sdcpp_api_base configured -> error result (no graph built)');

-- configure a base, then the same call builds the polling graph.
INSERT INTO ow.config(agent_id, key, value, secret)
VALUES (1, 'sdcpp_api_base', to_jsonb('http://sdcpp.test'::text), false)
ON CONFLICT (agent_id, key) DO UPDATE SET value = EXCLUDED.value;

SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'df\.http', 'built graph contains a df.http submit node');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  '/sdcpp/v1/vid_gen', 'built graph targets the vid_gen endpoint');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'df\.loop', 'built graph polls the job in a df.loop');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'df\.sleep\(3\)', 'built graph sleeps 3s between polls (poll_interval baked)');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'df\.break', 'built graph breaks the poll loop on a terminal job');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  '_sdcpp_finalize_video', 'built graph finalizes via _sdcpp_finalize_video');
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'CZ1', 'built graph bakes the latest user chat_id (fixture CZ1) as a literal');
-- the prompt makes it into the request body node as a quoted literal.
SELECT matches(ow_tools._tool_generate_video(p_prompt => 'a cat walking'),
  'a cat walking', 'built graph bakes the prompt into the request body');

SELECT * FROM finish();
ROLLBACK;
