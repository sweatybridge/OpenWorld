-- ============================================================================
-- Read-only dashboard role for the OpenWorld admin dashboard.
--
-- pg_durable hides other users' instances behind RLS (a normal role only sees
-- instances it submitted). The dashboard needs to see *all* workflows and *all*
-- agents' data, so the role is BYPASSRLS — the same pattern already used for
-- OpenWorld_service in 40-OpenWorld-rbac.sql. Crucially it gets ONLY SELECT/EXECUTE:
-- no INSERT/UPDATE/DELETE/USAGE-on-sequences, so it is read-only at the database
-- even if the API layer had a bug.
-- 
-- Idempotent and safe to re-run.
-- ============================================================================

-- 1. Create the login role (BYPASSRLS so it sees every df instance + OpenWorld row).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'OpenWorld_dashboard') THEN
    CREATE ROLE OpenWorld_dashboard LOGIN BYPASSRLS;
  END IF;
END $$;

-- 2. df privileges: USAGE on the df schema, EXECUTE on the read/monitoring
--    functions (list_instances, instance_info, instance_nodes, instance_executions,
--    metrics, status, result, explain), and SELECT on df.instances + df.nodes.
--    BYPASSRLS makes all rows visible despite per-user RLS.
SELECT df.grant_usage('OpenWorld_dashboard');
GRANT EXECUTE ON FUNCTION df.metrics() TO OpenWorld_dashboard;

-- 3. Read access to the OpenWorld domain. RLS is ENABLED but not FORCE on these
--    tables, and BYPASSRLS bypasses it anyway — but the SELECT privilege is still
--    required. No write/sequence privileges are granted. EXECUTE on the helpers is
--    needed because the view/trace_turn run as INVOKER (the dashboard role).
GRANT USAGE ON SCHEMA OpenWorld, OpenWorld_tools TO OpenWorld_dashboard;
GRANT SELECT
  ON OpenWorld.agents, OpenWorld.models, OpenWorld.config, OpenWorld.messages,
     OpenWorld.memory, OpenWorld.memory_sources, OpenWorld.users,
     OpenWorld.instance_index
  TO OpenWorld_dashboard;
GRANT EXECUTE ON FUNCTION
  OpenWorld.trace_turn(bigint),
  OpenWorld.turn_trigger_id(bigint),
  OpenWorld.parse_instance_label(text),
  OpenWorld._instance_result(text)
  TO OpenWorld_dashboard;

-- 4. Worker-liveness table (internal; may or may not be covered by grant_usage).
--    Tolerate absence so a future schema change can't break the seed job.
DO $$
BEGIN
  GRANT SELECT ON df._worker_epoch TO OpenWorld_dashboard;
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
GRANT USAGE ON SCHEMA ffmpeg TO OpenWorld_dashboard;
GRANT SELECT ON ffmpeg.hls_playlists, ffmpeg.hls_segments TO OpenWorld_dashboard;
GRANT EXECUTE ON FUNCTION ffmpeg.thumbnail(bytea, double precision, text) TO OpenWorld_dashboard;
