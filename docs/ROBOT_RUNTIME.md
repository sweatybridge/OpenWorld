# SQL robot activity runtime

OpenWorld implements the activity model from `plan.md` in SQL and PL/pgSQL.
`pg_durable` drives the scheduler. The runtime is application schema, installed
by `42-robot-runtime-schema.sql` through `46-robot-runtime-durable.sql`; it does
not require a new shared library, a hardware SDK, or a separate extension package.
This supersedes the original plan's standalone packaging, Rust/pgrx, and custom
background-worker requirements. Existing OpenWorld conversations still use their
existing workflows.

## Installation and operation

Fresh `docker compose up --build` databases install the runtime automatically.
The `runtime-init` service then starts the supervisor and exits; it retries if
`pg_durable` is not ready yet. Schema initialization itself does not start workflows.
For an existing database, back it up, apply the five new SQL files in filename
order as the database administrator, call `robot_runtime.ensure_scheduler()`,
and check `robot_runtime.worker_health`.
These are the initial schema migration, not scripts to rerun on an installed
runtime. PostgreSQL 18 and this repo's pinned `pg_durable` release are the initial
supported configuration.

The scheduler uses one supervisor workflow and one executor by default. Executors
run a short `robot_runtime.tick(slot)` SQL statement, immediately repeat while
work exists, and use `df.sleep(1)` when idle. No sleeping SQL transaction holds an
activity lock. The supervisor checks executor workflows every five seconds and
recreates missing/failed executors. PostgreSQL restart recovery is provided by
`pg_durable`; all runtime work remains in ordinary durable tables.

```sql
SELECT * FROM robot_runtime.worker_health;
SELECT * FROM robot_runtime.activities;
SELECT * FROM robot_runtime.pending_timers;
SELECT * FROM robot_runtime.effects;

-- Administrator only. Configure within the existing pg_durable connection and
-- worker budget; each slot is a workflow, not a new custom background worker.
UPDATE robot_runtime.settings SET executors = 2;
SELECT robot_runtime.ensure_scheduler();

-- Graceful pause: current transactions finish; scheduler loops then exit.
UPDATE robot_runtime.settings SET enabled = false;
-- Resume, or recreate the supervisor after manual workflow cancellation:
UPDATE robot_runtime.settings SET enabled = true;
SELECT robot_runtime.ensure_scheduler();
```

Idle polling adds approximately one second before scheduling overhead. This is
an activity coordinator, not a real-time control loop. A worker SQL statement
has a five-second timeout and a one-second lock timeout. Unexpected scheduler
errors are recorded as SQLSTATE in `worker_health.last_error`; failed reducers
record an error revision and fault that activity while other activities progress.
Payloads and arbitrary reducer exception messages are excluded from logs.

## Define and run an activity

An administrator installs and approves a reducer. Its unprivileged function owner
is also the activity owner, and callers need membership in that role (or runtime
administrator privileges) to start or operate its activities. Reducers execute
as that owner through `SECURITY DEFINER`, with exactly the fixed search path below.
They must be deterministic and use the supplied context for time and identity.

```sql
-- Run installation as an administrator.
CREATE ROLE counter_owner NOLOGIN;
GRANT robot_runtime_operator, robot_runtime_observer TO counter_owner;
CREATE SCHEMA counter_demo;
GRANT USAGE ON SCHEMA counter_demo TO counter_owner, robot_runtime_store;

CREATE FUNCTION counter_demo.reduce(
    state jsonb, intent robot_runtime.intent,
    context robot_runtime.reduce_context
) RETURNS robot_runtime.transition
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF intent.kind = 'increment' THEN
    state := jsonb_set(state, '{count}',
      to_jsonb((state->>'count')::integer + (intent.payload->>'by')::integer));
  END IF;
  RETURN (state, NULL, '[]', '[]', '[]')::robot_runtime.transition;
END;
$$;
ALTER FUNCTION counter_demo.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)
  OWNER TO counter_owner;
REVOKE ALL ON FUNCTION counter_demo.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION counter_demo.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context) TO robot_runtime_store;

SELECT robot_runtime.define('counter', 1,
  'counter_demo.reduce(jsonb,robot_runtime.intent,robot_runtime.reduce_context)',
  '{"count":0}', '{"state_schema":{"type":"object","required":["count"]},
    "intents":{"increment":{"schema":{"type":"object","required":["by"],
      "properties":{"by":{"type":"integer"}},"additionalProperties":false}}}}');

SET ROLE counter_owner;
SELECT robot_runtime.start('counter', 1, '{}', 'example',
  '10000000-0000-0000-0000-000000000001');
-- Substitute the returned activity_id and generation:
-- SELECT robot_runtime.send(ROW('<activity_id>',1)::robot_runtime.activity_ref,
--   'increment','{"by":1}','10000000-0000-0000-0000-000000000002');
-- SELECT robot_runtime.inspect('<activity_id>');
RESET ROLE;
```

