-- ============================================================================
-- OpenWorld ABAC / Row-Level Security — Phase 1 (define the layer)
-- ============================================================================
-- Companion to docs/abac-rls-security-design.md. Read that doc first.
--
-- What this file does:
--   * Creates the capability roles (NOLOGIN).
--   * Grants schema usage + table column privileges + EXECUTE on functions,
--     with column privileges that EXACTLY match the policies below
--     (e.g. ow_anonymous gets INSERT,UPDATE,SELECT on messages — never
--     DELETE; RLS policies do not confer privileges, GRANT does).
--   * ENABLE ROW LEVEL SECURITY on every table (never FORCE).
--   * Creates the least-privilege policies from the design's access matrix.
--   * Adds ow.set_context(...) for session attribute bootstrap.
--
-- What this file deliberately does NOT do:
--   * It does NOT redefine any existing function (append_message,
--     process_telegram_updates, upsert_agent, set_config, configure_telegram,
--     ...). SECURITY DEFINER conversion is Phase 3, owned separately, to avoid
--     the inline-duplication drift hazard of the prior attempt.
--   * It does NOT FORCE RLS, so the table owner / superuser still bypasses it.
--
-- Why this is non-breaking today: the only connector is `postgres` (superuser,
-- BYPASSRLS). Enabling RLS therefore has no effect on the live harness, on
-- agent-init, or on the pg_durable workflows. The policies only become binding
-- once a connection actually SET ROLEs into one of these roles — see Phase 2.
--
-- Idempotent: guarded role creation, DROP POLICY IF EXISTS before CREATE,
-- repeatable ENABLE ROW LEVEL SECURITY. Safe to re-run.
-- ============================================================================

-- ============================================================================
-- ROLES
-- ============================================================================

DO $$
BEGIN
  -- One role per agent
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_agent_primary') THEN
    CREATE ROLE ow_agent_primary NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_agent_sidecar') THEN
    CREATE ROLE ow_agent_sidecar NOLOGIN;
  END IF;

  -- Step down to user tiers when calling tools
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_authenticated') THEN
    CREATE ROLE ow_authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_anonymous') THEN
    CREATE ROLE ow_anonymous NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_service') THEN
    CREATE ROLE ow_service NOLOGIN;
  END IF;
END $$;

-- Agent roles run their own loops now: the pg_durable worker connects as the
-- submitted role (the agent role), so they must be LOGIN (non-superuser, so
-- enable_superuser_instances=off is satisfied).
ALTER ROLE ow_agent_primary LOGIN;
ALTER ROLE ow_agent_sidecar LOGIN;
ALTER ROLE ow_service BYPASSRLS;

-- ============================================================================
-- SCHEMA USAGE
-- ============================================================================

GRANT USAGE ON SCHEMA ow, ow_tools
  TO ow_authenticated, ow_anonymous, ow_service,
     ow_agent_primary, ow_agent_sidecar;

-- ============================================================================
-- SEQUENCES
--   bigserial PKs back onto a <table>_<col>_seq; INSERT needs USAGE on the
--   sequence (nextval) as well as INSERT on the table. Grant per inserting
--   role only — a role with no INSERT on a table gets no USAGE on its seq.
-- ============================================================================

-- Agent roles append to users, messages, and memory as they run
GRANT USAGE ON SEQUENCE ow.messages_id_seq, ow.memory_id_seq, ow.users_id_seq
  TO ow_agent_primary, ow_agent_sidecar;
-- Service role can add new models, agents, memory, or users through SQL tool 
GRANT USAGE ON SEQUENCE ow.agents_id_seq, ow.models_id_seq, ow.memory_id_seq, ow.users_id_seq
  TO ow_service;

-- ============================================================================
-- TABLE: ow.agents   (everyone reads; only service writes)
-- ============================================================================

GRANT SELECT ON ow.agents
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;
GRANT INSERT, UPDATE, DELETE ON ow.agents TO ow_service;

