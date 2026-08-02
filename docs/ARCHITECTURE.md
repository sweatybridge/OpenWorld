# Architecture

ow is a Postgres-resident agent harness. Agent state, turns, tool calls,
memory, and outbound delivery all live in PostgreSQL tables under the
`ow` schema. Agents point
at shared rows in `ow.models`, so multiple agents can reuse the same model
configuration. `pg_durable` owns the durable workflow execution, so a turn can
survive database restarts and resume from its last checkpoint.

There is no filesystem loop and no external agent process. Everything is
PL/pgSQL functions, `pg_durable` workflows, and triggers running inside
Postgres. The only other container is the one-shot `agent-init` seed job.

## Design Philosophy

- Any tools that affect external environments are subject to access control via role grants.
- Accessing any internal state requires explicit evaluation of RLS policies.
- ACID properties apply to the entire agent state. Referential integrity is maintained via foreign keys from memory to message history.
- Prefer general purpose tools that are open to extension by LLM and closed to modification.
- Backup and restore should work across windows, linux, and macOS.
- Semantic indexes can be created to support multimodal search, ie. pre-filling model context window with the right data.

## Least-Privilege Access Matrix

"own agent" for an agent role =
`agent_id = current_setting('ow.current_agent_id')::bigint`.
"own chat" for a telegram user =
`"own agent" AND chat_id = current_setting('ow.current_chat_id')`.

Each agent's **loop** (compose, model call, record, orchestrate) runs as that
agent's own role - fixed, trusted code that needs the api_key, so the agent role
reads its own config including secrets. **Tool calls** drop out of the loop role
into a narrower scope: the requesting user's tier (`anonymous`/`authenticated`)
for primary, and `ow_service` for the sidecar. The intent is that no
LLM-authored SQL runs with secret access, and that is now enforced for both tool
scopes (the user tiers and `ow_service`, the latter via the non-secret
`config_public` view). See `docs/abac-rls-security-design.md` for the full design and
`tests/pgtap/` for the enforced matrix (the executable source of truth).

Only the durable framework makes http calls. The primary agent polls telegram,
appends new messages, and calls its own model. All assistant/system messages on
`channel = 'telegram'` are forwarded to the chat; `tool` messages are not.

The primary agent role runs the loop: it reads the shared `agents`/`models`
rows, all `users` (and may create and edit users, but not delete them), its own
`messages`, `memory`, `memory_sources` (full CRUD on its own agent), its own
`config` (including secrets - needed to call the model).
It cannot delete `messages`,
`config`, or `users`, and cannot modify `agents`/`models`. Its tool calls drop
to the requesting user's tier, which cannot read secrets. A running loop may be
interrupted or cancelled.

The sidecar agent role runs its loop the same way (reading its own secrets
to call its model). As its own role it sees its own `messages`, every agent's
`memory` and `memory_sources` (full CRUD, to review and correct them), its own
`config`, and all `users` (read-only). Its tool calls drop to
`ow_service`, a broad `BYPASSRLS` scope that reads non-secret `config` only
(via the `config_public` view, so secrets stay out of the LLM SQL scope).

| Table | `anonymous` | `authenticated` | `agent_primary` | `agent_sidecar` | `service` |
|---|---|---|---|---|---|
| `agents` | SELECT | SELECT | SELECT | SELECT | SELECT; writer (I/U/D) |
| `models` | SELECT | SELECT | SELECT | SELECT | SELECT; writer (I/U/D) |
| `messages` | **SELECT own chat; no writes** | same | SELECT/INSERT/UPDATE own; no DELETE | SELECT/INSERT/UPDATE own; no DELETE | ALL |
| `memory` | - | - | ALL own agent | ALL across agents | ALL |
| `memory_sources` | - | - | ALL own agent | ALL across agents | ALL |
| `config` | SELECT non-secret own | SELECT non-secret own | SELECT own (incl. secrets); I/U own | SELECT own (incl. secrets); I/U own | non-secret only (`config_public` view) |
| `users` | SELECT own row | SELECT own row | SELECT all; INSERT/UPDATE | SELECT all (writes RLS-denied) | ALL |

The `ow_dashboard` role (the admin dashboard's DB principal) is `BYPASSRLS`
with `SELECT`/`EXECUTE` only across these tables - it sees every row but can
never write; secret values are redacted by the dashboard API, not by the
database. The matrix above is enforced and exercised end-to-end by the pgTAP
suite in `tests/pgtap/` (`docker compose run --rm pgtap`).

Two least-privilege decisions:

- **Secrets are kept out of every LLM-tool scope.** Agent roles read their own
  `secret = true` config (`api_key`, `telegram_token`) - but only from fixed loop
  code that needs the key to call the model. Neither LLM-SQL tool scope can read
  secrets: the user tier (`anonymous`/`authenticated`, primary's tool scope) has
  SELECT on non-secret own rows only, and `ow_service` (the sidecar's
  tool scope) has no grant on the base `config` table at all - it reads non-secret
  rows only through the `config_public` view, so its `BYPASSRLS` flag is irrelevant
  for secrets (no grant -> no rows). Today only the superuser and
  `ow_dashboard` see secrets directly (the dashboard API redacts them).
- **`messages` SELECT is chat-wide for users; users never write.** The whole
  conversation belongs to one configured chat = one agent, so a user sees all of
  it (including other users' messages and the agent's replies). Anonymous and
  authenticated hold `SELECT` only - they cannot `INSERT`, `UPDATE`, or
  `DELETE`; the agent role appends messages on their behalf.

## Docker Image

The image uses `pgvector/pgvector:pg18-trixie` as its base and installs
`pg-durable-postgresql-18_0.2.5-1_amd64.deb` from the
`sweatybridge/pg_durable` `v0.2.5` GitHub release. The Dockerfile verifies the
published SHA256 digest before installing the package.

The fork's package is used instead of Microsoft's own release assets on
purpose: Microsoft's debs are compiled with the `http-allow-azure-domains`
Cargo feature, which restricts `df.http()`/`df.http_multipart()` to Azure
service domains and private-IP-blocked endpoints — Telegram
(`api.telegram.org`) and the local LLM endpoint (e.g. `localhost:11434`)
would both be refused. The fork builds the same source with `http-allow-all`.
Version numbers track upstream; the fork's `v0.2.5` matches Microsoft's
`v0.2.5` feature-for-feature (including `df.http_multipart()`).

`shared_preload_libraries = 'pg_durable'` (plus `pg_durable.database` and
`pg_durable.worker_role`) is written into the base sample config so new clusters
load the background worker before init SQL runs.

The image also installs `pg-ssh-pg18_0.3.0-1_trixie_<arch>.deb` from the
`sweatybridge/pg_ssh` `v0.3.0` GitHub release. `pg_ssh` needs no
`shared_preload_libraries`; it is enabled with `CREATE EXTENSION pg_ssh` in
`docker-entrypoint-initdb.d/01-pg-ssh.sql`.

The `harness` service uses this image. The `agent-init` service uses the stock
Postgres client image, mounts `agents.sql` read-only, waits for `harness` to be
healthy, and runs `psql --no-psqlrc --single-transaction --set=ON_ERROR_STOP=1 --set=... --file=/ow/agents.sql`.
