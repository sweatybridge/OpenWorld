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
SELECT ok(to_regprocedure('ow._camera_role_owns_url(text,text)') IS NOT NULL,
  'ow._camera_role_owns_url(text,text) exists');
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
SELECT is(
  (SELECT p.pronargdefaults
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'ow' AND p.proname = 'ensure_camera_ingest_loop'),
  3::smallint,
  'camera ingest requires both agent_slug and URL'
);
SELECT ok(
  (SELECT p.prosecdef
     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'ow' AND p.proname = '_camera_role_owns_url'),
  'camera RLS ownership predicate bypasses config RLS without exposing the URL'
);
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
     WHERE schemaname = 'ow'
       AND tablename = 'config'
       AND indexname = 'config_camera_feed_url_unique'
  ),
  'one camera source URL can be claimed by only one agent'
);
SELECT ok(
  (SELECT c.relrowsecurity
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'ffmpeg' AND c.relname = 'hls_playlists'),
  'live playlists enforce RLS'
);
SELECT ok(
  (SELECT c.relrowsecurity
     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'ffmpeg' AND c.relname = 'hls_segments'),
  'live segments enforce RLS'
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

INSERT INTO ow.config(agent_id, key, value, secret)
SELECT a.id, 'camera_feed_url', to_jsonb('rtsp://camera/' || a.slug), true
  FROM ow.agents a
 WHERE a.slug IN ('primary', 'sidecar');

SET LOCAL ROLE ow_agent_sidecar;
SELECT set_config('ow.current_agent_id', ow.agent_id('sidecar')::text, true);
SELECT throws_ok(
  $$UPDATE ow.config
       SET value = to_jsonb('rtsp://camera/primary'::text)
     WHERE key = 'camera_feed_url'$$,
  '23505',
  'duplicate key value violates unique constraint "config_camera_feed_url_unique"',
  'an agent cannot claim another agent''s camera source URL'
);
RESET ROLE;

INSERT INTO ffmpeg.hls_playlists(source_url, target_duration)
VALUES ('rtsp://camera/primary', 2), ('rtsp://camera/sidecar', 2);
INSERT INTO ffmpeg.hls_segments(playlist_id, segment_index, duration, data)
SELECT p.id, 0, 2.0, decode('00', 'hex')
  FROM ffmpeg.hls_playlists p
 WHERE p.source_url IN ('rtsp://camera/primary', 'rtsp://camera/sidecar');

SET LOCAL ROLE ow_agent_primary;

INSERT INTO ffmpeg.hls_segments(playlist_id, segment_index, duration, data)
SELECT p.id, 2, 2.0, decode('02', 'hex')
  FROM ffmpeg.hls_playlists p
 WHERE p.source_url = 'rtsp://camera/primary';
SELECT throws_ok(
  $$INSERT INTO ffmpeg.hls_segments(playlist_id, segment_index, duration, data)
    SELECT p.id, 99, 2.0, decode('63', 'hex')
      FROM ffmpeg.hls_playlists p
     WHERE p.source_url = 'rtsp://camera/sidecar'$$,
  '42501',
  'new row violates row-level security policy for table "hls_segments"',
  'primary cannot inject segments into the sidecar live playlist'
);
UPDATE ffmpeg.hls_playlists SET stop_requested = true;
DELETE FROM ffmpeg.hls_segments;

RESET ROLE;

SELECT ok(
  (SELECT stop_requested FROM ffmpeg.hls_playlists
    WHERE source_url = 'rtsp://camera/primary'),
  'primary can update its own live playlist through RLS'
);
SELECT ok(
  NOT (SELECT stop_requested FROM ffmpeg.hls_playlists
        WHERE source_url = 'rtsp://camera/sidecar'),
  'primary cannot update the sidecar live playlist'
);
SELECT is(
  (SELECT count(*) FROM ffmpeg.hls_segments s
    JOIN ffmpeg.hls_playlists p ON p.id = s.playlist_id
   WHERE p.source_url = 'rtsp://camera/primary'),
  0::bigint,
  'primary can delete retained segments from its own stream'
);
SELECT is(
  (SELECT count(*) FROM ffmpeg.hls_segments s
    JOIN ffmpeg.hls_playlists p ON p.id = s.playlist_id
   WHERE p.source_url = 'rtsp://camera/sidecar'),
  1::bigint,
  'primary cannot delete retained segments from the sidecar stream'
);

UPDATE ffmpeg.hls_playlists
   SET stop_requested = false
 WHERE source_url = 'rtsp://camera/primary';
INSERT INTO ffmpeg.hls_segments(playlist_id, segment_index, duration, data)
SELECT p.id, 1, 2.0, decode('01', 'hex')
  FROM ffmpeg.hls_playlists p
 WHERE p.source_url = 'rtsp://camera/primary';

SET LOCAL ROLE ow_agent_sidecar;

UPDATE ffmpeg.hls_playlists SET owner_pid = 42;
DELETE FROM ffmpeg.hls_segments;

RESET ROLE;

SELECT is(
  (SELECT owner_pid FROM ffmpeg.hls_playlists
    WHERE source_url = 'rtsp://camera/sidecar'),
  42,
  'sidecar can update its own live playlist through RLS'
);
SELECT is(
  (SELECT owner_pid FROM ffmpeg.hls_playlists
    WHERE source_url = 'rtsp://camera/primary'),
  NULL,
  'sidecar cannot update the primary live playlist'
);
SELECT is(
  (SELECT count(*) FROM ffmpeg.hls_segments s
    JOIN ffmpeg.hls_playlists p ON p.id = s.playlist_id
   WHERE p.source_url = 'rtsp://camera/sidecar'),
  0::bigint,
  'sidecar can delete retained segments from its own stream'
);
SELECT is(
  (SELECT count(*) FROM ffmpeg.hls_segments s
    JOIN ffmpeg.hls_playlists p ON p.id = s.playlist_id
   WHERE p.source_url = 'rtsp://camera/primary'),
  1::bigint,
  'sidecar cannot delete retained segments from the primary stream'
);

SET LOCAL ROLE ow_agent_primary;

SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 0, 10, 300)$$,
  'P0001',
  'camera segment_duration must be greater than 0',
  'camera loop rejects non-positive segment duration before starting work'
);
SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', NULL, 10, 300)$$,
  'P0001',
  'camera segment_duration must be greater than 0',
  'camera loop rejects a NULL segment duration before starting work'
);
SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 2, 0, 300)$$,
  'P0001',
  'camera stall_timeout must be finite and greater than 0',
  'camera loop rejects non-positive stall timeout before starting work'
);
SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 2, NULL, 300)$$,
  'P0001',
  'camera stall_timeout must be finite and greater than 0',
  'camera loop rejects a NULL stall timeout before starting work'
);
SELECT throws_ok(
  $$SELECT ow.ensure_camera_ingest_loop('primary', 'rtsp://camera/live', 2, 10, NULL)$$,
  'P0001',
  'camera retention_segments must be greater than 0',
  'camera loop rejects a NULL retention bound before starting work'
);
SELECT throws_ok(
  $$SELECT ow.prune_camera_feed('primary', 0)$$,
  'P0001',
  'camera retention_segments must be greater than 0',
  'camera pruning rejects a non-positive retention bound'
);
SELECT throws_ok(
  $$SELECT ow.prune_camera_feed('primary', NULL)$$,
  'P0001',
  'camera retention_segments must be greater than 0',
  'camera pruning rejects a NULL retention bound'
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

-- A durable camera workflow may be active before hls_live has created its
-- playlist row. Stopping by playlist flag alone cannot disable that workflow;
-- the helper must cancel the durable instance identified by its camera label.
DELETE FROM ffmpeg.hls_segments
 WHERE playlist_id = (
   SELECT id FROM ffmpeg.hls_playlists
    WHERE source_url = 'rtsp://camera/primary'
 );
DELETE FROM ffmpeg.hls_playlists
 WHERE source_url = 'rtsp://camera/primary';

SET LOCAL ROLE ow_agent_primary;
SELECT df.start(
  df.sleep(600),
  'ow:primary:camera',
  transaction_mode => 'new'
) AS pending_camera_instance_id \gset

SELECT ok(
  ow.stop_camera_ingest_loop('primary'),
  'camera stop reports success when it cancels an instance without a playlist'
);
SELECT is(
  df.status(:'pending_camera_instance_id'),
  'cancelled',
  'camera stop cancels the pending or retrying durable instance'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
