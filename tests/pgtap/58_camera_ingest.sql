-- Optional camera ingest: pg_ffmpeg 0.4 hls_live surface, workflow helpers,
-- per-agent caller isolation, validation, and live-media mutation grants.
\set ON_ERROR_STOP on
BEGIN;
SELECT no_plan();

SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'pg_ffmpeg'),
  '0.4.0',
  'pg_ffmpeg 0.4.0 is installed'
);
SELECT has_column('ffmpeg', 'hls_playlists', 'source_url',
  'live playlists have a stable source_url key');
SELECT has_column('ffmpeg', 'hls_playlists', 'stop_requested',
  'live playlists expose a stop flag');
SELECT has_column('ffmpeg', 'hls_playlists', 'owner_pid',
  'live playlists track their owning backend');
SELECT has_column('ffmpeg', 'hls_playlists', 'updated_at',
  'live playlists expose a heartbeat timestamp');

SELECT ok(
  EXISTS (
    SELECT 1
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'ffmpeg'
       AND p.proname = 'hls_live'
       AND p.prokind = 'p'
       AND p.pronargs = 3
  ),
  'pg_ffmpeg exposes hls_live as a three-argument procedure'
);

SELECT ok(to_regprocedure('ow._camera_feed_url(text)') IS NOT NULL,
  'ow._camera_feed_url(text) exists');
SELECT ok(to_regprocedure('ow._camera_agent_id(text)') IS NOT NULL,
  'ow._camera_agent_id(text) exists');
SELECT ok(to_regprocedure('ow.prune_camera_feed(text,integer)') IS NOT NULL,
  'ow.prune_camera_feed(text,integer) exists');
SELECT ok(to_regprocedure('ow.ensure_camera_ingest_loop(text,text,integer,double precision,integer)') IS NOT NULL,
  'ow.ensure_camera_ingest_loop(...) exists');
SELECT ok(to_regprocedure('ow.stop_camera_ingest_loop(text)') IS NOT NULL,
  'ow.stop_camera_ingest_loop(text) exists');

SELECT ok(
  NOT (SELECT p.prosecdef
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'ow' AND p.proname = 'ensure_camera_ingest_loop'),
  'camera ingest starter is SECURITY INVOKER'
);

SELECT ok(has_table_privilege('ow_agent_primary', 'ffmpeg.hls_playlists', 'UPDATE'),
  'primary can claim and heartbeat a live playlist');
SELECT ok(has_table_privilege('ow_agent_primary', 'ffmpeg.hls_segments', 'DELETE'),
  'primary can prune retained live segments');
SELECT ok(has_table_privilege('ow_agent_sidecar', 'ffmpeg.hls_playlists', 'UPDATE'),
  'sidecar can claim and heartbeat its live playlist');
SELECT ok(has_table_privilege('ow_agent_sidecar', 'ffmpeg.hls_segments', 'DELETE'),
  'sidecar can prune its retained live segments');
SELECT ok(NOT has_table_privilege('ow_anonymous', 'ffmpeg.hls_playlists', 'UPDATE'),
  'anonymous cannot mutate live playlist state');
SELECT ok(NOT has_table_privilege('ow_anonymous', 'ffmpeg.hls_segments', 'DELETE'),
  'anonymous cannot prune camera segments');
SELECT ok(has_function_privilege(
    'ow_agent_primary', 'ffmpeg.hls_live(text,integer,double precision)', 'EXECUTE'),
  'primary can execute the hls_live procedure');
SELECT ok(has_function_privilege(
    'ow_agent_sidecar', 'ffmpeg.hls_live(text,integer,double precision)', 'EXECUTE'),
  'sidecar can execute the hls_live procedure');

SET LOCAL ROLE ow_agent_primary;

SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 0, 10, 300)$$,
  'P0001',
  'camera segment_duration must be greater than 0',
  'camera loop rejects non-positive segment duration before starting work'
);
SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 2, 0, 300)$$,
  'P0001',
  'camera stall_timeout must be finite and greater than 0',
  'camera loop rejects non-positive stall timeout before starting work'
);
SELECT throws_ok(
  $$SELECT ow.prune_camera_feed('primary', 0)$$,
  'P0001',
  'camera retention_segments must be greater than 0',
  'camera pruning rejects a non-positive retention bound'
);

RESET ROLE;
SET LOCAL ROLE ow_agent_sidecar;

SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('sidecar', 'rtsp://camera/live', 0, 10, 300)$$,
  'P0001',
  'camera segment_duration must be greater than 0',
  'sidecar may manage a camera loop for its own slug'
);
SELECT throws_ok(
  $$SELECT ow.prune_camera_feed('primary', 300)$$,
  'P0001',
  'camera ingest for agent primary must run as role ow_agent_primary',
  'an agent cannot prune another agent''s configured stream'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
