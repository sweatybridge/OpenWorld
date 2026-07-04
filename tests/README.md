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
| `00_fixtures.sql` | baseline model / agents / config / messages / memory / blobs / users |
| `10_roles_meta.sql` | role existence, LOGIN/BYPASSRLS flags, memberships, schema/sequence grants |
| `20_agents_models.sql` | PUBLIC read; service-only writes |
| `30_messages.sql` | users SELECT chat-wide (no writes); agents own-agent SELECT/INSERT/UPDATE; service ALL; dashboard read-all |
| `40_memory.sql` | `memory` + `memory_sources`: primary own-agent; subconscious all agents; service ALL |
| `50_config.sql` | users non-secret own; agents own incl. secrets; service reads **all** secrets; dashboard read-all |
| `60_lifecycle.sql` | users own SELECT; primary own SELECT+INSERT; subconscious INSERT-only; service SELECT-only; dashboard read-all |
| `70_blobs.sql` | users full CRUD own; primary same via membership; subconscious denied; service ALL; dashboard read-all |
| `80_users.sql` | users own-row; primary SELECT all + INSERT/UPDATE; subconscious SELECT all; service ALL; dashboard read-all |

## Documented drift between the code and the docs

The suite asserts what the database **actually enforces**. Several cells differ
from `docs/abac-rls-security-design.md` §7 and the README "Least-privilege
access matrix"; those tests are tagged `[DRIFT]`. Summary:

| # | Table | Cell | README/design says | Code enforces |
|---|---|---|---|---|
| 1 | `messages` | anonymous/authenticated | SELECT + INSERT/UPDATE own, no DELETE | **SELECT only** (no INSERT/UPDATE grant or policy) |
| 2 | `attotools.blobs` | anonymous/authenticated | — (no access) | **full CRUD** on own agent (needed by WRITE_BLOB/READ_BLOB) |
| 3 | `config` | service | non-secret only | **reads all secrets** (BYPASSRLS + full GRANT) |
| 4 | `lifecycle` | service | SELECT/INSERT/UPDATE | **SELECT only** (GRANT is SELECT-only) |
| 5 | `lifecycle` | agent_subconscious | SELECT; INSERT | **INSERT only** (not a member of anonymous/authenticated, so no SELECT policy applies) |
| 6 | `attotools.blobs` | agent_subconscious | SELECT/INSERT/UPDATE own | **denied** (policy is `TO anonymous, authenticated`; subconscious is only a member of service) |

⚠️ **#3 is security-relevant.** The subconscious agent's tool scope is
`attobot_service`, which is `BYPASSRLS` with full `SELECT` on `attobot.config`,
so LLM-authored SQL running as `attobot_service` can read `api_key` /
`telegram_token`. That contradicts the "secret-free tool scope" guarantee. If
that is unintended, the fix is in `40-attobot-rbac.sql` (drop `service`'s config
access or make it non-`BYPASSRLS` with a non-secret policy); the test in
`50_config.sql` should then be flipped to assert the locked-down behaviour.
