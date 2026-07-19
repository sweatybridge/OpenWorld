SELECT attobot.upsert_model(
  p_model => COALESCE(NULLIF(:'model', ''), 'deepseek-v4-pro'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'https://api.deepseek.com/v1'),
  p_temperature => COALESCE(NULLIF(:'temperature', ''), '1.0')::numeric,
  p_reasoning_effort => COALESCE(NULLIF(:'reasoning_effort', ''), 'medium'),
  p_context_tokens => COALESCE(NULLIF(:'context_tokens', ''), '1000000')::integer,
  p_multimodal_support => COALESCE(NULLIF(:'multimodal_support', ''), 'false')::boolean
) AS model_id
\gset

SELECT attobot.upsert_agent(
  p_slug => 'primary',
  p_soul => $primary_soul$
You are the primary attobot agent.

You run inside PostgreSQL. Your durable state is in the attobot schema:
messages and blobs.
You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Direct assistant replies with no tool calls are delivered to
the operator automatically. Keep durable notes in database tables or blobs.
Use SEARCH for web discovery and WEBFETCH to read public HTTP(S) pages. Use
WRITE_BLOB for large or binary content, with an explicit encoding such as UTF8,
base64, or hex. The ffmpeg schema (pg_ffmpeg) exposes media functions you can
call via SQL — e.g. ffmpeg.thumbnail, ffmpeg.transcode, ffmpeg.waveform,
ffmpeg.generate_gif — which return image/audio/video bytes. Use SEND_ATTACHMENT
to send media as a Telegram attachment: pass the raw content with an encoding
(base64, hex, escape, or a text encoding). Its kind is auto-detected from the
mime_type or filename (falling back to ffmpeg.media_info), so images are sent as
photos, audio as audio, and video as video; anything else is sent as a document.

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

SELECT attobot.upsert_agent(
  p_slug => 'subconscious',
  p_soul => $subconscious_soul$
You are the subconscious attobot agent.

You run inside PostgreSQL beside the other agents. Your job is to review their
durable streams for repeated mistakes, drift, missing lessons, or loops, and to
keep their memory accurate. You do not talk to the operator directly.

Use SQL to inspect any agent's state in attobot.messages
and related tables. When a lesson is worth recording or a stored memory is wrong,
correct it in attobot.memory for the relevant agent: INSERT a new memory row, or
UPDATE an existing one. Keep entries concise and accurate. If there is nothing
actionable, stay idle.

Only modify attobot.memory — never overwrite an agent's messages or other state.
$subconscious_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

-- Per-agent Exa API key for the SEARCH tool, shared by both agents (one Exa
-- account). Stored as a secret in each agent's config so either agent's SEARCH
-- graph builder can read its own key under RLS.
SELECT attobot.set_config(slug, 'exa_api_key', to_jsonb(NULLIF(:'exa_api_key', '')), true)
FROM (VALUES ('primary'), ('subconscious')) AS t(slug)
WHERE NULLIF(:'exa_api_key', '') IS NOT NULL;

SELECT attobot.ensure_agent_cron_loop(
  p_agent_slug => 'subconscious',
  p_name => 'primary-review',
  p_cron => '*/30 * * * *',
  p_message => 'review agent streams for actionable memory corrections'
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

ALTER ROLE attobot_dashboard PASSWORD :'dashboard_db_password';

-- SSH host registration for the BASH tool. Mint an ed25519 keypair in-process
-- with ssh.keygen() (no ssh-keygen binary, no temp files; the private key goes
-- straight from keygen into ssh.hosts and never touches disk) and register the
-- host. Idempotent: ON CONFLICT DO UPDATE means re-runs are no-ops and the key
-- is never rotated. Skipped entirely when ATTOBOT_SSH_HOST/ATTOBOT_SSH_USER are
-- unset. The public key is RETURNING on every run and written to disk so it can
-- be volume mounted into the sshd container's ~/.ssh/authorized_keys
\t on
\pset format unaligned
\o ~/.ssh/id_ed25519.pub

INSERT INTO ssh.hosts (host_name, host, port, username, private_key, public_key, host_key_fingerprint)
SELECT :'ssh_host_name', :'ssh_host', :'ssh_port'::integer, :'ssh_user',
       private_key, public_key, NULLIF(:'ssh_fp', '')
  FROM ssh.keygen('ed25519', 'attobot-' || :'ssh_host_name')
 WHERE NULLIF(:'ssh_host', '') IS NOT NULL
   AND NULLIF(:'ssh_user', '') IS NOT NULL
 ON CONFLICT (host_name) DO UPDATE SET host_name = EXCLUDED.host_name
 RETURNING public_key;
