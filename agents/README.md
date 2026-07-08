# agents/

Declarative agent seed SQL, loaded once by the `agent-init` service on every
`docker compose up` (and re-runnable via `docker compose run --rm agent-init`).
This replaced the old monolithic `harness/agents.sql`.

## How it loads

`docker-compose.yml` mounts this directory read-only at `/attobot/agents` and
passes every file below to a single `psql` invocation as ordered `--file` args,
wrapped in `--single-transaction`:

```
psql --single-transaction --file=.../00-model.sql --file=.../10-primary.sql ...
```

Everything runs in **one psql session**, so psql variables and meta-commands
carry across files:

- `00-model.sql` publishes `:model_id` via `\gset`; the agent files consume it.
- `90-ssh-host.sql` uses `\o` to redirect output to `~/.ssh/id_ed25519.pub`.

## Files (load order matters)

| File | Purpose | Depends on |
| --- | --- | --- |
| `00-model.sql` | Shared LLM model; `\gset` → `:model_id` | — |
| `10-primary.sql` | `primary` agent soul + Telegram config + inbox loop | `:model_id` |
| `20-subconscious.sql` | `subconscious` agent soul + `primary-review` cron loop | `:model_id` |
| `30-search.sql` | Shared Exa API key for both agents' `SEARCH` tool | both agents exist |
| `80-dashboard.sql` | `attobot_dashboard` role password | dashboard role (initdb) |
| `90-ssh-host.sql` | `ssh.hosts` registration + `authorized_keys` output | — (must run **last**) |

The `NN-` prefixes sort into the required order. Two constraints are not just
performance — they are correctness:

1. `00-model.sql` **before** the agent files (they reference `:model_id`).
2. `90-ssh-host.sql` **last** (its `\o` would swallow any later file's output).

## Adding a file

1. Name it with a `NN-` prefix that sorts into the right place (respecting the
   two constraints above).
2. Add a matching `- --file=/attobot/agents/<file>` line to the `agent-init`
   service's `command:` in `docker-compose.yml`, in order.

There is no glob — each file is listed explicitly in `docker-compose.yml` so the
load order stays visible and unambiguous.

## Variables

All `:var` references are fed by `--set` flags on the `psql` command, sourced
from `.env` via `docker-compose.yml` (e.g. `ATTOBOT_MODEL` → `:model`). See
`docs/CONFIGURATION.md` for the full table.
