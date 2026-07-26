# ABAC / Row-Level Security for ow

**Status:** Implemented — roles, RLS policies, the `users` ledger, and active
enforcement of user-scoped tool execution.
**Evolution since this doc was written:** each agent's loop now runs as that
agent's own role (`ow_agent_*`, `LOGIN`) rather than as `ow_service`;
`ow_service` is repurposed as the sidecar's broad tool-call scope; and
agent roles read their own secrets from fixed loop code. The **README access
matrix and the pgTAP suite in `tests/pgtap/` are the current source of truth** —
the §7 matrix and §8 worked example below have been corrected to match. The
narrative sections still predate the trigger-driven loop and are stale (notably
`start_turn`, the `outbox`, and `process_telegram_updates`).
**Secret-free tool scope:** `ow_service` (the sidecar's LLM-SQL tool
scope) has no grant on the base `config` table — it reads non-secret rows only
through the `config_public` view, so `api_key` / `telegram_token` are unreachable
even though `service` is `BYPASSRLS` (no grant → no rows). See `config` in
[§7](#7-least-privilege-access-matrix).
**Branch:** `docs/abac-rls-security` → `develop`.
**Supersedes:** the stale `feature/abac-rls-security` attempt (see [§12](#12-prior-attempt--why-this-is-different)).

---

## 1. Summary

ow is a Postgres-resident agent harness: agent state, the conversation
stream, tool calls, memory, and the outbound queue live in tables under
`ow`. The system is driven by PL/pgSQL
functions and `pg_durable` workflows that run **inside the database backend**.

This PR delivers a least-privilege **Attribute-Based Access Control** layer over
PostgreSQL **Row-Level Security**, and makes it **enforced** for the
security-critical path:

- A **separate role per agent** (`ow_agent_primary`,
  `ow_agent_sidecar`), plus tiers `ow_anonymous`,
  `ow_authenticated`, `ow_service`.
- **Attributes** carried as session GUCs (`ow.current_agent_id`,
  `ow.current_telegram_user_id`, …) that policies read fail-closed.
- A channel-agnostic **`ow.users`** ledger that auto-tracks telegram user
  ids (and is shaped for discord/whatsapp).
- Anonymous/authenticated `SELECT` on `messages` scoped to the **whole
  configured chat**; INSERT/UPDATE pinned to their own rows; never DELETE.
- **When the primary agent runs the SQL tool during a user-requested turn, it
  executes under that user's RLS scope** — the agent cannot reach another user's
  data or the agent's secrets through SQL. Scheduled/agent-initiated turns run
  with framework scope.

The durable framework still connects as the `postgres` superuser (that is the
trusted orchestrator). Enforcement is achieved by **deliberately dropping
privileges** (`SET ROLE` to the user's tier + setting GUCs) around the SQL
tool's query — the one tool that does arbitrary data access. This is the
standard trusted-orchestrator + privilege-drop-at-boundary pattern; it avoids
re-architecting `pg_durable`'s `worker_role`.

---

## 2. Goals & non-goals

**Goals**

- Per-agent and per-user isolation; secrets never exposed to user scope.
- The agent's database queries are bounded to the requesting user.
- `ow.users` tracking that extends to future channels.
- A non-breaking-on-data, idempotent migration.

**Non-goals (this PR)**

- Running the `pg_durable` framework or the agent's own context-build under
  non-superuser principals (future hardening — see [§11](#11-enforcement-status)).
- Cross-channel identity *linking* (one person, many channels). The table
  supports new channels; merging identities is additive later.
- Network/transport security, secret encryption at rest.

---

## 3. Threat model & trust boundaries

| Boundary | Trusted? | Implication |
|---|---|---|
| Telegram Bot API → us | **Yes (bot-token-authenticated)** | A delivered message's `from.id`/`chat.id` are trustworthy. |
| The DB backend (`pg_durable`, triggers) | **Yes (trusted compute)** | Runs as `postgres` superuser. This is the orchestrator. |
| A telegram user in the group | **No** | Constrained by RLS; the agent's SQL runs as them. |

RLS only constrains principals that are **not** superuser/table-owner. The
framework is superuser, so it bypasses RLS — by design. We make that bypass
*irrelevant to the user-isolation goal* by dropping to the user's role at the
SQL-tool boundary ([§10](#10-user-scoped-tool-execution)). The roles and table
policies also serve as defense-in-depth for any future direct least-privilege
connections.

---

## 4. Roles

```text
ow_agent_primary         # primary agent's turn execution
ow_agent_sidecar    # review/meta agent; never talks to operators

ow_service               # sidecar's broad tool scope; BYPASSRLS trusted compute

ow_authenticated         # a registered telegram operator (escalation tier)
ow_anonymous             # any telegram user in the configured group chat
```

The two tiers and `ow_service` are `NOLOGIN` *capabilities*; the two agent
roles are `LOGIN` (the pg_durable worker connects as the submitted role, which
must be a non-superuser `LOGIN` role). `ow_service` is `BYPASSRLS`. A
`users.tier` value (`anonymous` | `authenticated`) selects which tier a tracked
user maps to. Operators promote a user with
`UPDATE ow.users SET tier='authenticated' WHERE ...`.

---

## 5. Attributes (the "A" in ABAC)

Policies read session GUCs fail-closed (`current_setting(..., true)` returns
NULL when unset → `NULL = x` → NULL → **deny**):

| GUC | Set by | Read by RLS policies for |
|---|---|---|
| `ow.current_agent_id` | turn/tool bootstrap | agent-scoping of `messages`, `memory`, `memory_sources`, `config` |
| `ow.current_chat_id` | tool bootstrap | `messages` chat-wide SELECT (the configured chat) |
| `ow.current_user_id` | tool bootstrap | `users` own-row SELECT |
| `ow.current_role`, `ow.current_channel`, `ow.current_telegram_user_id` | `set_context` | carried for the loop/tool; no RLS policy reads them today |

`ow.set_context(p_role, p_agent_id, p_telegram_user_id, p_telegram_chat_id,
p_user_id, p_channel)` sets them all (3-arg `set_config`, transaction-local).

---

## 6. `ow.users` — channel identity ledger

```sql
CREATE TABLE ow.users (
  id bigserial PRIMARY KEY,
  channel text NOT NULL CHECK (channel IN ('telegram','discord','whatsapp')),
  external_id text NOT NULL,
  username text,
  display_name text,
  tier text NOT NULL DEFAULT 'anonymous' CHECK (tier IN ('anonymous','authenticated')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (channel, external_id)
);
```

`ow.process_telegram_updates` upserts each accepted sender via
`ow.upsert_user('telegram', from.id, from.username, from.first_name,
from)` and remembers the **last accepted** user's internal id as the turn's
**requesting user** (`start_turn(p_agent_slug, p_requesting_user_id)`).
(Multi-user poll batches attribute the turn to the last accepter — a documented
approximation; per-message turns are a later refinement.)

---

## 7. Least-privilege access matrix

"own chat" for a telegram user =
`agent_id = current_setting('ow.current_agent_id')::bigint AND chat_id = current_setting('ow.current_chat_id')`.
"own agent" for an agent role =
`agent_id = current_setting('ow.current_agent_id')::bigint`.

| Table | `anonymous` | `authenticated` | `agent_primary` | `agent_sidecar` | `service` |
|---|---|---|---|---|---|
| `agents` | SELECT | SELECT | SELECT | SELECT | SELECT; writer (I/U/D) |
| `models` | SELECT | SELECT | SELECT | SELECT | SELECT; writer (I/U/D) |
| `messages` | **SELECT own chat; no writes** | same | SELECT/INSERT/UPDATE own; no DELETE | SELECT/INSERT/UPDATE own; no DELETE | ALL |
| `memory` | — | — | ALL own agent | ALL across agents | ALL |
| `memory_sources` | — | — | ALL own agent | ALL across agents | ALL |
| `config` | SELECT non-secret own | SELECT non-secret own | SELECT own (incl. secrets); I/U own | SELECT own (incl. secrets); I/U own | non-secret only (`config_public` view) |
| `users` | SELECT own row | SELECT own row | SELECT all; INSERT/UPDATE | SELECT all (writes RLS-denied) | ALL |

The `ow_dashboard` role is `BYPASSRLS` with `SELECT`/`EXECUTE` only across
these tables (the admin dashboard's read-only DB principal; secrets are redacted
by the dashboard API, not the database). The full matrix is enforced and
exercised by `tests/pgtap/` — that suite is the authoritative reference; this
table is kept in sync with it.

Two least-privilege decisions:

- **Secrets are kept out of every LLM-tool scope.** Agent roles read their own
  `secret = true` config (`api_key`, `telegram_token`) from fixed loop code, and
  neither LLM-SQL tool scope can read secrets: the user tier
  (`anonymous`/`authenticated`) has SELECT on non-secret own rows only, and
  `ow_service` (the sidecar's tool scope) has no grant on the base
  `config` table — it reads non-secret rows only through the `config_public` view,
  so its `BYPASSRLS` flag cannot reach secrets (no grant → no rows). Today only the
  superuser and `ow_dashboard` see secrets (the dashboard API redacts them).
- **`messages` SELECT is chat-wide for users; users never write.** The whole
  conversation belongs to one configured chat = one agent, so a user sees all of
  it (including other users' messages and the agent's replies). Anonymous and
  authenticated hold `SELECT` only — they cannot `INSERT`/`UPDATE`/`DELETE`; the
  agent role appends messages on their behalf.

---

## 8. The worked example: anonymous group-chat user on `messages`

Anonymous/authenticated users **read** the whole configured chat and **never
write** — the agent role appends messages on their behalf. (An earlier design
gave users their own INSERT/UPDATE scoped to `from.id`; that was dropped so the
LLM can never author message rows directly.)

```sql
-- SELECT: the whole configured chat (one agent = one chat)
CREATE POLICY messages_user_select ON ow.messages
  FOR SELECT TO ow_anonymous, ow_authenticated
  USING (
    agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint
    AND chat_id = NULLIF(current_setting('ow.current_chat_id', true), '')::text
  );

-- The agent roles append and edit their own agent's rows (FOR ALL, no DELETE grant):
CREATE POLICY messages_agent_all_own ON ow.messages
  FOR ALL TO ow_agent_primary, ow_agent_sidecar
  USING (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint);

-- Users get SELECT only — no INSERT/UPDATE/DELETE grant, so they cannot write at all.
GRANT SELECT ON ow.messages TO ow_anonymous, ow_authenticated;
```

> **Gotcha (validated).** A `bigserial` PK is backed by a `<table>_<col>_seq`
> sequence; INSERT needs `USAGE` on it (nextval) **in addition to** INSERT on the
> table. The SQL grants `USAGE` per inserting role (the agent roles, not the
> tiers).

---

## 9. RLS policy catalog

All tables: `ENABLE ROW LEVEL SECURITY` (never `FORCE`). `ow_service` is
`BYPASSRLS` (trusted compute); everything else scoped. Full set in
`docker-entrypoint-initdb.d/40-ow-rbac.sql`, behaviour verified in
`tests/pgtap/`. Highlights:

- **messages** — as [§8](#8-the-worked-example-anonymous-group-chat-user-on-messages); users SELECT the configured chat only; agent roles `FOR ALL` on `agent_id = current_agent_id`.
- **users** — own row by `id = current_user_id` for tiers; agents read all; `agent_primary` inserts/updates (no delete); service full.
- **config** — agent roles `SELECT`/`INSERT`/`UPDATE` their **own rows incl. secrets**; tiers `SELECT` non-secret own only; `ow_service` has no grant on the base table and reads non-secret rows only via the `config_public` view (secret-free LLM-SQL scope).
- **memory / memory_sources** — agent-scoped by `current_agent_id`; `agent_primary` full-CRUDs its own; `agent_sidecar` full-CRUDs every agent's.
- **agents / models** — PUBLIC read; service/superuser writes.

---

## 10. User-scoped tool execution (the enforcement centerpiece)

When the primary agent runs the **SQL tool** during a user-requested turn, the
query executes under the **requesting user's** RLS scope. (Other tools —
attachments, web fetches — stay agent-scoped: they touch
agent-global state with no per-user dimension.)

**Threading the requesting user.** Intake stamps the user onto the assistant
message that originates the tool call — no change to the tool-signal machinery:

1. `process_telegram_updates` upserts the sender and calls
   `start_turn(p_agent_slug, p_requesting_user_id)`.
2. `start_turn` threads it into `record_assistant_from_http(..., p_requesting_user_id)`
   and the recursive `start_turn` (follow-up turns keep the same user).
3. `record_assistant_from_http` stamps `payload.requesting_user_id` onto the
   assistant message.
4. `_execute_sync_tool_call(p_message_id, ...)` reads it back off that message.

**Privilege drop.** `_execute_sync_tool_call` routes the SQL tool through
`ow_tools._tool_sql_as_user` when a requesting user is present:

```sql
EXECUTE format('SET ROLE %I', p_role);            -- service → user tier; RLS now binds
PERFORM set_config('ow.current_agent_id',    p_agent_id::text, true);
PERFORM set_config('ow.current_telegram_user_id', p_telegram_user_id, true);
PERFORM set_config('ow.current_telegram_chat_id', p_telegram_chat_id, true);
-- run the agent's query as the user (RLS-enforced), then ALWAYS reset:
BEGIN EXECUTE format('SELECT jsonb_agg(to_jsonb(q)) FROM (%s) q', v_query) INTO v_rows;
EXCEPTION WHEN OTHERS THEN v_err := SQLERRM; EXECUTE 'RESET ROLE'; RAISE EXCEPTION '%', v_err;
END;
EXECUTE 'RESET ROLE';
```

Properties that make this safe:

- `SET ROLE` from the superuser session to a non-superuser tier drops
  `BYPASSRLS`, so the inner query is RLS-bounded.
- `RESET ROLE` runs on both the success and error paths — the dropped role never
  leaks to the framework's subsequent steps.
- The result-append (`_append_tool_message`, role='tool') happens **after**
  `RESET ROLE`, so it runs privileged and isn't blocked by the user's INSERT
  `WITH CHECK`.
- All involved functions are `SECURITY INVOKER` — `SET ROLE` is forbidden inside
  `SECURITY DEFINER`.
- Scheduled/heartbeat turns pass `NULL` → the SQL tool falls back to
  `_tool_sql` (framework scope) via `_execute_sync_tool_call`.

**Pre-existing note:** the SQL tool wraps the user query as
`SELECT … FROM (<query>) q`, so it only supports `SELECT`-shaped queries today
(Postgres disallows data-modifying CTEs nested in a subquery). This is a
pre-existing limitation of `_tool_sql`, unchanged by this PR; the INSERT RLS
policy is validated directly.

---

## 11. Enforcement status

Durable instances no longer run as the superuser. `pg_durable.enable_superuser_instances`
is OFF (default), and the workflow-starting functions (`_start_durable_loop_once`,
`start_turn`, `start_telegram_outbox_send`) are `SECURITY DEFINER` owned by
`ow_service`, so every `df.start` submits as that non-superuser role. The
pg_durable worker connects as `ow_service` (hence it is `LOGIN`) to execute
instance SQL, so **all durable execution — the agent's own context-build included
— runs as `ow_service`** with RLS enforced (service holds bypass policies,
so its own operations are unrestricted).

| Path | Runs as | Bounded by |
|---|---|---|
| Agent SQL tool on a user-requested turn | requesting user's tier (`SET ROLE` in `_tool_sql_as_user`) | user RLS — can't see other users' data or secrets |
| Agent SQL tool on a scheduled turn | `ow_service` | service bypass (full agent scope) |
| Agent's own context-build (`compose_llm_request`, append, outbox) | `ow_service` | service bypass (the agent's own conversation) |
| pg_durable background worker | `postgres` (superuser) | required by pg_durable — `worker_role` must be superuser |

`df.grant_usage` is granted to the agent/service roles (`service`,
`agent_primary`, `agent_sidecar`, each with HTTP). `ow_service` is a member of
the user tiers so `_tool_sql_as_user` can `SET ROLE` down to them; and because
instance sessions have `session_user = ow_service`, `RESET ROLE` restores to
`service` (never escalates to a superuser). End-user tiers
(`ow_anonymous`/`ow_authenticated`) are intentionally **not** granted df
access — they interact via the agent.

**Why `worker_role` stays superuser:** pg_durable requires the background worker
to be a superuser to manage all instances; this is the framework's design and is
unrelated to per-user isolation, which is enforced at the instance / SQL-tool
boundary above.

---

## 12. Prior attempt & why this is different

A prior implementation on `feature/abac-rls-security` (commit `80039aa`) was
never merged. Defects fixed here:

1. **Privilege/policy mismatch** — it `GRANT`ed only `SELECT` but wrote `FOR ALL`
   policies, so no write could succeed. We grant the exact column privileges each
   policy implies (and omit `DELETE` deliberately).
2. **Inline function re-definition** — it re-declared core functions inline
   (drift hazard). We never redefine existing functions in the policy file.
3. **Broken `set_context`** — 2-arg `set_config` (doesn't exist). Fixed to 3-arg.
4. **Secrets exposed to agents** — its `config_agent_all_own` gave agents `ALL`
   on `config` incl. secrets. We hide `secret` rows and route writes via
   `set_config`.

---

## 13. Migration safety & rollback

- **Idempotent** — guarded role creation, `DROP POLICY IF EXISTS` + `CREATE`,
  repeatable `ENABLE ROW LEVEL SECURITY`.
- **`ENABLE` not `FORCE`** — the superuser framework is unaffected; data is
  untouched.
- **Ordering** — `40-ow-rbac.sql` runs last, after all tables/functions.
- **Rollback** — `DISABLE ROW LEVEL SECURITY`, `DROP POLICY`, `REVOKE`,
  `DROP ROLE`. None touch user data.

---

## 14. Validated behaviors (Postgres 18)

Loaded `10`→`40` under `ON_ERROR_STOP=1`, then a behavior harness:

- `upsert_user` upserts with stable id; tier preserved across re-upsert after promotion.
- Expanded anonymous `SELECT` returns the whole chat (incl. other users + assistant).
- SQL tool via `_execute_sync_tool_call` as user 111: reads chat-wide messages;
  `SELECT … FROM ow.config` → `permission denied`; forged INSERT (as 222)
  → `row-level security policy` denied; own INSERT (as 111) allowed;
  `current_user = postgres` after (no leak).
- Scheduled turn (no requesting user): `config` is readable (framework scope).

---

## 15. Open questions

1. Promote users to `authenticated` via a dedicated promotion function vs. direct
   `UPDATE` (currently direct).
2. Per-message turns instead of last-accepter attribution for multi-user batches.
3. Widen the SQL tool to support writes (data-modifying CTE at top level) so
   user-scoped writes are exercisable through the agent.
