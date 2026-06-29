# attobot

attobot is a Postgres-resident agent harness built for shared, stateful
conversations. It is designed for multiplayer agents that join group chats and
respond safely to unknown numbers by keeping the conversation stream, user
identity ledger, and access boundaries inside PostgreSQL.

All agent loops run as `pg_durable` workflows, so a turn can survive database
restarts and resume from its last checkpoint. The full lifecycle is captured as
events in the database, so every turn, tool call, inbox update, and operational
change is available for auditing, replay, and debugging.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details on the design
philosophy, execution model, and access permission matrix.

## Getting started

Copy the example environment file, adjust any values you need, and start the
stack:

```bash
cp .example.env .env
docker compose up -d
```

Detailed configuration, seeding, Telegram, and dashboard setup lives in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Tables

- `attobot.agents`: one row per agent.
- `attobot.models`: reusable model, endpoint, temperature, reasoning, context, and modality configuration.
- `attobot.config`: per-agent configuration and secrets.
- `attobot.messages`: canonical conversation stream — user, assistant, system,
  and tool rows. Outbound delivery is trigger-driven off this table, so there is
  no separate outbox.
- `attobot.memory`: agent-scoped durable memories forwarded to the LLM. Each row
  links to the messages it was constructed from via `attobot.memory_sources`.
- `attobot.memory_sources`: junction table backing memory's source messages;
  composite foreign keys force same-agent integrity and cascade on delete.
- `attobot.lifecycle`: append-only audit log of operational events (agent
  ensure, message appends, telegram poll/send outcomes, security markers).
- `attobot.users`: channel-agnostic identity ledger. One row per
  `(channel, external_id)`; telegram intake (`poll_messages` → `upsert_user`)
  upserts senders, and `tier` maps a user to an RLS role suffix
  (`anonymous` / `authenticated`).
- `attotools.blobs`: content-addressed large content storage as external `bytea`.

## Roles

The permission model is split into a few small roles rather than one broad
application role:

- `attobot_agent_primary` runs the primary loop and handles user-facing turns.
- `attobot_agent_subconscious` runs review and background loops.
- `attobot_anonymous` and `attobot_authenticated` are user-scoped SQL tiers for
  the primary agent's tool calls.
- `attobot_service` is the subconscious agent's broader tool-call scope.
- `attobot_dashboard` is read-only for the admin dashboard.

`pg_durable` executes the loop as the agent role, then drops into a narrower
role when the SQL tool runs. The dashboard connects with a separate read-only
principal. Full policy details live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```mermaid
graph TD
  db["attobot / attotools tables"]
  orchestrator["postgres / pg_durable worker"]
  primary["attobot_agent_primary"]
  subconscious["attobot_agent_subconscious"]
  anon["attobot_anonymous"]
  auth["attobot_authenticated"]
  service["attobot_service"]
  dashboard["attobot_dashboard"]

  orchestrator --> primary
  orchestrator --> subconscious
  primary --> db
  subconscious --> db
  anon --> db
  auth --> db
  service --> db
  dashboard --> db
  primary --> anon
  primary --> auth
  subconscious --> service
  dashboard -. "SELECT / EXECUTE only" .-> db
```

## Built-In Tools

The LLM sees these database-native tools (schemas are introsducted from the
`attotools._tool_*` functions):

- `SEARCH`: search the public web and return result titles, URLs, and snippets.
- `WEBFETCH`: fetch a public HTTP(S) URL and return status, content type, effective URL, and a truncated text body.
- `BASH`: run a shell command on a remote host over SSH and return `stdout`, `stderr`, and `exit_code` (host must be registered in `ssh.hosts`).
- `SEND_ATTACHMENT`: send a stored blob as a Telegram document attachment.
- `WRITE_BLOB`: write large or binary content into `attotools.blobs` using an explicit encoding.
- `READ_BLOB`: read blob content by hash as `UTF8` text, `base64`, `hex`, `escape`, or another PostgreSQL text encoding.
- `SQL`: run a single SQL query that returns rows; intentionally accepts only one semicolon-free query and wraps it as a subquery. For writes, use a data-modifying CTE with `RETURNING`, for example:

```sql
WITH ins AS (
  INSERT INTO some_table(value) VALUES ('x')
  RETURNING *
)
SELECT * FROM ins
```

`BASH` runs a shell command on a remote host over SSH via the `pg_ssh`
extension's `ssh.ssh_exec(host_name, command)`. Hosts are pre-registered by a
superuser in `ssh.hosts`, which keeps PEM private keys in memory only and is
locked to its owner. `ssh_exec` is `SECURITY DEFINER`, owned by `postgres`, with
`EXECUTE` granted to `PUBLIC` by default, so the acting role can call it without
extra grants and never sees the keys; run `REVOKE EXECUTE ON FUNCTION
ssh.ssh_exec(text,text) FROM PUBLIC;` then `GRANT` it to specific roles to
restrict who can run remote commands. Like the other synchronous tools it runs
through `run_tool_call_as_role`, but its result comes from the
`SECURITY DEFINER` function rather than RLS-bound data access; connection/auth
failures surface as the tool result instead of aborting the turn.

## Admin Dashboard

![Screenshot](https://github.com/user-attachments/assets/410f4f8d-d903-42dd-99d6-aaf170a90868)

## Docker Image

The image uses `postgres:18-trixie` as its base and installs
`pg-durable-postgresql-18_0.2.3-1_amd64.deb` from the
`sweatybridge/pg_durable` `v0.2.3` GitHub release. The Dockerfile verifies the
published SHA256 digest before installing the package.

`shared_preload_libraries = 'pg_durable'` (plus `pg_durable.database` and
`pg_durable.worker_role`) is written into the base sample config so new clusters
load the background worker before init SQL runs.

The image also installs `pg-ssh-pg18_0.1.0-1_trixie_<arch>.deb` from the
`sweatybridge/pg_ssh` `v0.1.0` GitHub release (SHA256-verified per arch).
`pg_ssh` needs no `shared_preload_libraries` — it is a function extension with no
background worker — so it is enabled with `CREATE EXTENSION pg_ssh` in
`docker-entrypoint-initdb.d/01-pg-ssh.sql`. (libssh2 is statically linked into
`pg_ssh.so`, so the base image's libssl/libcrypto are the only runtime deps.)

The `harness` service uses this image. The `agent-init` service uses the stock
Postgres client image, mounts `agents.sql` read-only, waits for `harness` to be
healthy, and runs `psql --no-psqlrc --single-transaction --set=ON_ERROR_STOP=1 --set=... --file=/attobot/agents.sql`.