ALTER TABLE ow.agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS agents_read_all ON ow.agents;
CREATE POLICY agents_read_all ON ow.agents
  FOR SELECT TO PUBLIC USING (true);

-- ============================================================================
-- TABLE: ow.models   (everyone reads; only service writes)
-- ============================================================================

GRANT SELECT ON ow.models
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;
GRANT INSERT, UPDATE, DELETE ON ow.models TO ow_service;

ALTER TABLE ow.models ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS models_read_all ON ow.models;
CREATE POLICY models_read_all ON ow.models
  FOR SELECT TO PUBLIC USING (true);

-- ============================================================================
-- TABLE: ow.messages
--   Anonymous/authenticated: SELECT the whole configured chat (all messages for
--   the agent whose chat they are in), INSERT/UPDATE only their own rows, NEVER
--   delete. Agent roles scope to current_agent_id.
-- ============================================================================

GRANT SELECT ON ow.messages
  TO ow_anonymous, ow_authenticated;
GRANT SELECT, INSERT, UPDATE ON ow.messages
  TO ow_agent_primary, ow_agent_sidecar;
GRANT SELECT, INSERT, UPDATE, DELETE ON ow.messages
  TO ow_service;

ALTER TABLE ow.messages ENABLE ROW LEVEL SECURITY;

-- anonymous / authenticated: SELECT is chat-wide.
DROP POLICY IF EXISTS messages_user_select ON ow.messages;
CREATE POLICY messages_user_select ON ow.messages
  FOR SELECT TO ow_anonymous, ow_authenticated
  USING (
    agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint
    AND chat_id = NULLIF(current_setting('ow.current_chat_id', true), '')::text
  );

-- agent roles: their own agent_id; insert+update only, no delete
-- TODO: may be allow agents to forward messages to other channels in the future.
DROP POLICY IF EXISTS messages_agent_all_own ON ow.messages;
CREATE POLICY messages_agent_all_own ON ow.messages
  FOR ALL TO ow_agent_primary, ow_agent_sidecar
  USING (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint);

-- ============================================================================
-- TABLE: ow.memory
--   primary owns its memory; sidecar reviews and corrects memory across
--   ALL agents (read + insert + update); service full.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON ow.memory
  TO ow_agent_primary, ow_agent_sidecar, ow_service;

ALTER TABLE ow.memory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memory_primary_all_own ON ow.memory;
CREATE POLICY memory_primary_all_own ON ow.memory
  FOR ALL TO ow_agent_primary
  USING (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint);

-- sidecar reads / writes every agent's memory (to review)...
DROP POLICY IF EXISTS memory_sidecar_bypass ON ow.memory;
CREATE POLICY memory_sidecar_bypass ON ow.memory
  FOR ALL TO ow_agent_sidecar USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: ow.memory_sources
--   Junction backing memory's source messages (the composite FKs enforce
--   same-agent integrity and cascade). Ownership mirrors ow.memory: primary
--   owns its own, sidecar reads and corrects source links across ALL agents,
--   service full.
-- ============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON ow.memory_sources
  TO ow_agent_primary, ow_agent_sidecar, ow_service;

ALTER TABLE ow.memory_sources ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memory_sources_primary_all_own ON ow.memory_sources;
CREATE POLICY memory_sources_primary_all_own ON ow.memory_sources
  FOR ALL TO ow_agent_primary
  USING (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint);

-- sidecar reads / writes every agent's source links...
DROP POLICY IF EXISTS memory_sources_sidecar_bypass ON ow.memory_sources;
CREATE POLICY memory_sources_sidecar_bypass ON ow.memory_sources
  FOR ALL TO ow_agent_sidecar USING (true) WITH CHECK (true);

