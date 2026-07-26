# Configuration

This project is configured through `.env`. Start by copying the checked-in
template:

```bash
cp .example.env .env
docker compose up -d
```

The first `docker compose up` run starts the database and runs the one-shot
`agent-init` seed job. That job loads `agents.sql` and `dashboard-role.sql`,
creates the default `primary` and `sidecar` agents, and stores the chosen
settings in `ow.config`.

If you change environment values later, rerun the seed job so the stored config
matches the file:

```bash
docker compose run --rm agent-init
```

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `OPENWORLD_POSTGRES_PASSWORD` | Password for the local Postgres container. | `postgres` |
| `OPENWORLD_API_KEY` | Required LLM key for agent turns. | empty |
| `OPENWORLD_EXA_API_KEY` | Optional key for the `SEARCH` tool. | empty |
| `OPENWORLD_MODEL` | Shared model name seeded into `ow.models`. | `Gemma4-26B-A4B` |
| `OPENWORLD_API_BASE` | API base for the shared model. | `http://localhost:11434/v1` |
| `OPENWORLD_TEMPERATURE` | Shared model temperature. | `1.0` |
| `OPENWORLD_REASONING_EFFORT` | Reasoning effort passed to the model. | `medium` |
| `OPENWORLD_CONTEXT_TOKENS` | Context window size for the shared model. | `131072` |
| `OPENWORLD_MULTIMODAL_SUPPORT` | Whether the shared model supports multimodal input. | `true` |
| `OPENWORLD_TELEGRAM_TOKEN` | Telegram bot token for the primary inbox loop. | empty |
| `OPENWORLD_TELEGRAM_CHAT_ID` | Telegram chat id accepted by the inbox loop. | empty |
| `OPENWORLD_TELEGRAM_THREAD_ID` | Optional Telegram forum topic id. | empty |
| `OPENWORLD_TELEGRAM_API_BASE` | Telegram API base URL. | `https://api.telegram.org` |
| `OPENWORLD_TELEGRAM_POLL_TIMEOUT` | Telegram polling timeout in seconds. | `60` |
| `OPENWORLD_DASHBOARD_PASSWORD` | Password for the `ow_dashboard` DB role. | `dashboard` |
| `OPENWORLD_DASHBOARD_TOKEN` | Optional bearer token required by the dashboard API. | empty |

## Model Setup

`agent-init` seeds the shared model before creating the default agents. Override
the model settings in `.env` if you want a different provider, base URL, or
context window.

To create a new agent manually, configure a model first and then insert the
agent with its model id:

```bash
docker compose exec harness psql -U postgres -d postgres
```

```sql
WITH model AS (
  SELECT ow.upsert_model(
    p_model => 'Gemma4-26B-A4B',
    p_api_base => 'http://localhost:11434/v1',
    p_temperature => 1.0,
    p_reasoning_effort => 'medium',
    p_context_tokens => 131072,
    p_multimodal_support => true
  ) AS id
)
SELECT ow.upsert_agent(
  p_slug => 'primary',
  p_soul => $$
You are a persistent agent running inside PostgreSQL.
Be direct. Use tools when you need to act on stored state.
Reply directly when no tool action is needed.
$$,
  p_api_key => 'sk-...',
  p_model_id => (SELECT id FROM model)
);
```

To update only a secret after the row exists:

```sql
SELECT ow.set_config('primary', 'api_key', to_jsonb('sk-...'::text));
```

## Telegram

Set `OPENWORLD_TELEGRAM_TOKEN` and `OPENWORLD_TELEGRAM_CHAT_ID` before first boot to
enable the primary agent's inbox loop.

For a forum topic, also set `OPENWORLD_TELEGRAM_THREAD_ID`.
If you change any Telegram values after startup, rerun `docker compose run --rm
agent-init` so the stored config is refreshed and the inbox loop is created if
needed.

To update stored Telegram settings directly, call `ow.configure_telegram`
from `psql`:

```sql
SELECT ow.configure_telegram(
  p_agent_slug => 'primary',
  p_token => '123:abc',
  p_chat_id => '-1001234567',
  p_thread_id => NULL
);
```

The inbox loop polls Telegram through `pg_durable` and appends accepted
messages as `[telegram <update_id>] ...` user messages.

Outbound delivery is trigger-driven: any `assistant` or `system` row inserted
into `ow.messages` with `channel = 'telegram'` and a non-empty payload
starts a one-shot durable send workflow for that message.

## Dashboard

The dashboard uses the `ow_dashboard` DB role. Set
`OPENWORLD_DASHBOARD_PASSWORD` if you want a non-default password, and set
`OPENWORLD_DASHBOARD_TOKEN` to require `Authorization: Bearer <token>` on API
requests.

## SSH Host Registration

`ssh.hosts` is registered by `harness/agents.sql`, which the `agent-init`
service runs against the harness database as the `postgres` superuser on every
`docker compose up`. Set the host and user in the environment; the rest are
optional:

| Env var | Required | Default | Meaning |
| --- | --- | --- | --- |
| `OPENWORLD_SSH_HOST` | yes | — | remote host (IP or DNS name) |
| `OPENWORLD_SSH_USER` | yes | — | remote SSH user |
| `OPENWORLD_SSH_PORT` | no | `22` | remote port |
| `OPENWORLD_SSH_HOST_NAME` | no | `default` | logical name passed as the `BASH` tool's `host` arg |
| `OPENWORLD_SSH_HOST_KEY_FINGERPRINT` | no | unset | lowercase hex SHA-256 of the server host key; omit to skip host-key verification and pin it later by updating the row |

On first registration `agents.sql` mints an ed25519 keypair in-process via
pg_ssh's `ssh.keygen()`, inserts the private key straight into `ssh.hosts`, and
returns the matching public key to the `agent-init` logs:

```text
 host_name |                       public_key
-----------+-----------------------------------------------------------
 default   | ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... ow-default
```

Append that public key to the remote `~/.ssh/authorized_keys`. The private key
lives only in `ssh.hosts` and is never written to disk. Registration is
idempotent, so later runs are no-ops and the key is not rotated.

Recover the public key at any time as a superuser:

```sh
docker compose exec harness psql -tAc \
  "SELECT public_key FROM ssh.hosts WHERE host_name='default';"
```

Leave `OPENWORLD_SSH_HOST` and `OPENWORLD_SSH_USER` unset to skip registration
entirely.

## Operational Notes

To interact with the agent directly, open `psql` and insert a user message into
`ow.messages`:

```bash
docker compose exec harness psql -U postgres -d postgres
```

```sql
INSERT INTO ow.messages(agent_id, role, content)
VALUES (ow.agent_id('primary'), 'user', 'Introduce yourself');
```

The reply lands back in `ow.messages`. Turn progress is visible in
`df.instances`.

To start a cron-driven loop for the sidecar agent:

```sql
SELECT ow.ensure_agent_cron_loop(
  p_agent_slug => 'sidecar',
  p_name => 'heartbeat',
  p_cron => '*/5 * * * *',
  p_message => 'tick'
);
```
