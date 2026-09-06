-- SQL activity runtime. All durable data is ordinary pg_dump-visible application data.
-- Install in filename order; scheduler startup is in 46-robot-runtime-durable.sql.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'robot_runtime_store') THEN
    CREATE ROLE robot_runtime_store NOLOGIN;
    CREATE ROLE robot_runtime_worker LOGIN;
    CREATE ROLE robot_runtime_admin NOLOGIN;
    CREATE ROLE robot_runtime_operator NOLOGIN;
    CREATE ROLE robot_runtime_adapter NOLOGIN;
    CREATE ROLE robot_runtime_observer NOLOGIN;
  END IF;
END $$;
ALTER ROLE robot_runtime_worker SET statement_timeout = '5s';
ALTER ROLE robot_runtime_worker SET lock_timeout = '1s';
CREATE SCHEMA IF NOT EXISTS robot_runtime AUTHORIZATION robot_runtime_store;
REVOKE ALL ON SCHEMA robot_runtime FROM PUBLIC;
GRANT USAGE ON SCHEMA robot_runtime TO robot_runtime_worker, robot_runtime_admin,
  robot_runtime_operator, robot_runtime_adapter, robot_runtime_observer;
SET LOCAL ROLE robot_runtime_store;
-- Per-schema defaults cannot revoke PostgreSQL's global PUBLIC EXECUTE default.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TYPE robot_runtime.activity_ref AS (activity_id uuid, generation bigint);
CREATE TYPE robot_runtime.intent AS (
  intent_id uuid, kind text, schema_version integer, payload jsonb, source text,
  message_id uuid, observed_at timestamptz, expires_at timestamptz
);
CREATE TYPE robot_runtime.reduce_context AS (
  activity_id uuid, generation bigint, effect_epoch bigint, revision bigint, now timestamptz
);
CREATE TYPE robot_runtime.transition AS (
  new_state jsonb, next_lifecycle text, effects jsonb, timers jsonb, events jsonb
);

