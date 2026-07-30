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
-- plan(22) up front: this file uses throws_ok, whose result path does not trip
-- no_plan()'s deferred end-of-transaction plan emission, so an explicit plan
-- keeps the TAP output well-formed for pg_prove.
SELECT plan(22);

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

-- _telegram_is_parse_error gates the send graph's plain-text retry. The exact
-- shape Telegram returned for instance 3a8e027a (LLM wrote **bold** + '*'
-- bullets, legacy Markdown could not balance the markers): only this error
-- may trigger the retry; every other failure must still raise on the first
-- response so it is neither retried nor masked.
SELECT is(
  ow._telegram_is_parse_error('{"status":400,"body":"{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: can''t parse entities: Can''t find end of the entity starting at byte offset 412\"}"}'::jsonb),
  true,
  'markdown parse error 400 is detected (plain-text retry fires)'
);
SELECT is(
  ow._telegram_is_parse_error('{"status":400,"body":"{\"ok\":false,\"error_code\":400,\"description\":\"Bad Request: chat not found\"}"}'::jsonb),
  false,
  'non-parse 400 (chat not found) is not retried'
);
SELECT is(
  ow._telegram_is_parse_error('{"status":200,"body":"{\"ok\":true,\"result\":{\"message_id\":42}}"}'::jsonb),
  false,
  'successful send is not retried'
);

-- ow.telegramify: CommonMark → MarkdownV2 conversion, modeled on
-- telegramify-markdown (the send graph posts its output with
-- parse_mode=MarkdownV2). Pure function, exercised directly. Expected values
-- below are written char-for-char ('' literals, so backslashes are literal).
SELECT is(
  ow.telegramify('# Hello World'),
  '*Hello World*',
  'heading → bold'
);
SELECT is(
  ow.telegramify('This is **bold** and __strong__ text'),
  'This is *bold* and *strong* text',
  'strong ** and __ → *…*'
);
SELECT is(
  ow.telegramify('an *italic* and _em_ word'),
  'an _italic_ and _em_ word',
  'emphasis * and _ → _…_'
);
SELECT is(
  ow.telegramify('use snake_case_names here'),
  'use snake\_case\_names here',
  'intraword underscores stay escaped (no false emphasis)'
);
SELECT is(
  ow.telegramify('~~gone~~'),
  '~gone~',
  'strikethrough ~~ → ~…~'
);
SELECT is(
  ow.telegramify('run `rm -rf /tmp` now'),
  'run `rm -rf /tmp` now',
  'inline code span kept verbatim'
);
SELECT is(
  ow.telegramify('a `a_b*c.d` span'),
  'a `a_b*c.d` span',
  'specials inside a code span are not escaped'
);
SELECT is(
  ow.telegramify('```js
const a_b = 1;
```'),
  '```js
const a_b = 1;
```',
  'fenced block kept, content verbatim'
);
SELECT is(
  ow.telegramify('see [docs](https://ex.com/a_(b))'),
  'see [docs](https://ex.com/a_\(b\))',
  'link: text kept, url escapes only ( )'
);
SELECT is(
  ow.telegramify('[click **here**](https://x.com)'),
  '[click *here*](https://x.com)',
  'formatting inside link text; url dots not escaped'
);
SELECT is(
  ow.telegramify('1.0.0 + x - y = z!'),
  '1\.0\.0 \+ x \- y \= z\!',
  'plain-text specials backslash-escaped'
);
SELECT is(
  ow.telegramify('- one
- two'),
  '• one
• two',
  'dash bullets → •'
);
SELECT is(
  ow.telegramify('1. one
2. two'),
  '1\. one
2\. two',
  'ordered list markers escaped'
);
SELECT is(
  ow.telegramify('path D:\work\attobot end'),
  'path D:\\work\\attobot end',
  'backslashes doubled'
);
SELECT is(
  ow.telegramify('> quoted **text**'),
  '> quoted *text*',
  'blockquote kept, content converted'
);
SELECT is(
  ow.telegramify('```
code `x`'),
  '```
code \`x\`
```',
  'unterminated fence closed; backticks escaped inside'
);
SELECT is(
  ow.telegramify('_a_ and _b_'),
  '_a_ and _b_',
  'multiple emphasis spans in one line'
);

ROLLBACK;
