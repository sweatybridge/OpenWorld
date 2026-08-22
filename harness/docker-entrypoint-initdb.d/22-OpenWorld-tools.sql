CREATE OR REPLACE FUNCTION ow_tools._append_tool_message(
  p_agent_id bigint,
  p_tool_call_id text,
  p_result text
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  -- Bind the agent GUC so the INSERT satisfies the agent-scoped WITH CHECK
  -- policy (run_tool_calls runs as the loop/agent role, not service-bypass).
  PERFORM set_config('ow.current_agent_id', p_agent_id::text, true);

  INSERT INTO ow.messages(agent_id, role, content, tool_call_id)
  VALUES (p_agent_id, 'tool', coalesce(p_result, ''), p_tool_call_id)
  ON CONFLICT (agent_id, tool_call_id)
    WHERE role = 'tool' AND tool_call_id IS NOT NULL
    DO NOTHING;
END;
$$;

-- Classify media bytes as 'photo' | 'audio' | 'video' | 'document' so
-- SEND_ATTACHMENT can route to the matching Telegram send method
-- (sendPhoto/sendAudio/sendVideo/sendDocument). Priority: explicit mime_type,
-- then filename extension, then ffmpeg.media_info introspection of the container
-- (falls back to 'document' when the bytes are unparseable). media_info yields
-- {format, duration, streams:[{type:'video'|'audio'|..., codec, ...}]}.
CREATE OR REPLACE FUNCTION ow_tools._attachment_kind(
  p_bytes bytea,
  p_mime_type text,
  p_filename text
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_mime text := lower(btrim(coalesce(p_mime_type, '')));
  v_ext text := lower(regexp_replace(coalesce(p_filename, ''), '^.*\.', ''));
  v_info jsonb;
  v_streams jsonb;
  v_has_video boolean;
  v_has_audio boolean;
  v_duration float8;
  v_video_codec text;
BEGIN
  -- 1. explicit mime_type wins
  IF v_mime LIKE 'image/%' THEN RETURN 'photo'; END IF;
  IF v_mime LIKE 'audio/%' THEN RETURN 'audio'; END IF;
  IF v_mime LIKE 'video/%' THEN RETURN 'video'; END IF;

  -- 2. filename extension
  IF v_ext IN ('jpg','jpeg','png','webp','gif','bmp','tif','tiff','heic') THEN RETURN 'photo'; END IF;
  IF v_ext IN ('mp3','m4a','aac','wav','ogg','oga','flac','opus','wma') THEN RETURN 'audio'; END IF;
  IF v_ext IN ('mp4','m4v','mov','avi','mkv','webm','3gp','mpeg','mpg','ts','mts') THEN RETURN 'video'; END IF;

  -- 3. ffmpeg introspection; tolerate unparseable/corrupt input.
  BEGIN
    v_info := ffmpeg.media_info(p_bytes);
  EXCEPTION WHEN others THEN
    RETURN 'document';
  END;

  v_streams := coalesce(v_info->'streams', '[]'::jsonb);
  v_duration := nullif(v_info->>'duration', '')::float8;
  v_has_video := EXISTS (SELECT 1 FROM jsonb_array_elements(v_streams) s WHERE s.value->>'type' = 'video');
  v_has_audio := EXISTS (SELECT 1 FROM jsonb_array_elements(v_streams) s WHERE s.value->>'type' = 'audio');

  IF v_has_video THEN
    SELECT s.value->>'codec' INTO v_video_codec
    FROM jsonb_array_elements(v_streams) s
    WHERE s.value->>'type' = 'video'
    LIMIT 1;

    -- A standalone image (PNG/JPEG/...) demuxes as a single video stream with an
    -- image codec, no audio, and no real duration. Anything else with a video
    -- stream is a video.
    IF v_video_codec IN ('png','mjpeg','jpeg','jpegls','webp','bmp','tiff','gif')
       AND NOT v_has_audio
       AND v_duration IS NULL THEN
      RETURN 'photo';
    END IF;
    RETURN 'video';
  END IF;

  IF v_has_audio THEN
    RETURN 'audio';
  END IF;

  RETURN 'document';
END;
$$;

-- SEND_ATTACHMENT: decode inline media bytes, auto-detect image/audio/video via
-- pg_ffmpeg, and queue an outbound system message (channel='telegram') that the
-- outbound trigger delivers. The media bytes ride in the message payload as
-- base64, so media produced by an ffmpeg function
-- (thumbnail/transcode/waveform/generate_gif/...) can be sent in one call.
-- queue_outbound_attachment (SECURITY DEFINER, owner ow_agent_primary) does
-- the privileged append so this works even when the caller is the anonymous
-- acting role.
CREATE OR REPLACE FUNCTION ow_tools._tool_send_attachment(
  p_content text,
  p_encoding text,
  p_filename text DEFAULT '',
  p_caption text DEFAULT '',
  p_mime_type text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('ow.current_agent_id', true), '')::bigint;
  v_bytes bytea;
  v_kind text;
  v_slug text;
  v_chat_id text;
BEGIN
  IF v_agent_id IS NULL THEN
    RAISE EXCEPTION 'SEND_ATTACHMENT has no current agent context';
  END IF;

  v_bytes := ow_tools._decode_content(p_content, p_encoding);
  v_kind := ow_tools._attachment_kind(v_bytes, p_mime_type, p_filename);

  SELECT slug, chat_id INTO v_slug, v_chat_id
  FROM ow.messages m JOIN ow.agents a ON a.id = m.agent_id
  WHERE m.agent_id = v_agent_id AND m.role = 'user'
  ORDER BY m.id DESC LIMIT 1;

  PERFORM ow.queue_outbound_attachment(
    v_slug,
    encode(v_bytes, 'base64'),
    v_kind,
    nullif(p_filename, ''),
    nullif(p_caption, ''),
    nullif(p_mime_type, ''),
    v_chat_id
  );

  RETURN jsonb_build_object('queued', true, 'kind', v_kind, 'bytes', length(v_bytes))::text;
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_send_attachment(text, text, text, text, text) IS 'Send media (image/audio/video) as a Telegram attachment. Pass the raw content with an encoding (base64, hex, escape, or a text encoding like UTF8). The kind is auto-detected from mime_type/filename, falling back to ffmpeg.media_info: photos use sendPhoto, audio sendAudio, video sendVideo, anything else sendDocument.';

-- Reconstruct one continuous media blob from the HLS segments stored for a
-- playlist (created by ffmpeg.hls(url, segment_duration), which returns the
-- playlist_id). ffmpeg.concat stream-copies the segments back together in
-- segment_index order; segments from a single hls() call share codec/
-- dimensions so they are concat-compatible. The send_photo/send_video/
-- send_audio tools key off this id so the media bytes are produced and
-- consumed server-side and never flow through the LLM's arguments or results.
CREATE OR REPLACE FUNCTION ow_tools._hls_media(p_playlist_id bigint)
RETURNS bytea
LANGUAGE plpgsql
SET search_path = ow, ow_tools, pg_temp
AS $$
DECLARE
  v_bytes bytea;
BEGIN
  IF p_playlist_id IS NULL THEN
    RAISE EXCEPTION 'playlist_id is required';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM ffmpeg.hls_segments WHERE playlist_id = p_playlist_id) THEN
    RAISE EXCEPTION 'no HLS segments found for playlist_id %', p_playlist_id
      USING HINT = 'create one with: SELECT ffmpeg.hls(url, segment_duration)';
  END IF;

  SELECT ffmpeg.concat(array_agg(data ORDER BY segment_index)) INTO v_bytes
  FROM ffmpeg.hls_segments WHERE playlist_id = p_playlist_id;

  IF v_bytes IS NULL THEN
    RAISE EXCEPTION 'could not reconstruct media for playlist_id %', p_playlist_id;
  END IF;

  RETURN v_bytes;
END;
$$;

-- Shared tail of the three send_* tools: resolve the acting agent's slug +
-- chat_id from its most recent user message, queue the (already-produced)
-- bytes as the FORCED kind (photo/video/audio — chosen by which tool was
-- called, not by detection), and return a small result. detected runs
-- _attachment_kind on the actual bytes for the result only — it does NOT
-- override the forced kind — so the model can see a mismatch (e.g. a
-- send_video of an audio-only transform) without the routing changing.
-- bytes never leave this call as text: queue_outbound_attachment base64-
-- encodes them into the message payload, and the returned JSON carries only
-- lengths and labels.
CREATE OR REPLACE FUNCTION ow_tools._queue_send(
  p_kind text,
  p_bytes bytea,
  p_transform text,
  p_filename text,
  p_caption text,
  p_mime_type text
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('ow.current_agent_id', true), '')::bigint;
  v_detected text;
  v_slug text;
  v_chat_id text;
BEGIN
  IF v_agent_id IS NULL THEN
    RAISE EXCEPTION 'send tool has no current agent context';
  END IF;
  IF p_bytes IS NULL OR length(p_bytes) = 0 THEN
    RAISE EXCEPTION 'send tool produced no media bytes';
  END IF;

  v_detected := ow_tools._attachment_kind(p_bytes, p_mime_type, p_filename);

  SELECT a.slug, m.chat_id INTO v_slug, v_chat_id
  FROM ow.messages m JOIN ow.agents a ON a.id = m.agent_id
  WHERE m.agent_id = v_agent_id AND m.role = 'user'
  ORDER BY m.id DESC LIMIT 1;

  PERFORM ow.queue_outbound_attachment(
    v_slug,
    encode(p_bytes, 'base64'),
    p_kind,
    nullif(p_filename, ''),
    nullif(p_caption, ''),
    nullif(p_mime_type, ''),
    v_chat_id
  );

  RETURN jsonb_build_object(
    'queued', true,
    'kind', p_kind,
    'detected', v_detected,
    'bytes', length(p_bytes),
    'transform', nullif(p_transform, '')
  )::text;
END;
$$;

-- Helper: read an optional numeric/text field from a (possibly NULL) jsonb
-- options bag. p_key absent or p_options NULL -> p_default; otherwise cast.
-- A malformed value raises, which run_tool_call_as_role turns into an
-- 'error: ...' tool result (the model sees it and can retry with valid opts).
CREATE OR REPLACE FUNCTION ow_tools._opt_int(p_options jsonb, p_key text, p_default integer)
RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_options ->> p_key, '')::integer, p_default)
$$;
CREATE OR REPLACE FUNCTION ow_tools._opt_float(p_options jsonb, p_key text, p_default double precision)
RETURNS double precision
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_options ->> p_key, '')::float8, p_default)
$$;
CREATE OR REPLACE FUNCTION ow_tools._opt_bool(p_options jsonb, p_key text, p_default boolean)
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_options ->> p_key, '')::boolean, p_default)
$$;
CREATE OR REPLACE FUNCTION ow_tools._opt_text(p_options jsonb, p_key text, p_default text)
RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(p_options ->> p_key, ''), p_default)
$$;