CREATE TABLE robot_runtime.settings (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  enabled boolean NOT NULL DEFAULT true,
  executors integer NOT NULL DEFAULT 1 CHECK (executors BETWEEN 1 AND 8),
  max_payload_bytes integer NOT NULL DEFAULT 65536 CHECK (max_payload_bytes BETWEEN 1024 AND 1048576),
  max_mailbox integer NOT NULL DEFAULT 256 CHECK (max_mailbox BETWEEN 1 AND 10000),
  max_effects integer NOT NULL DEFAULT 32 CHECK (max_effects BETWEEN 1 AND 256),
  max_timers integer NOT NULL DEFAULT 32 CHECK (max_timers BETWEEN 1 AND 256),
  max_rate integer NOT NULL DEFAULT 100 CHECK (max_rate BETWEEN 1 AND 10000)
);
INSERT INTO robot_runtime.settings DEFAULT VALUES ON CONFLICT DO NOTHING;
CREATE TABLE robot_runtime.activity_definition (
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
  version integer NOT NULL CHECK (version > 0),
  reducer regprocedure NOT NULL,
  reducer_signature text NOT NULL,
  reducer_fingerprint text NOT NULL,
  owner name NOT NULL,
  initial_state jsonb NOT NULL,
  contract jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (name, version)
);
CREATE TABLE robot_runtime.activity_instance (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definition_name text NOT NULL,
  definition_version integer NOT NULL,
  owner name NOT NULL,
  started_by name NOT NULL,
  idempotency_key uuid NOT NULL,
  start_request jsonb NOT NULL,
  label text,
  state jsonb NOT NULL,
  lifecycle text NOT NULL DEFAULT 'created' CHECK (lifecycle IN ('created','active','paused','stopping','stopped','faulted')),
  generation bigint NOT NULL DEFAULT 1,
  effect_epoch bigint NOT NULL DEFAULT 1,
  revision bigint NOT NULL DEFAULT 0,
  next_sequence bigint NOT NULL DEFAULT 0,
  barrier_pending boolean NOT NULL DEFAULT false,
  rate_window timestamptz NOT NULL DEFAULT clock_timestamp(),
  rate_count integer NOT NULL DEFAULT 0,
  rejected_count bigint NOT NULL DEFAULT 0,
  last_rejection text,
  last_rejected_at timestamptz,
  last_scheduled_at timestamptz NOT NULL DEFAULT '-infinity',
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (started_by, idempotency_key),
  FOREIGN KEY (definition_name, definition_version) REFERENCES robot_runtime.activity_definition
);
CREATE TABLE robot_runtime.activity_inbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  activity_id uuid NOT NULL REFERENCES robot_runtime.activity_instance,
  generation bigint NOT NULL,
  sequence bigint NOT NULL,
  source text NOT NULL,
  message_id uuid NOT NULL,
  kind text NOT NULL,
  payload jsonb NOT NULL,
  request jsonb NOT NULL,
  observed_at timestamptz NOT NULL,
  expires_at timestamptz,
  priority smallint NOT NULL DEFAULT 0,
  delivery text NOT NULL CHECK (delivery IN ('fifo','latest','barrier','reject_if_busy')),
  replace_key text,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processed','superseded','stale','expired','rejected','failed')),
  accepted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  processed_at timestamptz,
  UNIQUE (activity_id, source, message_id),
  UNIQUE (activity_id, sequence)
);
CREATE INDEX inbox_pending ON robot_runtime.activity_inbox (activity_id, priority DESC, sequence) WHERE status = 'pending';
CREATE TABLE robot_runtime.activity_history (
  activity_id uuid NOT NULL REFERENCES robot_runtime.activity_instance,
  generation bigint NOT NULL,
  revision bigint NOT NULL,
  intent_id uuid NOT NULL,
  old_revision bigint NOT NULL,
  lifecycle text NOT NULL,
  state_hash text NOT NULL,
  effect_ids uuid[] NOT NULL DEFAULT '{}',
  events jsonb NOT NULL DEFAULT '[]',
  error_code text,
  committed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (activity_id, generation, revision)
);
CREATE TABLE robot_runtime.activity_timer (
  activity_id uuid NOT NULL REFERENCES robot_runtime.activity_instance,
  generation bigint NOT NULL,
  timer_id text NOT NULL,
  due_at timestamptz NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','fired','cancelled')),
  PRIMARY KEY (activity_id, generation, timer_id)
);
CREATE INDEX timers_due ON robot_runtime.activity_timer (due_at, activity_id) WHERE status = 'pending';
CREATE TABLE robot_runtime.adapter_registration (
  name text PRIMARY KEY,
  owner name NOT NULL,
  protocol_versions integer[] NOT NULL,
  capabilities text[] NOT NULL,
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- Fence counters outlive holders. Shared holders use separate rows under one resource.
CREATE TABLE robot_runtime.capability_resource (
  adapter text NOT NULL REFERENCES robot_runtime.adapter_registration,
  capability text NOT NULL,
  resource_key text NOT NULL,
  fence bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (adapter, capability, resource_key)
);
CREATE TABLE robot_runtime.capability_lease (
  adapter text NOT NULL,
  capability text NOT NULL,
  resource_key text NOT NULL,
  gateway text NOT NULL,
  mode text NOT NULL CHECK (mode IN ('exclusive','shared')),
  fence bigint NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (adapter, capability, resource_key, gateway),
  FOREIGN KEY (adapter, capability, resource_key) REFERENCES robot_runtime.capability_resource
);
CREATE TABLE robot_runtime.effect_outbox (
  id uuid PRIMARY KEY,
  activity_id uuid NOT NULL REFERENCES robot_runtime.activity_instance,
  generation bigint NOT NULL,
  effect_epoch bigint NOT NULL,
  revision bigint NOT NULL,
  effect_index integer NOT NULL,
  adapter text NOT NULL,
  protocol_version integer NOT NULL,
  capability text NOT NULL,
  resource_key text NOT NULL,
  operation text NOT NULL,
  payload jsonb NOT NULL,
  lane text NOT NULL DEFAULT 'default',
  delivery text NOT NULL CHECK (delivery IN ('fifo','latest_wins','barrier')),
  replace_key text,
  priority smallint NOT NULL DEFAULT 0,
  scope text NOT NULL DEFAULT 'ordinary' CHECK (scope IN ('ordinary','stop','fault')),
  expires_at timestamptz,
  deadline_at timestamptz,
  retry_class text NOT NULL CHECK (retry_class IN ('idempotent','reconcile','never')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','claimed','succeeded','failed','timed_out','expired','ambiguous','cancelled','reconciled')),
  claim_token uuid,
  claim_expires_at timestamptz,
  gateway text,
  fence bigint,
  outcome jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (activity_id, generation, revision, effect_index)
);
CREATE INDEX effects_pending ON robot_runtime.effect_outbox (adapter, capability, resource_key, activity_id) WHERE status = 'pending';
CREATE INDEX effects_activity ON robot_runtime.effect_outbox (activity_id, status);
CREATE TABLE robot_runtime.effect_attempt (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  effect_id uuid NOT NULL REFERENCES robot_runtime.effect_outbox,
  claim_token uuid,
  gateway text,
  fence bigint,
  outcome text NOT NULL,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE robot_runtime.dead_letter (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  activity_id uuid NOT NULL REFERENCES robot_runtime.activity_instance,
  intent_id uuid,
  effect_id uuid,
  reason text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE robot_runtime.worker_epoch (
  slot integer PRIMARY KEY,
  instance_id text,
  epoch bigint NOT NULL DEFAULT 1,
  started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_seen_at timestamptz,
  transitions bigint NOT NULL DEFAULT 0,
  last_error text
);
COMMIT;
