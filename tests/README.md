# pgTAP permission-matrix tests

`tests/pgtap/` is a [pgTAP](https://pgtap.org) suite that pins down the entire
**RBAC + Row-Level-Security permission matrix** enforced by
`docker-entrypoint-initdb.d/40-attobot-rbac.sql` and
`docker-entrypoint-initdb.d/41-dashboard-role.sql`.

It asserts, for every `(role, table, action)` cell:

- the **GRANT shape** (`has_table_privilege` / `has_sequence_privilege` /
  `has_schema_privilege`), and
- the **RLS behaviour** (which rows a role can see / whether an INSERT/UPDATE/
  DELETE is allowed), using the `pgtap_test.visible_count` / `pgtap_test.can`
  helpers in `00_setup.sql`.

The six roles under test: `attobot_anonymous`, `attobot_authenticated`,
`attobot_agent_primary`, `attobot_agent_subconscious`, `attobot_service`,
`attobot_dashboard`.

## Run

```bash
docker compose run --rm pgtap
```

This builds a throwaway image (Postgres 18 + `pg_durable` + pgTAP + `pg_prove`),
bootstraps a fresh cluster with the project schema, creates the dashboard role
exactly as the `agent-init` job does, loads baseline fixtures, and runs the
suite. It never touches the live `harness` database. Exit status is non-zero if
any assertion fails; add `--build` to rebuild after editing the SQL.

## Files

| File | Contents |
|---|---|
| `00_setup.sql` | `CREATE EXTENSION pgtap`; disables the message triggers that fire `df.start`; `pgtap_test.visible_count` / `pgtap_test.can` helpers |
| `00_fixtures.sql` | baseline model / agents / config / messages / memory / users |
| `10_roles_meta.sql` | role existence, LOGIN/BYPASSRLS flags, memberships, schema/sequence grants |
| `20_agents_models.sql` | PUBLIC read; service-only writes |
| `30_messages.sql` | users SELECT chat-wide (no writes); agents own-agent SELECT/INSERT/UPDATE; service ALL; dashboard read-all |
| `40_memory.sql` | `memory` + `memory_sources`: primary own-agent; subconscious all agents; service ALL |
| `50_config.sql` | users non-secret own; agents own incl. secrets; service non-secret only via `config_public`; dashboard read-all |
| `80_users.sql` | users own-row; primary SELECT all + INSERT/UPDATE; subconscious SELECT all; service ALL; dashboard read-all |

## Access-matrix notes (suite ↔ docs in sync)

The suite asserts exactly what the database enforces, and that matches the
access matrix in `docs/ARCHITECTURE.md` and `docs/abac-rls-security-design.md` §7.
A few cells are non-obvious least-privilege decisions worth calling out:

| # | Table | Cell | Behaviour |
|---|---|---|---|
| 1 | `messages` | anonymous/authenticated | **SELECT only** — the configured chat is one agent = one chat, so a user reads all of it; the agent role appends/edits on their behalf. Users never write. |
| 2 | `config` | service | **non-secret only**, via the `attobot.config_public` view — `service` is the subconscious's LLM-SQL tool scope and has **no** grant on the base `config` table, so secret rows (`api_key`, `telegram_token`) are unreachable even though `service` is `BYPASSRLS`. |

`attobot_dashboard` is `BYPASSRLS` with `SELECT`/`EXECUTE` only; it reads secret
`config` rows but the dashboard API redacts them server-side.
