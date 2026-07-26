SELECT ow.upsert_model(
  p_model => COALESCE(NULLIF(:'model', ''), 'Gemma4-26B-A4B'),
  p_api_base => COALESCE(NULLIF(:'api_base', ''), 'http://localhost:11434/v1'),
  p_temperature => COALESCE(NULLIF(:'temperature', ''), '1.0')::numeric,
  p_reasoning_effort => COALESCE(NULLIF(:'reasoning_effort', ''), 'medium'),
  p_context_tokens => COALESCE(NULLIF(:'context_tokens', ''), '131072')::integer,
  p_multimodal_support => COALESCE(NULLIF(:'multimodal_support', ''), 'true')::boolean
) AS model_id
\gset

SELECT ow.upsert_agent(
  p_slug => 'primary',
  p_soul => $primary_soul$
You are the primary OpenWorld agent.

You run inside PostgreSQL. Your durable state is in the ow schema:
messages.
You do not own a filesystem harness.

Respond to operator messages directly and use tools when you need to act on
database state. Direct assistant replies with no tool calls are delivered to
the operator automatically. Keep durable notes in database tables.
Use SEARCH for web discovery and WEBFETCH to read public HTTP(S) pages.

To send media (photo/video/audio) as a Telegram attachment, first ingest the
source with the SQL tool: `SELECT ffmpeg.hls(url, segment_duration)` fetches a
remote video and stores its HLS segments, returning a `playlist_id` (a bigint).
Then call SEND_PHOTO, SEND_VIDEO, or SEND_AUDIO with that `playlist_id` and a
`transform` (an ffmpeg op) plus an `options` object. The tool rebuilds the
media from the playlist, applies the transform server-side, and queues it for
delivery — so the media bytes never pass through your arguments or results;
you only ever handle the small playlist_id. SEND_PHOTO transforms: thumbnail
(grab a frame; options seconds, format), waveform (audio waveform image).
SEND_VIDEO transforms: raw (send as-is), transcode, trim. SEND_AUDIO
transforms: extract_audio (optionally start_time/end_time to trim). Each tool
forces its kind — SEND_PHOTO always sends a photo, etc. SEND_ATTACHMENT still
exists for sending inline bytes you already hold (pass content + an encoding),
with kind auto-detected.

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

SELECT ow.upsert_agent(
  p_slug => 'sidecar',
  p_soul => $sidecar_soul$
You are the sidecar OpenWorld agent.

You run inside PostgreSQL beside the other agents. Your job is to review their
durable streams for repeated mistakes, drift, missing lessons, or loops, and to
keep their memory accurate. You do not talk to the operator directly.

Use SQL to inspect any agent's state in ow.messages
and related tables. When a lesson is worth recording or a stored memory is wrong,
correct it in ow.memory for the relevant agent: INSERT a new memory row, or
UPDATE an existing one. Keep entries concise and accurate. If there is nothing
actionable, stay idle.

Only modify ow.memory — never overwrite an agent's messages or other state.
$sidecar_soul$,
  p_api_key => NULLIF(:'api_key', ''),
  p_model_id => :model_id
);

-- Per-agent Exa API key for the SEARCH tool, shared by both agents (one Exa
-- account). Stored as a secret in each agent's config so either agent's SEARCH
-- graph builder can read its own key under RLS.
SELECT ow.set_config(slug, 'exa_api_key', to_jsonb(NULLIF(:'exa_api_key', '')), true)
FROM (VALUES ('primary'), ('sidecar')) AS t(slug)
WHERE NULLIF(:'exa_api_key', '') IS NOT NULL;

SELECT ow.ensure_agent_cron_loop(
  p_agent_slug => 'sidecar',
  p_name => 'primary-review',
  p_cron => '*/30 * * * *',
  p_message => 'review agent streams for actionable memory corrections'
);

SELECT ow.configure_telegram(
  p_agent_slug => 'primary',
  p_token => :'telegram_token',
  p_chat_id => :'telegram_chat_id',
  p_thread_id => NULLIF(:'telegram_thread_id', ''),
  p_api_base => COALESCE(NULLIF(:'telegram_api_base', ''), 'https://api.telegram.org')
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;

SELECT ow.ensure_telegram_inbox_loop(
  p_agent_slug => 'primary',
  p_timeout => COALESCE(NULLIF(:'telegram_poll_timeout', ''), '60')::integer
)
WHERE NULLIF(:'telegram_token', '') IS NOT NULL
  AND NULLIF(:'telegram_chat_id', '') IS NOT NULL;

ALTER ROLE ow_dashboard PASSWORD :'dashboard_db_password';

-- SSH host registration for the BASH tool. Mint an ed25519 keypair in-process
-- with ssh.keygen() (no ssh-keygen binary, no temp files; the private key goes
-- straight from keygen into ssh.hosts and never touches disk) and register the
-- host. Idempotent: ON CONFLICT DO UPDATE means re-runs are no-ops and the key
-- is never rotated. Skipped entirely when OPENWORLD_SSH_HOST/OPENWORLD_SSH_USER are
-- unset. The public key is RETURNING on every run and written to disk so it can
-- be volume mounted into the sshd container's ~/.ssh/authorized_keys
\t on
\pset format unaligned
\o ~/.ssh/id_ed25519.pub

INSERT INTO ssh.hosts (host_name, host, port, username, private_key, public_key, host_key_fingerprint)
SELECT :'ssh_host_name', :'ssh_host', :'ssh_port'::integer, :'ssh_user',
       private_key, public_key, NULLIF(:'ssh_fp', '')
  FROM ssh.keygen('ed25519', 'ow-' || :'ssh_host_name')
 WHERE NULLIF(:'ssh_host', '') IS NOT NULL
   AND NULLIF(:'ssh_user', '') IS NOT NULL
 ON CONFLICT (host_name) DO UPDATE SET host_name = EXCLUDED.host_name
 RETURNING public_key;
