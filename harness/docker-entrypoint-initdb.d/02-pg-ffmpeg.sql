-- pg_ffmpeg exposes FFmpeg media processing as SQL functions in the 'ffmpeg'
-- schema (bytea-in / bytea-out). No shared_preload_libraries, no background
-- worker. The .so, control, and install SQL are installed from the Debian
-- package in the Dockerfile; CREATE EXTENSION creates the schema and the
-- functions. SEND_ATTACHMENT uses ffmpeg.media_info(bytea)->jsonb to detect
-- image/audio/video so it can route to sendPhoto/sendAudio/sendVideo.
CREATE EXTENSION IF NOT EXISTS pg_ffmpeg;
