-- ============================================================================
-- Read-only dashboard role for the ow admin dashboard.
--
-- pg_durable hides other users' instances behind RLS (a normal role only sees
-- instances it submitted). The dashboard needs to see *all* workflows and *all*
-- agents' data, so the role is BYPASSRLS — the same pattern already used for
-- ow_service in 40-ow-rbac.sql. Crucially it gets ONLY SELECT/EXECUTE:
-- no INSERT/UPDATE/DELETE/USAGE-on-sequences, so it is read-only at the database
-- even if the API layer had a bug.
-- 
-- Idempotent and safe to re-run.
-- ============================================================================

-- 1. Create the login role (BYPASSRLS so it sees every df instance + ow row).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ow_dashboard') THEN
    CREATE ROLE ow_dashboard LOGIN BYPASSRLS;
  END IF;
END $$;

-- 2. df privileges: USAGE on the df schema, EXECUTE on the read/monitoring
--    functions (list_instances, instance_info, instance_nodes, instance_executions,
--    metrics, status, result, explain), and SELECT on df.instances + df.nodes.
--    BYPASSRLS makes all rows visible despite per-user RLS.
SELECT df.grant_usage('ow_dashboard');
GRANT EXECUTE ON FUNCTION df.metrics() TO ow_dashboard;

-- 3. Read access to the ow domain. RLS is ENABLED but not FORCE on these
--    tables, and BYPASSRLS bypasses it anyway — but the SELECT privilege is still
--    required. No write/sequence privileges are granted. EXECUTE on the helpers is
--    needed because the view/trace_turn run as INVOKER (the dashboard role).
GRANT USAGE ON SCHEMA ow, ow_tools TO ow_dashboard;
GRANT SELECT
  ON ow.agents, ow.models, ow.config, ow.messages,
     ow.memory, ow.memory_sources, ow.users,
     ow.instance_index
  TO ow_dashboard;
GRANT EXECUTE ON FUNCTION
  ow.trace_turn(bigint),
  ow.turn_trigger_id(bigint),
  ow.parse_instance_label(text),
  ow._instance_result(text)
  TO ow_dashboard;

-- 4. Worker-liveness table (internal; may or may not be covered by grant_usage).
--    Tolerate absence so a future schema change can't break the seed job.
DO $$
BEGIN
  GRANT SELECT ON df._worker_epoch TO ow_dashboard;
EXCEPTION
  WHEN undefined_table THEN NULL;
END $$;

-- 5. Media page: read ffmpeg.hls_playlists / hls_segments and compute thumbnails.
--    pg_ffmpeg (CREATE EXTENSION in 02-pg-ffmpeg.sql) owns the schema and both
--    tables. The dashboard lists playlists (aggregated against hls_segments) and
--    renders a per-row thumbnail via ffmpeg.thumbnail on the FIRST segment only
--    (HLS segments keyframe at the start, so segment 0 decodes standalone — no
--    need to concat the whole playlist). Read-only: SELECT on the two tables +
--    EXECUTE on the single transform used; no concat, no INSERT, no sequences.
GRANT USAGE ON SCHEMA ffmpeg TO ow_dashboard;
GRANT SELECT ON ffmpeg.hls_playlists, ffmpeg.hls_segments TO ow_dashboard;
GRANT EXECUTE ON FUNCTION ffmpeg.thumbnail(bytea, double precision, text) TO ow_dashboard;