Definitions are immutable `(name, version)` records. `start` pins a version.
Registered reducer definition changes fault subsequent reductions. The runtime
resolves its qualified signature on execution, so a logical restore can assign
new PostgreSQL OIDs. New implementations must use new reducer functions and
definition versions; running activities never migrate implicitly.

`IMMUTABLE` is a contract, not a sandbox. Administrators must audit the reducer,
its dependencies, its owner's privileges, and later changes to those dependencies.
Do not approve functions that use network, filesystem, mutable tables, random
IDs, or the wall clock. Runtime fingerprints do not freeze transitive dependencies
or prevent a trusted administrator from changing code. Native/untrusted-language
reducers and deliberately hostile administrator code are outside the isolation
guarantee. The supplied `context.now` is the accepted intent timestamp and stays
stable if an uncommitted reduction is retried.

## Contracts and lifecycle

The transition composite contains `new_state`, optional `next_lifecycle`, and
JSON arrays `effects`, `timers`, and `events`. The complete result must fit the
payload limit. State validation, history append, timer/effect creation, and intent
acknowledgement share one transaction. A failed application rolls back all of
those writes before recording a fault revision with unchanged user state.

Supported JSON Schema keywords are `type`, `properties`, `required`,
`additionalProperties` (boolean), `items`, `enum`, `minimum`, `maximum`,
`maxLength`, and `maxItems`, with nesting limited to 16. Unknown keywords fail
definition registration, including remote references. This is a documented
subset, not full JSON Schema conformance.

Each ordinary intent has a schema and optional `delivery`, `priority`,
`replace_key`, and `adapters` settings. Delivery is bounded `fifo`, keyed `latest`,
or `reject_if_busy`. Keys identify an observation stream declared by the
definition; they are not taken from untrusted payloads. FIFO is ordered within
priority; lifecycle barriers outrank ordinary work. Global `settings` ceilings
bound per-definition payload bytes, pending intents, outstanding effects/timers,
and ordinary intents per second. Internal timer/completion intents have a
separate bounded reserve so ordinary traffic cannot suppress completions.

`lifecycle.start` activates a new activity. Pause cancels existing timers and
effects and prevents ordinary reduction until resume. Resume advances generation
and effect epoch; prior-generation pending messages become stale. Stop and fault
barriers invalidate queued/claimed effects when the barrier is accepted, before
its reducer runs. Lifecycle barriers cannot have an expiry. A stop reducer reaches `stopped`; a fault reducer reaches
`faulted`. They may emit only respectively scoped `stop`/`fault` effects with an
explicit deadline within five seconds of acceptance. No previous activity is
implicitly resumed.

Ordinary reducers may finish or fault their activity, but cannot arbitrarily
pause/resume it. Reducer failure faults directly, avoiding repeated execution of
a failing fault handler. A started activity's initial intent must be reduced
before a pause can be accepted.

Accepted messages are deduplicated by `(activity, authenticated source,
message_id)`. Reusing an identity with changed content raises an error. Generated
observation timestamps are excluded from the retry comparison; explicitly supplied
timestamps are compared as instants. Supply stable IDs when retrying after a lost
connection. Start keys are scoped to the authenticated caller.

Rejected messages return a structured receipt with no intent ID and are not
accepted retry identities: the same request may be accepted after congestion
clears. Rejection counters and a bounded, payload-free trail record overload.
Caller rollback also rolls back these diagnostics. Unexpected SQL errors use
PostgreSQL's normal transaction error semantics.

## Adapter SQL protocol 1

An administrator registers an adapter name, dedicated role, capabilities, and
`ARRAY[1]` as protocol versions. Adapters use only the public functions:

