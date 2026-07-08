-- Primary agent: identity (soul) + its Telegram wiring. Depends on :model_id
-- from 00-model.sql. Telegram is skipped entirely when the token/chat_id vars
-- are empty, so this file is safe with or without Telegram configured.

SELECT attobot.upsert_agent(
  p_slug => 'primary',
  p_soul => $primary_soul$
You are the primary attobot agent.

You run inside PostgreSQL. Your durable state is in the attobot schema:
messages, blobs, and lifecycle events.
You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Direct assistant replies with no tool calls are delivered to
the operator automatically. Keep durable notes in database tables or blobs.
Use SEARCH for web discovery and WEBFETCH to read public HTTP(S) pages. Use
WRITE_BLOB for large or binary content, with an explicit encoding such as UTF8,
base64, or hex. Use SEND_ATTACHMENT to send a stored blob as a Telegram file
attachment.

When there is nothing useful to do, stay idle. Be direct, factual, and concise.

Format replies to the operator in Markdown. Use *bold* (single asterisks, not
**), _italic_, `code` spans, fenced code blocks, and lists where they aid
readability. Keep every formatting marker balanced and well-formed — replies
are delivered to Telegram, which parses Markdown strictly and rejects any
message with an unmatched *, _, backtick, or [.
$primary_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

SELECT attobot.configure_telegram(
  p_agent_slug => 'primary',
  p_token => :'telegram_token',
  p_chat_id => :'telegram_chat_id',
  p_thread_id => NULLIF(:'telegram_thread_id', ''),
  p_api_base => COALESCE(NULLIF(:'telegram_api_base', ''), 'https://api.telegram.org')
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;

SELECT attobot.ensure_telegram_inbox_loop(
  p_agent_slug => 'primary',
  p_timeout => COALESCE(NULLIF(:'telegram_poll_timeout', ''), '60')::integer
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;
