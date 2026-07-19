# attobot

attobot is a Postgres-resident agent harness built for shared, stateful
conversations. It is designed for multiplayer agents that join group chats and
respond safely to unknown numbers by keeping the conversation stream, user
identity ledger, and access boundaries inside PostgreSQL.

All agent loops run as `pg_durable` workflows, so a turn can survive database
restarts and resume from its last checkpoint. Every turn, tool call, and inbox
update is recorded as a workflow instance and message rows, available for replay
and debugging.

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
- `attobot.users`: channel-agnostic identity ledger. One row per
  `(channel, external_id)`; telegram intake (`poll_messages` → `upsert_user`)
  upserts senders, and `tier` maps a user to an RLS role suffix
  (`anonymous` / `authenticated`).

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

- `SEARCH`: search the public web and return titles, URLs, and snippets.
- `WEBFETCH`: fetch a public HTTP(S) URL and return status, content type, and a truncated text body.
- `BASH`: run a shell command on a registered remote host over SSH. `host` is optional and defaults to the first registered host when omitted.
- `SEND_ATTACHMENT`: send media (image/audio/video) as a Telegram attachment.
- `SQL`: run a single SQL query that returns rows.

`BASH` uses the `pg_ssh` extension's `ssh.exec(host_name, command)` function.
That function returns `stdout` and `stderr` as `bytea` and is defined as
`SECURITY DEFINER`, owned by `postgres`. By default `EXECUTE` is granted to
`PUBLIC`, so the acting role can call it without extra grants and never sees
the SSH keys. To restrict remote command execution, revoke `EXECUTE` from
`PUBLIC` and grant it only to the roles you want to allow.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for SSH host registration.

## Admin Dashboard

![Screenshot](https://github.com/user-attachments/assets/410f4f8d-d903-42dd-99d6-aaf170a90868)