```sql
SELECT robot_runtime.register_adapter('device', 'device_adapter', ARRAY['arm']);
-- As device_adapter, a member of robot_runtime_adapter:
SELECT robot_runtime.adapter_heartbeat('device');
SELECT robot_runtime.acquire_capability('device','arm','robot-1','gateway-1');
-- Use the returned fence:
SELECT * FROM robot_runtime.claim_effects('device','arm','robot-1','gateway-1',1);
-- Complete using the returned effect ID, claim token, gateway and fence:
-- SELECT robot_runtime.complete_effect(effect_id,claim_token,'device','gateway-1',1,'succeeded','{}');
```

An effect specifies `adapter`, `capability`, `resource_key`, `operation`, optional
`protocol_version` (1), `payload`, `lane`, `delivery`, `replace_key`, `priority`,
`scope`, `expires_at`, `deadline_at`, and `retry_class`. Effect identity derives
from activity ID, generation, revision, and effect index. Lanes have one in-flight
effect; unresolved ambiguity blocks later work in that lane. `latest_wins`
replaces pending effects with the same key; a `barrier` cancels pending work of
no greater priority in its lane. Executing physical work cannot be retracted.

Capability leases support `exclusive` and `shared` modes. Expired holders cannot
renew; reacquisition increments a durable resource fence. Shared holders retain
their individually issued valid fences, so a newer shared holder does not evict
older live shared holders. Adapters must enforce their issued fences before
physical execution; database fencing cannot enforce behavior at hardware.

Claims have random tokens, a bounded lifetime, and an expiry no later than their
capability lease, effect expiry, or deadline. Completion checks all of these plus
generation and effect epoch. Repeated identical completions return the original
receipt; conflicting completions return `conflict` and append an audit record.
Late completions return `stale` and remain auditable without changing user state.

Expired `idempotent` claims can be retried. `reconcile` and `never` claims become
`ambiguous` and are never automatically redelivered. Use `reconcile_effect` under
a current capability lease after checking the external outcome. Ambiguity and
final reconciliation have distinct deterministic intent identities. A timeout
is never reported as success.

Adapters may publish only nonreserved intents whose definition explicitly lists
their name in `adapters`, and only after an effect binds that adapter to the
activity generation. Observation publication is adapter-role-wide, not fenced
to a gateway lease; use `observed_at`, `expires_at`, and reducer validation for
observation freshness. Command completion always requires the claim and fence.

Timers specify `timer_id`, `due_at`, and optional `payload`, or `cancel:true`.
A pending timer may be rescheduled. A fired/cancelled ID cannot fire again in
the same generation; use a new ID for a new logical timer.

## Security, backup, and removal

`robot_runtime_store` owns internal objects and cannot log in. Do not grant this
role or `robot_runtime_worker` to applications. Administrator, operator, adapter,
and observer roles have explicit function grants; PUBLIC has none. Operators
and observers see owner-authorized rows under RLS. OpenWorld agents receive
operator access; the existing administrative dashboard receives observer access
and retains its existing BYPASSRLS behavior. Definitions still require explicit
approval by a runtime administrator.

Use normal PostgreSQL backup for the whole database. A schema-only selection
must also include reducer schemas and role provisioning; do not start the
scheduler during partial restore. Durable activity state, accepted retry
identities, timers, effects, attempt receipts, and history are ordinary table
data. Restore a consistent backup before enabling the scheduler. After restoring
an older backup, reconcile physical device state and isolate previous gateways
before allowing execution: database restore cannot establish a physical fence
against a gateway from a later timeline.

`prune_diagnostics()` removes old terminal diagnostics in bounded batches and
preserves accepted retry identities, completion receipts, history, and active or
ambiguous work. Durable audit history is intentionally retained; monitor storage
and explicitly archive terminal activities if needed. There is no automatic
activity deletion or migration in this first schema version.

To remove the runtime, disable scheduling, wait for its workflows to finish,
stop adapters, and take a backup before dropping the schema. Dropping it destroys
its durable state. Existing `df` workflows are separate and must be retained or
removed according to the application's workflow retention policy.

## Verification

The pgTAP suite includes `95_robot_runtime.sql` and uses a SQL mock reducer and
adapter fixture. Worker integration tests exercise committed ingress under the
actual `pg_durable` scheduler. Run against disposable databases only:

```bash
docker compose -f docker-compose.test.yml run --rm -T pgtap
bash tests/robot-runtime-e2e.sh
```