-- SEND_PHOTO: reconstruct media from an HLS playlist, apply an image-producing
-- ffmpeg transform, and queue as a photo (sendPhoto). transform 'thumbnail'
-- (default) grabs a video frame; 'waveform' renders an audio waveform image.
-- options (jsonb): thumbnail -> {seconds, format}; waveform ->
-- {width, height, format, mode}.
CREATE OR REPLACE FUNCTION ow_tools._tool_send_photo(
  p_playlist_id bigint,
  p_transform text DEFAULT 'thumbnail',
  p_options jsonb DEFAULT NULL,
  p_filename text DEFAULT '',
  p_caption text DEFAULT '',
  p_mime_type text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, ffmpeg, pg_temp
AS $$
DECLARE
  v_media bytea := ow_tools._hls_media(p_playlist_id);
  v_t text := lower(btrim(coalesce(p_transform, 'thumbnail')));
  v_out bytea;
BEGIN
  IF v_t IN ('', 'thumbnail') THEN
    v_out := ffmpeg.thumbnail(
      v_media,
      ow_tools._opt_float(p_options, 'seconds', 0.0),
      ow_tools._opt_text(p_options, 'format', 'png'));
  ELSIF v_t = 'waveform' THEN
    v_out := ffmpeg.waveform(
      v_media,
      ow_tools._opt_int(p_options, 'width', 800),
      ow_tools._opt_int(p_options, 'height', 200),
      ow_tools._opt_text(p_options, 'format', 'png'),
      ow_tools._opt_text(p_options, 'mode', 'waveform'));
  ELSE
    RAISE EXCEPTION 'unknown photo transform "%"; use thumbnail or waveform', v_t;
  END IF;

  RETURN ow_tools._queue_send('photo', v_out, v_t, p_filename, p_caption, p_mime_type);
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_send_photo(bigint, text, jsonb, text, text, text) IS 'Send a photo (Telegram sendPhoto) derived from an HLS playlist. First create the playlist with SELECT ffmpeg.hls(url, segment_duration) via the SQL tool, then pass the returned playlist_id here. transform selects the ffmpeg image op: "thumbnail" (default; grab a video frame — options: seconds, format png|jpeg) or "waveform" (render an audio waveform — options: width, height, format, mode). The frame/waveform is produced server-side; the model only handles the playlist_id.';

-- SEND_VIDEO: reconstruct media from an HLS playlist, optionally transform,
-- and queue as a video (sendVideo). transform '' / 'raw' (default) sends the
-- reconstructed media as-is; 'transcode' re-encodes; 'trim' cuts a sub-range.
CREATE OR REPLACE FUNCTION ow_tools._tool_send_video(
  p_playlist_id bigint,
  p_transform text DEFAULT '',
  p_options jsonb DEFAULT NULL,
  p_filename text DEFAULT '',
  p_caption text DEFAULT '',
  p_mime_type text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, ffmpeg, pg_temp
AS $$
DECLARE
  v_media bytea := ow_tools._hls_media(p_playlist_id);
  v_t text := lower(btrim(coalesce(p_transform, '')));
  v_out bytea;
BEGIN
  IF v_t IN ('', 'raw') THEN
    v_out := v_media;
  ELSIF v_t = 'transcode' THEN
    v_out := ffmpeg.transcode(
      v_media,
      format       := nullif(p_options ->> 'format', ''),
      filter       := nullif(p_options ->> 'filter', ''),
      codec        := nullif(p_options ->> 'codec', ''),
      preset       := nullif(p_options ->> 'preset', ''),
      crf          := nullif(p_options ->> 'crf', '')::integer,
      bitrate      := nullif(p_options ->> 'bitrate', '')::integer,
      audio_codec  := nullif(p_options ->> 'audio_codec', ''),
      audio_filter := nullif(p_options ->> 'audio_filter', ''),
      audio_bitrate:= nullif(p_options ->> 'audio_bitrate', '')::integer,
      hwaccel      := ow_tools._opt_bool(p_options, 'hwaccel', false));
  ELSIF v_t = 'trim' THEN
    v_out := ffmpeg.trim(
      v_media,
      ow_tools._opt_float(p_options, 'start_time', 0.0),
      nullif(p_options ->> 'end_time', '')::float8,
      ow_tools._opt_bool(p_options, 'precise', false));
  ELSE
    RAISE EXCEPTION 'unknown video transform "%"; use raw, transcode, or trim', v_t;
  END IF;

  RETURN ow_tools._queue_send('video', v_out, v_t, p_filename, p_caption, p_mime_type);
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_send_video(bigint, text, jsonb, text, text, text) IS 'Send a video (Telegram sendVideo) derived from an HLS playlist. First create the playlist with SELECT ffmpeg.hls(url, segment_duration) via the SQL tool, then pass the returned playlist_id here. transform selects the ffmpeg op: "raw"/"" (default; send reconstructed media as-is), "transcode" (re-encode — options: format, filter, codec, preset, crf, bitrate, audio_codec, audio_filter, audio_bitrate, hwaccel), or "trim" (cut a sub-range — options: start_time, end_time, precise). Produced server-side; the model only handles the playlist_id.';

-- SEND_AUDIO: reconstruct media from an HLS playlist, extract its audio, and
-- queue as audio (sendAudio). transform 'extract_audio' (default) pulls the
-- audio track; giving start_time/end_time additionally trims the extracted
-- audio to that range. options: format, codec, bitrate, sample_rate, channels,
-- filter (+ start_time/end_time/precise for the optional trim).
CREATE OR REPLACE FUNCTION ow_tools._tool_send_audio(
  p_playlist_id bigint,
  p_transform text DEFAULT 'extract_audio',
  p_options jsonb DEFAULT NULL,
  p_filename text DEFAULT '',
  p_caption text DEFAULT '',
  p_mime_type text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, ffmpeg, pg_temp
AS $$
DECLARE
  v_media bytea := ow_tools._hls_media(p_playlist_id);
  v_t text := lower(btrim(coalesce(p_transform, 'extract_audio')));
  v_out bytea;
BEGIN
  IF v_t IN ('', 'extract_audio') THEN
    v_out := ffmpeg.extract_audio(
      v_media,
      format      := nullif(p_options ->> 'format', ''),
      codec       := nullif(p_options ->> 'codec', ''),
      bitrate     := nullif(p_options ->> 'bitrate', '')::integer,
      sample_rate := nullif(p_options ->> 'sample_rate', '')::integer,
      channels    := nullif(p_options ->> 'channels', '')::integer,
      filter      := nullif(p_options ->> 'filter', ''));
    IF p_options ? 'start_time' OR p_options ? 'end_time' THEN
      v_out := ffmpeg.trim(
        v_out,
        ow_tools._opt_float(p_options, 'start_time', 0.0),
        nullif(p_options ->> 'end_time', '')::float8,
        ow_tools._opt_bool(p_options, 'precise', false));
    END IF;
  ELSE
    RAISE EXCEPTION 'unknown audio transform "%"; use extract_audio', v_t;
  END IF;

  RETURN ow_tools._queue_send('audio', v_out, v_t, p_filename, p_caption, p_mime_type);
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_send_audio(bigint, text, jsonb, text, text, text) IS 'Send audio (Telegram sendAudio) extracted from an HLS playlist. First create the playlist with SELECT ffmpeg.hls(url, segment_duration) via the SQL tool, then pass the returned playlist_id here. transform "extract_audio" (default) pulls the audio track (options: format, codec, bitrate, sample_rate, channels, filter); set start_time/end_time to additionally trim the extracted audio (precise for frame accuracy). Produced server-side; the model only handles the playlist_id.';

CREATE OR REPLACE FUNCTION ow_tools._decode_content(
  p_content text,
  p_encoding text
)
RETURNS bytea
LANGUAGE plpgsql
AS $$
DECLARE
  v_encoding text := btrim(coalesce(p_encoding, ''));
  v_format text := lower(btrim(coalesce(p_encoding, '')));
BEGIN
  IF p_content IS NULL THEN
    RAISE EXCEPTION 'content is required';
  END IF;
  IF v_encoding = '' THEN
    RAISE EXCEPTION 'encoding is required';
  END IF;

  IF v_format IN ('base64', 'hex', 'escape') THEN
    RETURN decode(p_content, v_format);
  END IF;

  RETURN convert_to(p_content, v_encoding);

EXCEPTION WHEN others THEN
  RAISE EXCEPTION 'could not decode content with encoding "%": %', v_encoding, SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION ow_tools._url_decode(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := replace(coalesce(p_text, ''), '+', ' ');
  v_result text := '';
  v_index integer := 1;
  v_char text;
  v_hex text;
BEGIN
  WHILE v_index <= length(v_text) LOOP
    v_char := substr(v_text, v_index, 1);
    v_hex := substr(v_text, v_index + 1, 2);

    IF v_char = '%' AND v_hex ~ '^[0-9A-Fa-f]{2}$' THEN
      v_result := v_result || convert_from(decode(v_hex, 'hex'), 'UTF8');
      v_index := v_index + 3;
    ELSE
      v_result := v_result || v_char;
      v_index := v_index + 1;
    END IF;
  END LOOP;

  RETURN v_result;
EXCEPTION WHEN others THEN
  RETURN coalesce(p_text, '');
END;
$$;

CREATE OR REPLACE FUNCTION ow_tools._url_encode(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := coalesce(p_text, '');
  v_result text := '';
  v_index integer := 1;
  v_char text;
  v_hex text;
  v_hex_index integer;
BEGIN
  WHILE v_index <= length(v_text) LOOP
    v_char := substr(v_text, v_index, 1);

    IF v_char ~ '^[A-Za-z0-9._~-]$' THEN
      v_result := v_result || v_char;
    ELSIF v_char = ' ' THEN
      v_result := v_result || '+';
    ELSE
      v_hex := encode(convert_to(v_char, 'UTF8'), 'hex');
      v_hex_index := 1;
      WHILE v_hex_index <= length(v_hex) LOOP
        v_result := v_result || '%' || upper(substr(v_hex, v_hex_index, 2));
        v_hex_index := v_hex_index + 2;
      END LOOP;
    END IF;

    v_index := v_index + 1;
  END LOOP;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION ow_tools._html_text(p_html text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_text text := coalesce(p_html, '');
BEGIN
  v_text := regexp_replace(v_text, '<[^>]+>', ' ', 'g');
  v_text := replace(v_text, '&amp;', '&');
  v_text := replace(v_text, '&lt;', '<');
  v_text := replace(v_text, '&gt;', '>');
  v_text := replace(v_text, '&quot;', '"');
  v_text := replace(v_text, '&#39;', '''');
  v_text := replace(v_text, '&apos;', '''');
  v_text := regexp_replace(v_text, '\s+', ' ', 'g');
  RETURN btrim(v_text);
END;
$$;

CREATE OR REPLACE FUNCTION ow_tools._http_url_allowed(p_url text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_url text := btrim(coalesce(p_url, ''));
  v_host text;
BEGIN
  IF v_url !~* '^https?://' THEN
    RETURN false;
  END IF;

  v_host := lower(substring(v_url from '^[Hh][Tt][Tt][Pp][Ss]?://([^/@:?#]+|\[[^]]+\])'));
  IF v_host IS NULL OR v_host = '' THEN
    RETURN false;
  END IF;

  v_host := trim(both '[]' from v_host);

  IF v_host IN ('localhost', 'ip6-localhost', 'ip6-loopback')
     OR v_host LIKE '%.localhost'
     OR v_host ~ '(^|:)(::1|fc[0-9a-f]|fd[0-9a-f])'
     OR v_host ~ '^(0|10|127)\.'
     OR v_host ~ '^169\.254\.'
     OR v_host ~ '^192\.168\.'
     OR v_host ~ '^172\.(1[6-9]|2[0-9]|3[0-1])\.' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

-- Walk a jsonb value from a SQL-tool result and replace bytea-derived string
-- leaves with a size marker. to_jsonb renders bytea as backslash-x + lowercase
-- hex (2 chars/byte, always even-length); a query that selects a bytea column —
-- or an inline ffmpeg.* output (thumbnails/transcodes/waveforms return bytea) —
-- would otherwise dump that hex into the tool result, which is stored as the
-- role='tool' message and replayed to the LLM every turn, blowing the context
-- window. The bytes are useless to the model as text, so we drop them at
-- result-build time (mirroring how _webfetch_result caps its body). Recurses
-- through objects and arrays so bytea[], composite columns, and nested values
-- are caught. The backslash is matched via chr(92) (no literal '\' in source) so
-- the check is immune to standard_conforming_strings. A genuine text value that
-- is exactly backslash-x + even-length lowercase hex would also be redacted —
-- vanishingly rare, and it only costs a marker.
CREATE OR REPLACE FUNCTION ow_tools._redact_bytea_json(p_value jsonb, p_key text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_str text;
  v_bytes integer;
BEGIN
  CASE jsonb_typeof(p_value)
    WHEN 'string' THEN
      v_str := p_value #>> '{}';
      IF length(v_str) >= 4
         AND left(v_str, 2) = chr(92) || 'x'
         AND substr(v_str, 3) ~ '^[0-9a-f]+$'
         AND mod(length(v_str) - 2, 2) = 0
      THEN
        v_bytes := (length(v_str) - 2) / 2;
        RETURN to_jsonb(
          CASE WHEN p_key IS NULL
               THEN '[bytea ' || v_bytes || ' bytes]'
               ELSE '[bytea ' || v_bytes || ' bytes, column "' || p_key || '"]'
          END
        );
      END IF;
      RETURN p_value;
    WHEN 'object' THEN
      RETURN (
        SELECT coalesce(jsonb_object_agg(key, ow_tools._redact_bytea_json(value, key)), '{}'::jsonb)
        FROM jsonb_each(p_value)
      );
    WHEN 'array' THEN
      RETURN (
        SELECT coalesce(jsonb_agg(ow_tools._redact_bytea_json(value, NULL) ORDER BY ordinality), '[]'::jsonb)
        FROM jsonb_array_elements(p_value) WITH ORDINALITY AS arr(value, ordinality)
      );
    ELSE
      RETURN p_value;
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION ow_tools._tool_sql(p_query text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_query text;
  v_rows jsonb;
BEGIN
  v_query := btrim(coalesce(p_query, ''));
  -- Tolerate a single trailing semicolon (a common habit). Strip it, then
  -- reject any remaining semicolon, which would signal a second statement.
  IF right(v_query, 1) = ';' THEN
    v_query := btrim(left(v_query, length(v_query) - 1));
  END IF;
  IF v_query = '' THEN
    RAISE EXCEPTION 'SQL tool requires query';
  END IF;
  IF position(';' IN v_query) > 0 THEN
    RAISE EXCEPTION 'SQL tool accepts a single query';
  END IF;

  EXECUTE format(
    'SELECT coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (%s) AS q',
    v_query
  )
  INTO v_rows;

  -- Strip bytea-derived hex (binary columns / inline ffmpeg.* outputs) so it
  -- never reaches the LLM via the tool result. See _redact_bytea_json.
  v_rows := ow_tools._redact_bytea_json(coalesce(v_rows, '[]'::jsonb));

  RETURN jsonb_pretty(jsonb_build_object(
    'rows', coalesce(v_rows, '[]'::jsonb),
    'row_count', jsonb_array_length(coalesce(v_rows, '[]'::jsonb))
  ));
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_sql(text) IS 'Run one SQL query inside PostgreSQL. A single trailing semicolon is tolerated; multiple statements are rejected. The query must return rows. For writes, use a data-modifying CTE with RETURNING.';

-- BASH: run a shell command on a remote host registered in ssh.hosts (the pg_ssh
-- catalog). ssh.exec is SECURITY DEFINER, owned by the postgres superuser
-- that ran CREATE EXTENSION, with EXECUTE granted to PUBLIC by default, so the
-- acting role can call it with no extra grants. The PEM keys never leave
-- ssh.hosts (superuser-only); the operator registers hosts and pins host-key
-- fingerprints out of band, and can REVOKE EXECUTE FROM PUBLIC to restrict which
-- roles may run remote commands. ssh.exec returns stdout/stderr as bytea
-- (binary-safe); we decode them as UTF-8 here since BASH output is text. On
-- connection/auth failure ssh.exec raises, which run_tool_call_as_role turns
-- into an 'error: ...' result. The host arg is optional: when omitted, BASH
-- targets the first entry in ssh.hosts (see _default_ssh_host).

-- Default SSH host = first entry in ssh.hosts. SECURITY DEFINER (owned by the
-- bootstrap superuser) because ssh.hosts is superuser-only — it stores private
-- keys — so the acting role that runs _tool_bash can't read it directly; we
-- expose only host_name, a non-sensitive operator-assigned label. ssh.hosts has
-- no insertion-order column, so "first" is host_name-ascending (deterministic);
-- in the usual single-host deployment there is only one row. Returns NULL when
-- no host is registered, in which case _tool_bash raises.
CREATE OR REPLACE FUNCTION ow_tools._default_ssh_host()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = pg_catalog
AS $$
  SELECT host_name FROM ssh.hosts ORDER BY host_name LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION ow_tools._tool_bash(
  p_command text,
  p_host text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_command text := coalesce(p_command, '');
  v_host text := btrim(coalesce(p_host, ''));
  v_stdout text;
  v_stderr text;
  v_exit integer;
BEGIN
  IF v_command = '' THEN
    RAISE EXCEPTION 'BASH requires command';
  END IF;

  -- No host specified: use the first entry in ssh.hosts (resolved superuser-side
  -- by _default_ssh_host; ssh.hosts itself is unreadable by the acting role).
  IF v_host = '' THEN
    v_host := ow_tools._default_ssh_host();
    IF v_host IS NULL THEN
      RAISE EXCEPTION 'BASH requires host (no SSH hosts registered in ssh.hosts)';
    END IF;
    v_host := btrim(v_host);
  END IF;

  -- ssh.exec returns TABLE(stdout bytea, stderr bytea, exit_code int); decode
  -- the streams as UTF-8 to keep the text-typed locals (and JSON result) honest.
  SELECT convert_from(stdout, 'UTF8'), convert_from(stderr, 'UTF8'), exit_code
    INTO v_stdout, v_stderr, v_exit
  FROM ssh.exec(v_host, v_command);

  RETURN jsonb_build_object(
    'host', v_host,
    'exit_code', coalesce(v_exit, -1),
    'stdout', coalesce(v_stdout, ''),
    'stderr', coalesce(v_stderr, '')
  )::text;
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_bash(text, text) IS 'Run a shell command on a remote host over SSH and return stdout, stderr, and exit_code. host is optional and defaults to the first entry in ssh.hosts when omitted; the host must already be registered in ssh.hosts.';

-- Build the result text of a WEBFETCH from its http response (no append).
CREATE OR REPLACE FUNCTION ow_tools._webfetch_result(
  p_args jsonb,
  p_http_response jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_max_bytes integer;
  v_headers jsonb;
  v_body text;
BEGIN
  v_max_bytes := least(greatest(coalesce((p_args->>'max_bytes')::integer, 20000), 1000), 200000);
  v_headers := coalesce(p_http_response->'headers', '{}'::jsonb);
  v_body := left(coalesce(p_http_response->>'body', ''), v_max_bytes);

  RETURN jsonb_build_object(
    'url', p_args->>'url',
    'effective_url', p_args->>'url',
    'status', coalesce((p_http_response->>'status')::integer, 0),
    'content_type', coalesce(v_headers->>'content-type', v_headers->>'Content-Type', ''),
    'bytes_returned', length(v_body),
    'truncated', length(coalesce(p_http_response->>'body', '')) > length(v_body),
    'body', v_body
  )::text;
END;
$$;

-- Build the result text of a SEARCH from its Exa JSON http response (no append).
CREATE OR REPLACE FUNCTION ow_tools._search_result(
  p_args jsonb,
  p_http_response jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce((p_args->>'limit')::integer, 5), 1), 10);
  v_body jsonb;
  v_row jsonb;
  v_results jsonb := '[]'::jsonb;
BEGIN
  v_body := ow._try_jsonb(coalesce(p_http_response->>'body', ''));

  -- Gracefully surface a non-JSON / unexpected Exa body instead of crashing the
  -- turn (e.g. bad key -> 401, or a stray HTML error page). _try_jsonb never
  -- returns NULL (it yields {} or {"_raw": ...}), so test the results array
  -- directly: IS DISTINCT FROM catches missing/null/non-array alike.
  IF jsonb_typeof(v_body->'results') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object(
      'query', p_args->>'query',
      'results', '[]'::jsonb,
      'result_count', 0,
      'status', coalesce((p_http_response->>'status')::integer, 0),
      'error', 'exa returned no parseable results'
    )::text;
  END IF;

  FOR v_row IN
    SELECT value FROM jsonb_array_elements(v_body->'results') LIMIT v_limit
  LOOP
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'title',   coalesce(v_row->>'title', ''),
      'url',     coalesce(v_row->>'url', ''),
      'snippet', left(coalesce(v_row->>'text', ''), 500)
    ));
  END LOOP;

  RETURN (jsonb_build_object(
    'query', p_args->>'query',
    'results', v_results,
    'result_count', jsonb_array_length(v_results)
  ) || jsonb_build_object('status', coalesce((p_http_response->>'status')::integer, 0)))::text;
END;
$$;

-- Build the SEARCH future (a df http graph) against the Exa search API. Returns
-- the graph text, or an error result text when the query is empty or the agent
-- has no exa_api_key. Introspected as the SEARCH tool schema.
CREATE OR REPLACE FUNCTION ow_tools._tool_search(
  p_query text,
  p_limit integer DEFAULT 5
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_limit integer := least(greatest(coalesce(p_limit, 5), 1), 10);
  v_agent_id bigint;
  v_key text;
  v_body text;
BEGIN
  IF btrim(coalesce(p_query, '')) = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: SEARCH requires query');
  END IF;

  -- Agent context reaches the tool via GUC (there are no agent params: the
  -- signature is introspected as the LLM-facing schema). start_tool_calls binds
  -- it for this path; the agent role can SELECT its own secret config under RLS.
  v_agent_id := nullif(current_setting('ow.current_agent_id', true), '')::bigint;
  v_key := ow._config_text(v_agent_id, 'exa_api_key');
  IF v_key IS NULL OR v_key = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: SEARCH requires exa_api_key config');
  END IF;

  v_body := jsonb_build_object(
    'query', p_query,
    'numResults', v_limit,
    'contents', jsonb_build_object('text', jsonb_build_object('maxCharacters', 500))
  )::text;

  RETURN format('SELECT %L::text AS body', v_body) |=> 'request'
    ~> df.http(
      'https://api.exa.ai/search', 'POST', '$request',
      jsonb_build_object('x-api-key', v_key, 'Content-Type', 'application/json'),
      30
    ) |=> 'http'
    ~> format(
      'SELECT ow_tools._search_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('query', p_query, 'limit', v_limit)::text
    );
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_search(text, integer) IS 'Search the public web and return a JSON list of result titles, URLs, and snippets.';

-- Build the WEBFETCH future (a df http graph). Returns the graph text, or an
-- error result text for non-public URLs. Introspected as the WEBFETCH tool schema.
CREATE OR REPLACE FUNCTION ow_tools._tool_webfetch(
  p_url text,
  p_max_bytes integer DEFAULT 20000
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ow, ow_tools, public, pg_temp
AS $$
BEGIN
  IF NOT ow_tools._http_url_allowed(p_url) THEN
    RETURN format('SELECT %L::text AS result', 'error: WEBFETCH requires a public http(s) URL');
  END IF;

  RETURN df.http(
    p_url, 'GET', '',
    jsonb_build_object(
      'User-Agent', 'ow-webfetch/1.0',
      'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
    ), 30
  ) |=> 'http'
    ~> format(
      'SELECT ow_tools._webfetch_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('url', p_url, 'max_bytes', p_max_bytes)::text
    );
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_webfetch(text, integer) IS 'Fetch an HTTP or HTTPS URL and return status, content type, effective URL, and a truncated text body.';

-- ============================================================================
-- GENERATE_VIDEO: async video generation via the stable-diffusion.cpp sdcpp API
--   (POST /sdcpp/v1/vid_gen -> poll GET /sdcpp/v1/jobs/{id} -> deliver the
--   encoded container). Agent-scoped config (seeded from env like exa_api_key):
--     sdcpp_api_base  e.g. http://localhost:8080   (REQUIRED)
--     sdcpp_api_key   optional Bearer token
--   The graph submits the job, polls until terminal in a df.loop with df.sleep,
--   then queues the returned base64 container as an outbound Telegram video
--   attachment via queue_outbound_attachment — so the video bytes never enter
--   the model context, only a small JSON summary does. When this tool is
--   present in a turn, start_tool_cells raises await_tool_calls' per-turn
--   timeout to 600s (see start_tool_calls), since short clips can take minutes.
--   The sdcpp endpoint host must be in pg_durable's HTTP egress allowlist.
-- ============================================================================

-- True when a GET /sdcpp/v1/jobs/{id} df.http envelope is terminal: the call
-- did not succeed (ok absent/false, e.g. 404/410 gone) OR the parsed job body
-- status is completed / failed / cancelled. Pure (HTTP envelope jsonb only).
CREATE OR REPLACE FUNCTION ow_tools._sdcpp_job_terminal(p_envelope jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(NOT coalesce((p_envelope->>'ok')::boolean, false), false)
      OR coalesce(ow._http_body_json(p_envelope)->>'status', '')
         IN ('completed', 'failed', 'cancelled')
$$;

-- Build the absolute poll URL for a vid_gen submission: parse poll_url out of
-- the 202 response body and prefix the configured sdcpp base. Pure. Raises when
-- the submission returned no poll_url (caller surfaces it as a tool error).
CREATE OR REPLACE FUNCTION ow_tools._sdcpp_job_url(p_base text, p_envelope jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_poll text := ow._http_body_json(p_envelope)->>'poll_url';
BEGIN
  IF v_poll IS NULL OR v_poll = '' THEN
    RAISE EXCEPTION 'vid_gen submission returned no poll_url';
  END IF;
  RETURN rtrim(coalesce(p_base, ''), '/') || v_poll;
END;
$$;

-- Terminal-job handler for the polling loop. On a completed job, decode the
-- returned base64 container and queue it as an outbound Telegram video
-- attachment (queue_outbound_attachment, SECURITY DEFINER owner ow_agent_primary,
-- self-resolves chat_id when NULL). On failed / cancelled / missing bytes it
-- returns an error summary WITHOUT raising, so the turn continues and the model
-- sees what went wrong. p_chat_id is resolved at graph-build time (the latest
-- user message's chat) and baked into the node. Pure w.r.t. its args.
CREATE OR REPLACE FUNCTION ow_tools._sdcpp_finalize_video(
  p_agent_slug text,
  p_envelope jsonb,
  p_caption text DEFAULT '',
  p_filename text DEFAULT '',
  p_chat_id text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_job jsonb := ow._http_body_json(p_envelope);
  v_status text := coalesce(v_job->>'status', '');
  v_result jsonb;
  v_b64 text;
  v_mime text;
  v_fmt text;
  v_ext text;
  v_filename text;
BEGIN
  IF v_status <> 'completed' THEN
    RETURN jsonb_build_object(
      'queued', false,
      'status', v_status,
      'http_status', ow._http_status(p_envelope),
      'error', v_job->'error',
      'body', left(coalesce(p_envelope->>'body', ''), 300)
    )::text;
  END IF;

  v_result := v_job->'result';
  v_b64 := coalesce(v_result->>'b64_json', '');
  IF v_b64 = '' THEN
    RETURN jsonb_build_object(
      'queued', false, 'status', 'completed',
      'error', jsonb_build_object('code', 'no_video', 'message', 'completed job returned no b64_json')
    )::text;
  END IF;

  v_fmt  := coalesce(v_result->>'output_format', 'webm');
  v_mime := coalesce(v_result->>'mime_type', CASE v_fmt WHEN 'webp' THEN 'image/webp' WHEN 'avi' THEN 'video/x-msvideo' ELSE 'video/webm' END);
  v_ext  := CASE v_fmt WHEN 'webp' THEN 'webp' WHEN 'avi' THEN 'avi' ELSE 'webm' END;
  v_filename := coalesce(nullif(p_filename, ''), 'generated_video.' || v_ext);

  PERFORM ow.queue_outbound_attachment(
    p_agent_slug, v_b64, 'video', v_filename,
    nullif(p_caption, ''), v_mime, nullif(p_chat_id, ''));

  RETURN jsonb_build_object(
    'queued', true,
    'delivered', 'video',
    'status', 'completed',
    'frame_count', nullif(v_result->>'frame_count', '')::integer,
    'fps', nullif(v_result->>'fps', '')::integer,
    'output_format', v_fmt,
    'mime_type', v_mime
  )::text;
END;
$$;

-- Build a tool result for a non-202 vid_gen submission (4xx/other). Pure.
CREATE OR REPLACE FUNCTION ow_tools._sdcpp_error_result(p_envelope jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN jsonb_build_object(
    'queued', false,
    'error', 'vid_gen submission failed',
    'http_status', ow._http_status(p_envelope),
    'body', left(coalesce(p_envelope->>'body', ''), 500)
  )::text;
END;
$$;

-- GENERATE_VIDEO graph builder. Reads sdcpp config at BUILD time (the agent GUC
-- is bound by start_tool_calls) and bakes endpoint, headers, slug, chat_id and
-- the vid_gen request body into the graph text as literals — no graph node does
-- an agent-scoped config read. Introspected as the LLM-facing GENERATE_VIDEO
-- schema. Returns a df graph text (like SEARCH/WEBFETCH), or a single-node error
-- result text when sdcpp_api_base is unset.
CREATE OR REPLACE FUNCTION ow_tools._tool_generate_video(
  p_prompt text,
  p_negative_prompt text DEFAULT '',
  p_width integer DEFAULT 832,
  p_height integer DEFAULT 480,
  p_strength double precision DEFAULT 0.75,
  p_seed integer DEFAULT -1,
  p_video_frames integer DEFAULT 33,
  p_fps integer DEFAULT 16,
  p_output_format text DEFAULT 'webm',
  p_init_image text DEFAULT '',
  p_end_image text DEFAULT '',
  p_caption text DEFAULT '',
  p_filename text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := nullif(current_setting('ow.current_agent_id', true), '')::bigint;
  v_slug text;
  v_base text;
  v_key text;
  v_chat_id text;
  v_headers jsonb;
  v_headers_text text;
  v_body jsonb;
  v_body_text text;
  v_vid_url text;
  v_poll_interval integer := 3;
BEGIN
  IF btrim(coalesce(p_prompt, '')) = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: GENERATE_VIDEO requires prompt');
  END IF;

  IF v_agent_id IS NULL THEN
    RETURN format('SELECT %L::text AS result', 'error: GENERATE_VIDEO has no current agent context');
  END IF;

  v_base := ow._config_text(v_agent_id, 'sdcpp_api_base');
  IF v_base IS NULL OR btrim(v_base) = '' THEN
    RETURN format('SELECT %L::text AS result', 'error: GENERATE_VIDEO requires sdcpp_api_base config');
  END IF;

  SELECT slug INTO v_slug FROM ow.agents WHERE id = v_agent_id;
  SELECT m.chat_id INTO v_chat_id
    FROM ow.messages m
    WHERE m.agent_id = v_agent_id AND m.role = 'user'
    ORDER BY m.id DESC LIMIT 1;

  v_key := ow._config_text(v_agent_id, 'sdcpp_api_key');
  v_headers := jsonb_build_object('Content-Type', 'application/json', 'Accept', 'application/json');
  IF v_key IS NOT NULL AND v_key <> '' THEN
    v_headers := v_headers || jsonb_build_object('Authorization', 'Bearer ' || v_key);
  END IF;
  v_headers_text := v_headers::text;

  -- Native sdcpp vid_gen request; omitted sample_params fall back to backend
  -- defaults (see api.md "Optional Field Handling"). init_image/end_image, when
  -- supplied (base64 or data: URL), drive image-to-video; omitted => txt2video.
  v_body := jsonb_strip_nulls(jsonb_build_object(
    'prompt', p_prompt,
    'negative_prompt', nullif(p_negative_prompt, ''),
    'width', p_width,
    'height', p_height,
    'strength', p_strength,
    'seed', p_seed,
    'video_frames', p_video_frames,
    'fps', p_fps,
    'clip_skip', -1,
    'output_format', nullif(p_output_format, ''),
    'init_image', nullif(p_init_image, ''),
    'end_image', nullif(p_end_image, '')
  ));
  v_body_text := v_body::text;
  v_vid_url := rtrim(v_base, '/') || '/sdcpp/v1/vid_gen';

  RETURN format(
    $graph$SELECT %L::text AS req |=> 'req'
~> df.http(%L, 'POST', '$req', %L::jsonb, 30) |=> 'submit'
~> df.if(
     'SELECT $submit.ok',
     SELECT ow_tools._sdcpp_job_url(%L, $submit::jsonb)::text AS purl |=> 'purl'
     ~> df.loop(
          df.http('$purl', 'GET', '', %L::jsonb, 30) |=> 'job'
          ~> df.if(
               'SELECT ow_tools._sdcpp_job_terminal($job::jsonb)',
               df.break('$job'),
               df.sleep(%s)
             )
        ) |=> 'final'
     ~> SELECT ow_tools._sdcpp_finalize_video(%L, $final::jsonb, %L, %L, %L)::text AS result,
     SELECT ow_tools._sdcpp_error_result($submit::jsonb)::text AS result
   )$graph$,
    v_body_text, v_vid_url, v_headers_text,
    v_base, v_headers_text, v_poll_interval,
    v_slug, coalesce(p_caption, ''), coalesce(p_filename, ''), coalesce(v_chat_id, '')
  );
END;
$$;
COMMENT ON FUNCTION ow_tools._tool_generate_video(text, text, integer, integer, double precision, integer, integer, integer, text, text, text, text, text) IS 'Generate a short video clip via the stable-diffusion.cpp sdcpp API and send it as a Telegram video. Parameters: prompt (required), negative_prompt, width, height, strength, seed (-1 random), video_frames (effective length is normalized to the largest 4n+1 <= requested), fps, output_format (webm|webp|avi; default webm), init_image / end_image (base64 or data: URL for image-to-video; omit for text-to-video), caption, filename. The clip is produced server-side and queued for delivery — only a small summary returns. Requires agent sdcpp_api_base config.';

-- Run one synchronous tool's WORK under the acting role (SET ROLE + GUCs), then
-- RESET. SECURITY INVOKER — SET ROLE is forbidden inside SECURITY DEFINER. The
-- instance that calls this is submitted by ow_service; we drop to the
-- acting role (the requesting user's tier, or the sidecar role) so RLS
-- binds for the tool's data access. Returns the result text; the orchestrator
-- appends the role='tool' message as service.
CREATE OR REPLACE FUNCTION ow_tools.run_tool_call_as_role(
  p_name text,
  p_args jsonb,
  p_acting_role text,
  p_agent_id bigint,
  p_agent_slug text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_result text;
  v_err text;
BEGIN
  EXECUTE format('SET ROLE %I', p_acting_role);
  PERFORM set_config('ow.current_agent_id', p_agent_id::text, true);
  PERFORM set_config('ow.current_chat_id', coalesce(p_chat_id, ''), true);
  PERFORM set_config('ow.current_user_id', coalesce(p_user_id::text, ''), true);
  BEGIN
    -- Agent context reaches the tool functions via GUCs (they no longer take an
    -- agent_id/agent_slug param, so every parameter is LLM-facing & introspectable).
    v_result := CASE p_name
      WHEN 'SQL' THEN ow_tools._tool_sql(coalesce(p_args->>'query', ''))
      WHEN 'BASH' THEN ow_tools._tool_bash(
            coalesce(p_args->>'command', ''),
            coalesce(p_args->>'host', ''))
      WHEN 'SEND_ATTACHMENT' THEN ow_tools._tool_send_attachment(
            coalesce(p_args->>'content', ''),
            coalesce(p_args->>'encoding', ''),
            coalesce(p_args->>'filename', ''),
            coalesce(p_args->>'caption', ''),
            coalesce(p_args->>'mime_type', ''))
      WHEN 'SEND_PHOTO' THEN ow_tools._tool_send_photo(
            nullif(p_args->>'playlist_id', '')::bigint,
            coalesce(p_args->>'transform', 'thumbnail'),
            ow._try_jsonb(coalesce(p_args->>'options', '')),
            coalesce(p_args->>'filename', ''),
            coalesce(p_args->>'caption', ''),
            coalesce(p_args->>'mime_type', ''))
      WHEN 'SEND_VIDEO' THEN ow_tools._tool_send_video(
            nullif(p_args->>'playlist_id', '')::bigint,
            coalesce(p_args->>'transform', ''),
            ow._try_jsonb(coalesce(p_args->>'options', '')),
            coalesce(p_args->>'filename', ''),
            coalesce(p_args->>'caption', ''),
            coalesce(p_args->>'mime_type', ''))
      WHEN 'SEND_AUDIO' THEN ow_tools._tool_send_audio(
            nullif(p_args->>'playlist_id', '')::bigint,
            coalesce(p_args->>'transform', 'extract_audio'),
            ow._try_jsonb(coalesce(p_args->>'options', '')),
            coalesce(p_args->>'filename', ''),
            coalesce(p_args->>'caption', ''),
            coalesce(p_args->>'mime_type', ''))
      ELSE NULL
    END;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
    EXECUTE 'RESET ROLE';
    v_result := 'error: ' || v_err;
  END;
  EXECUTE 'RESET ROLE';

  IF v_result IS NULL THEN
    v_result := 'error: unknown synchronous tool: ' || p_name;
  END IF;
  RETURN v_result;
END;
$$;

-- Build the df future for one tool call (the body of its tc instance).
-- SEARCH/WEBFETCH become an http graph; the rest run synchronously as the
-- acting role. Returns a df graph text.
CREATE OR REPLACE FUNCTION ow_tools.tool_call_future(
  p_name text,
  p_args jsonb,
  p_acting_role text,
  p_agent_id bigint,
  p_agent_slug text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_limit text;
  v_max_bytes text;
BEGIN
  IF p_name = 'WEBFETCH' THEN
    -- Safe integer parse: a malformed max_bytes must not abort the whole turn.
    v_max_bytes := p_args->>'max_bytes';
    RETURN ow_tools._tool_webfetch(
      btrim(coalesce(p_args->>'url', '')),
      CASE WHEN v_max_bytes ~ '^[0-9]+$' THEN v_max_bytes::integer ELSE 20000 END
    );
  ELSIF p_name = 'SEARCH' THEN
    v_limit := p_args->>'limit';
    RETURN ow_tools._tool_search(
      coalesce(p_args->>'query', ''),
      CASE WHEN v_limit ~ '^[0-9]+$' THEN v_limit::integer ELSE 5 END
    );
  ELSIF p_name = 'GENERATE_VIDEO' THEN
    -- Numeric field safe-parse mirrors SEARCH/WEBFETCH: a malformed value falls
    -- back to the function default rather than aborting the whole turn.
    RETURN ow_tools._tool_generate_video(
      coalesce(p_args->>'prompt', ''),
      coalesce(p_args->>'negative_prompt', ''),
      CASE WHEN (p_args->>'width') ~ '^[0-9]+$' THEN (p_args->>'width')::integer ELSE 832 END,
      CASE WHEN (p_args->>'height') ~ '^[0-9]+$' THEN (p_args->>'height')::integer ELSE 480 END,
      CASE WHEN (p_args->>'strength') ~ '^[0-9]+(\.[0-9]+)?$' THEN (p_args->>'strength')::float8 ELSE 0.75 END,
      CASE WHEN (p_args->>'seed') ~ '^-?[0-9]+$' THEN (p_args->>'seed')::integer ELSE -1 END,
      CASE WHEN (p_args->>'video_frames') ~ '^[0-9]+$' THEN (p_args->>'video_frames')::integer ELSE 33 END,
      CASE WHEN (p_args->>'fps') ~ '^[0-9]+$' THEN (p_args->>'fps')::integer ELSE 16 END,
      coalesce(p_args->>'output_format', 'webm'),
      coalesce(p_args->>'init_image', ''),
      coalesce(p_args->>'end_image', ''),
      coalesce(p_args->>'caption', ''),
      coalesce(p_args->>'filename', '')
    );
  END IF;

  -- synchronous tools run as the acting role
  RETURN format(
    'SELECT ow_tools.run_tool_call_as_role(%L, %L::jsonb, %L, %s, %L, %L, %L, %s)::text AS result',
    p_name, p_args::text, p_acting_role, p_agent_id, p_agent_slug,
    coalesce(p_user_external_id, ''), coalesce(p_chat_id, ''),
    coalesce(p_user_id::text, 'NULL')
  );
END;
$$;

-- Orchestrator for an assistant message's tool calls, split across TWO graph
-- nodes so the per-call durable instances actually run:
--   start_tool_calls: df.start every call (parallel), return
--     {"calls":[{id,tc_id},...],"timeout":N} (timeout is 600 when the batch
--     contains a GENERATE_VIDEO, else 120; await_tool_calls honors it).
--     Its transaction commits when the node ends, so workers can SEE and run the
--     instances. (Starting and awaiting in the SAME node left the starts
--     uncommitted in that node's transaction, so no worker picked them up and
--     every call timed out as "Instance not found".)
--   await_tool_calls: poll df.status per call (cancel on timeout) and append each
--     result as role='tool'. Runs in the NEXT node, by which point the starts are
--     committed and the tool instances are executing on other workers.
CREATE OR REPLACE FUNCTION ow_tools.start_tool_calls(
  p_agent_slug text,
  p_message_id bigint,
  p_tool_calls jsonb,
  p_acting_role text,
  p_user_external_id text DEFAULT NULL,
  p_chat_id text DEFAULT NULL,
  p_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_call jsonb;
  v_tool_call_id text;
  v_name text;
  v_args jsonb;
  v_future text;
  v_tc text;
  v_started jsonb := '[]'::jsonb;
  v_timeout integer;
BEGIN
  -- Bind agent context so the SEARCH graph builder (_tool_search) can read the
  -- agent's own secret config (exa_api_key) under RLS. The synchronous tools
  -- bind it again inside run_tool_call_as_role; setting it here is harmless.
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);

  IF p_acting_role IS NULL OR p_acting_role = '' THEN
    p_acting_role := 'ow_agent_primary';
  END IF;

  -- start every tool call as its own instance (all started before any awaiting)
  FOR v_call IN SELECT value FROM jsonb_array_elements(coalesce(p_tool_calls, '[]'::jsonb))
  LOOP
    v_tool_call_id := coalesce(v_call->>'id', 'call_' || md5(v_call::text));
    v_name := v_call #>> '{function,name}';
    v_args := ow._try_jsonb(v_call #>> '{function,arguments}');
    v_future := ow_tools.tool_call_future(
      v_name, v_args, p_acting_role, v_agent_id, p_agent_slug,
      p_user_external_id, p_chat_id, p_user_id
    );
    SELECT df.start(v_future, format('ow:tool:%s:%s', p_message_id, v_tool_call_id)) INTO v_tc;
    v_started := v_started || jsonb_build_array(
      jsonb_build_object('id', v_tc, 'tc_id', v_tool_call_id)
    );
  END LOOP;

  -- GENERATE_VIDEO submits + polls an sdcpp async job; clips can take minutes,
  -- so when one is in the batch raise await_tool_calls' per-turn timeout from
  -- the 120s default to 600s. The timeout rides alongside the started calls so
  -- await_tool_calls honors it without a signature change.
  v_timeout := CASE WHEN EXISTS (
      SELECT 1 FROM jsonb_array_elements(coalesce(p_tool_calls, '[]'::jsonb)) c
      WHERE c #>> '{function,name}' = 'GENERATE_VIDEO'
    ) THEN 600 ELSE 120 END;

  RETURN jsonb_build_object('calls', v_started, 'timeout', v_timeout)::text;
END;
$$;

-- Strip pg_durable's df.result() envelope to recover a tool call's own result
-- text. Each tool call runs as a one-node graph whose body is
-- `SELECT ow_tools.run_tool_call_as_role(...)::text AS result`, and df.result()
-- exposes a node's terminal SELECT wrapped as {"rows":[{<cols>}],"row_count":N}.
-- So the single row comes back as {"rows":[{"result": <text>}],"row_count":1},
-- with the tool's actual output (_tool_sql's {"rows":...,"row_count":...}, BASH
-- stdout, an error string) sitting at rows[0].result as a JSON string. Returning
-- that verbatim would replay a double-wrapped blob to the LLM every turn.
--
-- The earlier form read a top-level `result` key (->>'result'), which df.result()
-- never sets — the value is nested under rows[0] — so coalesce always fell through
-- and stored the whole envelope. Anything without a rows[0].result (df.result
-- raised and the caller stored an 'error: ...' string, or a non-JSON value) is
-- returned unchanged. Pure (IMMUTABLE) so it can be unit-tested without df.start,
-- which the test harness can't run.
CREATE OR REPLACE FUNCTION ow_tools._unwrap_tool_result(p_result text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(ow._try_jsonb(p_result) #>> '{rows,0,result}', p_result)
$$;

CREATE OR REPLACE FUNCTION ow_tools.await_tool_calls(
  p_agent_slug text,
  p_started text,
  p_timeout integer DEFAULT 120
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_started_obj jsonb;
  v_calls jsonb;
  v_item jsonb;
  v_id text;
  v_tcid text;
  v_status text;
  v_result text;
  v_deadline timestamptz;
  v_count integer := 0;
  v_timeout integer;
BEGIN
  -- start_tool_calls may now return {"calls":[...],"timeout":N} (when the batch
  -- holds a long-running GENERATE_VIDEO) instead of a bare array. Keep bare
  -- arrays working (older callers / tests) by falling back to p_timeout.
  v_started_obj := ow._try_jsonb(p_started);
  v_calls := CASE jsonb_typeof(v_started_obj)
              WHEN 'array'  THEN v_started_obj
              WHEN 'object' THEN coalesce(v_started_obj->'calls', '[]'::jsonb)
              ELSE '[]'::jsonb END;
  v_timeout := coalesce(nullif(v_started_obj->>'timeout', '')::integer, p_timeout);

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_calls)
  LOOP
    v_count := v_count + 1;
    v_id := v_item->>'id';
    v_tcid := v_item->>'tc_id';
    v_deadline := clock_timestamp() + make_interval(secs => v_timeout);
    v_status := NULL;
    LOOP
      BEGIN
        SELECT df.status(v_id) INTO v_status;
      EXCEPTION WHEN OTHERS THEN
        v_status := 'error';
      END;
      EXIT WHEN v_status IN ('completed', 'failed', 'cancelled', 'error');
      IF clock_timestamp() >= v_deadline THEN
        BEGIN
          PERFORM df.cancel(v_id, 'tool call timeout');
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
        v_status := 'cancelled';
        EXIT;
      END IF;
      -- TODO: use future composition when upstream supports it
      PERFORM pg_sleep(0.1);
    END LOOP;

    BEGIN
      SELECT df.result(v_id) INTO v_result;
      v_result := ow_tools._unwrap_tool_result(v_result);
    EXCEPTION WHEN OTHERS THEN
      v_result := 'error: ' || SQLERRM;
    END;
    IF v_status <> 'completed' THEN
      v_result := coalesce(v_result, 'error: tool ' || v_status);
    END IF;

    PERFORM ow_tools._append_tool_message(v_agent_id, v_tcid, v_result);
  END LOOP;

  RETURN jsonb_build_object('tool_calls', v_count)::text;
END;
$$;