-- ============================================================================
-- TABLE: ow.config
--   Agent roles SELECT their own config INCLUDING secrets: the loop body runs as
--   the agent role and needs api_key / telegram_token to call the model and send.
--   This is safe because the LLM never executes as an agent role — only fixed
--   loop code does. LLM-authored SQL runs as the user tier (primary) or as
--   ow_service (sidecar). Neither can read secrets:
--     * the user tiers are granted SELECT on non-secret own rows only (policy
--       below); and
--     * ow_service — the sidecar's broad LLM-SQL tool scope — gets
--       SELECT on the non-secret config_public view ONLY and NO grant on the
--       base config table, so secret rows are unreachable even though service is
--       BYPASSRLS (no grant -> no rows, bypass or not).
--   Agent roles also write their own config rows (INSERT/UPDATE, no DELETE,
--   scoped to current_agent_id) — e.g. poll_messages bumps telegram_update_offset
--   as the agent role. Admin/superuser still owns bootstrap writes
--   (configure_telegram / set_config) at init.
-- ============================================================================

GRANT SELECT ON ow.config
  TO ow_anonymous, ow_authenticated;
GRANT SELECT, INSERT, UPDATE ON ow.config
  TO ow_agent_primary, ow_agent_sidecar;
-- ow_service (the sidecar's LLM-SQL tool scope) must stay secret-free.
-- It is BYPASSRLS, so a row-level policy cannot hide secret rows from it; instead
-- it gets SELECT on the non-secret config_public view ONLY and no grant on the
-- base table, so secrets are unreachable. No fixed loop code reads config as
-- service (only the SQL tool does).
CREATE OR REPLACE VIEW ow.config_public AS
  SELECT agent_id, key, value, updated_at FROM ow.config WHERE NOT secret;
GRANT SELECT ON ow.config_public TO ow_service;

ALTER TABLE ow.config ENABLE ROW LEVEL SECURITY;

-- agent roles: write their own config rows. No DELETE is granted, so the FOR ALL
-- policy still can't delete (mirrors messages_agent_all_own). Requires
-- current_agent_id, which poll_messages binds (23-OpenWorld-telegram.sql:128).
DROP POLICY IF EXISTS config_agent_write_own ON ow.config;
CREATE POLICY config_agent_write_own ON ow.config
  FOR ALL TO ow_agent_primary, ow_agent_sidecar
  USING (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint)
  WITH CHECK (agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint);

-- user roles: read non-secret config rows only (e.g. model_id, not api_key)
DROP POLICY IF EXISTS config_user_read_nonsecret ON ow.config;
CREATE POLICY config_user_read_nonsecret ON ow.config
  FOR SELECT TO ow_anonymous, ow_authenticated
  USING (
    agent_id = NULLIF(current_setting('ow.current_agent_id', true), '')::bigint
    AND secret = false
  );

-- ============================================================================
-- TABLE: ow.users   (channel identity ledger; intake upserts telegram users)
--   A user reads only their own row; agent/service read all (to resolve the
--   requesting user during a turn); service inserts (upsert_user); the primary
--   agent role may also create and edit users (insert/update, no delete — e.g.
--   to promote tier); admin manages the ledger incl. promoting tier
--   anonymous -> authenticated.
-- ============================================================================

GRANT SELECT ON ow.users
  TO ow_anonymous, ow_authenticated, ow_agent_sidecar;
GRANT SELECT, INSERT, UPDATE ON ow.users
  TO ow_agent_primary;
GRANT SELECT, INSERT, UPDATE, DELETE ON ow.users
  TO ow_service;

ALTER TABLE ow.users ENABLE ROW LEVEL SECURITY;

-- user sees only their own row (resolved by the internal id in their session)
DROP POLICY IF EXISTS users_user_select_own ON ow.users;
CREATE POLICY users_user_select_own ON ow.users
  FOR SELECT TO ow_anonymous, ow_authenticated
  USING (id = NULLIF(current_setting('ow.current_user_id', true), '')::bigint);

-- agent reads all users (resolve the requesting user during a turn)
DROP POLICY IF EXISTS users_agent_read_all ON ow.users;
CREATE POLICY users_agent_read_all ON ow.users
  FOR SELECT TO ow_agent_primary, ow_agent_sidecar
  USING (true);

-- ow_agent_primary creates and edits users (no DELETE). The ledger has no
-- agent_id, so management is global; it can promote tier, but not delete rows.
DROP POLICY IF EXISTS users_primary_insert ON ow.users;
CREATE POLICY users_primary_insert ON ow.users
  FOR INSERT TO ow_agent_primary WITH CHECK (true);

DROP POLICY IF EXISTS users_primary_update ON ow.users;
CREATE POLICY users_primary_update ON ow.users
  FOR UPDATE TO ow_agent_primary USING (true) WITH CHECK (true);

-- ============================================================================
-- FUNCTION EXECUTE PRIVILEGES
--   Per-function for the verified ow entrypoints (least privilege, and
--   to document the intent). Schema-wide for ow_tools (the agent tooling
--   surface) and for the trusted service role.
-- ============================================================================

-- Agent roles now run their own loops, so they also need the full ow
-- function surface (compose_llm_request, record_assistant, poll_messages,
-- upsert_user, helpers, ...).
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ow
  TO ow_agent_primary, ow_agent_sidecar;

-- Acting roles (user tiers + per-agent roles) run tool functions inside
-- per-call tool instances. EXECUTE is broad but contained: row-level security
-- on the underlying tables bounds what they can actually read or write.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ow_tools
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;

-- pg_ffmpeg (schema 'ffmpeg') is used by SEND_ATTACHMENT's _attachment_kind to
-- detect image/audio/video via ffmpeg.media_info, which runs SET ROLE'd to the
-- acting role inside run_tool_call_as_role. Grant USAGE + EXECUTE broadly (the
-- agent may also call ffmpeg functions directly via the SQL tool).
GRANT USAGE ON SCHEMA ffmpeg
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ffmpeg
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;
GRANT SELECT ON ALL TABLES IN SCHEMA ffmpeg
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;

-- Acting roles CREATE HLS playlists via ffmpeg.hls(url, segment_duration) in
-- the SQL tool — that returned playlist_id is what send_photo/send_video/
-- send_audio key off. ffmpeg.hls is SECURITY INVOKER and INSERTs into
-- ffmpeg.hls_playlists / ffmpeg.hls_segments (and nextval's their id
-- sequences), so those roles need INSERT on the two tables and USAGE on the
-- sequences. The tables are scratch media storage (no RLS, no sensitive
-- data); GRANT ... ON ALL TABLES above only granted SELECT, so this is
-- scoped to just the hls pair.
GRANT INSERT ON ffmpeg.hls_playlists, ffmpeg.hls_segments
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;
GRANT USAGE, SELECT ON SEQUENCE ffmpeg.hls_playlists_id_seq, ffmpeg.hls_segments_id_seq
  TO ow_anonymous, ow_authenticated, ow_service,
     ow_agent_primary, ow_agent_sidecar;

-- Each agent may own a camera workflow. hls_live claims/releases its playlist
-- and updates a heartbeat; its retention branch deletes old segments. The ow
-- helpers bind each operation to the calling agent's own configured stream.
GRANT EXECUTE ON PROCEDURE ffmpeg.hls_live(text, integer, double precision)
  TO ow_agent_primary, ow_agent_sidecar;
GRANT UPDATE ON ffmpeg.hls_playlists
  TO ow_agent_primary, ow_agent_sidecar;
GRANT DELETE ON ffmpeg.hls_segments
  TO ow_agent_primary, ow_agent_sidecar;

-- TODO: move this function to ow_tools or telegram schema
GRANT EXECUTE ON FUNCTION ow.queue_outbound_attachment(text, text, text, text, text, text, text)
  TO ow_anonymous, ow_authenticated;

-- ============================================================================
-- DURABLE FRAMEWORK ACCESS (pg_durable)
--   pg_durable.enable_superuser_instances is OFF (default), so durable instances
--   may NOT be owned by a superuser. The entry-point starters (inbox/cron loops)
--   are SECURITY DEFINER owned by the agent roles; the trigger/send functions
--   are SECURITY INVOKER but fire/run as the agent role in every live path — so
--   either way every df.start submits as the acting agent role (a non-superuser).
--   The agent roles run df.http
--   (LLM call, Telegram poll/send) and manage per-call tool instances, so they
--   get include_http. ow_service no longer submits workflows, so it gets no
--   df access.
--   (ow_anonymous / ow_authenticated are intentionally NOT granted df
--    access: end users interact through the agent, not by submitting durable
--    workflows themselves.)
-- ============================================================================
SELECT df.grant_usage('ow_service',       include_http => true);
SELECT df.grant_usage('ow_agent_primary', include_http => true);
SELECT df.grant_usage('ow_agent_sidecar', include_http => true);

-- The durable worker connects as the submitted role (now an agent role, made
-- LOGIN above) to execute instance SQL. Per-call tool instances are submitted
-- by the agent role, and run_tool_call_as_role SET ROLEs down to the acting
-- tool scope inside them, so RESET ROLE restores to the agent role (no
-- escalation). Each agent role must be a member of its tool-scope role:
--   primary      -> the requesting user's tier (anonymous / authenticated)
--   sidecar -> ow_service (broad, secret-free)
GRANT ow_anonymous TO ow_agent_primary;
GRANT ow_authenticated TO ow_agent_primary;
GRANT ow_service TO ow_agent_sidecar;

-- SECURITY DEFINER entry-point starters, owned by the agent whose context they
-- submit as (df.start submits as the owner): the telegram inbox loop (primary),
-- the cron loop (sidecar), and queue_outbound_attachment
-- (primary — it is called from the anonymous/authenticated acting role and
-- needs the INSERT that only the primary owner grants).
-- SECURITY INVOKER (they inherit the caller's identity; in every live path the
-- caller is the relevant agent role, so df.start submits as that agent):
-- start_agent_loop, ensure_camera_ingest_loop, stop_camera_ingest_loop,
-- after_user_message_loop, after_outbound_message_send, send_message, and
-- send_message_future. Ownership is inert for INVOKER functions, so these are
-- not re-owned here.
ALTER FUNCTION ow.ensure_telegram_inbox_loop(text, integer) OWNER TO ow_agent_primary;
ALTER FUNCTION ow.ensure_agent_cron_loop(text, text, text, text) OWNER TO ow_agent_sidecar;
ALTER FUNCTION ow.queue_outbound_attachment(text, text, text, text, text, text, text) OWNER TO ow_agent_primary;

-- ============================================================================
-- CONTEXT HELPER  (sets the ABAC session attributes; see design §10.2)
--   Uses the 3-argument built-in set_config(name, value, is_local).
--   Role switching is performed by the connection layer / intake loop after
--   calling this (SET LOCAL ROLE), not baked in here.
-- ============================================================================

CREATE OR REPLACE FUNCTION ow.set_context(
  p_role text,
  p_agent_id bigint DEFAULT NULL,
  p_telegram_user_id text DEFAULT NULL,
  p_telegram_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL,
  p_channel text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, pg_temp
AS $$
BEGIN
  PERFORM set_config('ow.current_role', p_role, true);
  PERFORM set_config('ow.current_agent_id', COALESCE(p_agent_id::text, ''), true);
  PERFORM set_config('ow.current_chat_id', COALESCE(p_telegram_chat_id, ''), true);
  PERFORM set_config('ow.current_user_id', COALESCE(p_user_id::text, ''), true);
  PERFORM set_config('ow.current_channel', COALESCE(p_channel, ''), true);
END;
$$;
