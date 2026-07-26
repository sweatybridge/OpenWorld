-- send_message: a Telegram API error must fail the send instance.
--
-- pg_durable has no df.fail; an unhandled RAISE in a node is what marks a
-- workflow failed (RAISE EXCEPTION surfaces as SQLSTATE P0001, raise_exception).
-- send_message is the final node of the send graph built by send_message_future
-- (df.start-ed as ow:send:<msg_id>), so when Telegram rejects the send it
-- must RAISE instead of returning sent:false (which left the instance silently
-- completed).
--
-- Only the response-parse is exercised here: it is pure (the df.http /
-- df.http_multipart response is passed in as p_http_response, so no network).
-- The attachment *upload* (df.http_multipart) needs a live Telegram endpoint,
-- which the harness cannot reach (the message triggers are disabled in
-- 00_setup.sql and the harness cannot df.start), so it is not under test — but
-- text and attachment now share this one RAISE-on-non-2xx guard in send_message,
-- so it covers both paths' failure logic.
\set ON_ERROR_STOP on
BEGIN;
-- plan(2) up front: this file uses throws_ok, whose result path does not trip
-- no_plan()'s deferred end-of-transaction plan emission, so an explicit plan
-- keeps the TAP output well-formed for pg_prove.
SELECT plan(2);

-- 4xx with ok:false (the shape Telegram returns for a rejected sendMessage,
-- e.g. an unroutable chat_id): the function raises P0001, so the send instance
-- fails instead of completing silently. throws_ok's 4-arg form takes errcode
-- then errmsg (NULL = don't check) then description.
SELECT throws_ok(
  $$SELECT ow.send_message('primary', 0, '{"status":400,"body":"{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: chat not found\"}"}'::jsonb)$$,
  'P0001'::char(5),
  NULL,
  'text-path 4xx ok:false raises P0001 (fails the send instance)'
);

-- 2xx with ok:true (a successful sendMessage): returns sent=true, so the
-- instance still completes. Guards against the success path being broken.
SELECT is(
  (SELECT (ow.send_message('primary', 0, '{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":42}}"}'::jsonb))->>'sent'),
  'true',
  'text-path 2xx ok:true returns sent=true (instance completes)'
);

ROLLBACK;
