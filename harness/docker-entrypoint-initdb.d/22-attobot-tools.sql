CREATE OR REPLACE FUNCTION attotools._append_tool_message(
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
  PERFORM set_config('attobot.current_agent_id', p_agent_id::text, true);

  INSERT INTO attobot.messages(agent_id, role, content, tool_call_id)
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
CREATE OR REPLACE FUNCTION attotools._attachment_kind(
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
-- queue_outbound_attachment (SECURITY DEFINER, owner attobot_agent_primary) does
-- the privileged append so this works even when the caller is the anonymous
-- acting role.
CREATE OR REPLACE FUNCTION attotools._tool_send_attachment(
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
  v_agent_id bigint := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_bytes bytea;
  v_kind text;
  v_slug text;
  v_chat_id text;
BEGIN
  IF v_agent_id IS NULL THEN
    RAISE EXCEPTION 'SEND_ATTACHMENT has no current agent context';
  END IF;

  v_bytes := attotools._decode_content(p_content, p_encoding);
  v_kind := attotools._attachment_kind(v_bytes, p_mime_type, p_filename);

  SELECT slug, chat_id INTO v_slug, v_chat_id
  FROM attobot.messages m JOIN attobot.agents a ON a.id = m.agent_id
  WHERE m.agent_id = v_agent_id AND m.role = 'user'
  ORDER BY m.id DESC LIMIT 1;

  PERFORM attobot.queue_outbound_attachment(
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
COMMENT ON FUNCTION attotools._tool_send_attachment(text, text, text, text, text) IS 'Send media (image/audio/video) as a Telegram attachment. Pass the raw content with an encoding (base64, hex, escape, or a text encoding like UTF8). The kind is auto-detected from mime_type/filename, falling back to ffmpeg.media_info: photos use sendPhoto, audio sendAudio, video sendVideo, anything else sendDocument.';

CREATE OR REPLACE FUNCTION attotools._decode_content(
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

CREATE OR REPLACE FUNCTION attotools._url_decode(p_text text)
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

CREATE OR REPLACE FUNCTION attotools._url_encode(p_text text)
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

CREATE OR REPLACE FUNCTION attotools._html_text(p_html text)
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

CREATE OR REPLACE FUNCTION attotools._http_url_allowed(p_url text)
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
CREATE OR REPLACE FUNCTION attotools._redact_bytea_json(p_value jsonb, p_key text DEFAULT NULL)
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
        SELECT coalesce(jsonb_object_agg(key, attotools._redact_bytea_json(value, key)), '{}'::jsonb)
        FROM jsonb_each(p_value)
      );
    WHEN 'array' THEN
      RETURN (
        SELECT coalesce(jsonb_agg(attotools._redact_bytea_json(value, NULL) ORDER BY ordinality), '[]'::jsonb)
        FROM jsonb_array_elements(p_value) WITH ORDINALITY AS arr(value, ordinality)
      );
    ELSE
      RETURN p_value;
  END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_sql(p_query text)
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
  v_rows := attotools._redact_bytea_json(coalesce(v_rows, '[]'::jsonb));

  RETURN jsonb_pretty(jsonb_build_object(
    'rows', coalesce(v_rows, '[]'::jsonb),
    'row_count', jsonb_array_length(coalesce(v_rows, '[]'::jsonb))
  ));
END;
$$;
COMMENT ON FUNCTION attotools._tool_sql(text) IS 'Run one SQL query inside PostgreSQL. A single trailing semicolon is tolerated; multiple statements are rejected. The query must return rows. For writes, use a data-modifying CTE with RETURNING.';

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
CREATE OR REPLACE FUNCTION attotools._default_ssh_host()
RETURNS text
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = pg_catalog
AS $$
  SELECT host_name FROM ssh.hosts ORDER BY host_name LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION attotools._tool_bash(
  p_command text,
  p_host text DEFAULT ''
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
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
    v_host := attotools._default_ssh_host();
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
COMMENT ON FUNCTION attotools._tool_bash(text, text) IS 'Run a shell command on a remote host over SSH and return stdout, stderr, and exit_code. host is optional and defaults to the first entry in ssh.hosts when omitted; the host must already be registered in ssh.hosts.';

-- Build the result text of a WEBFETCH from its http response (no append).
CREATE OR REPLACE FUNCTION attotools._webfetch_result(
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
CREATE OR REPLACE FUNCTION attotools._search_result(
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
  v_body := attobot._try_jsonb(coalesce(p_http_response->>'body', ''));

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
CREATE OR REPLACE FUNCTION attotools._tool_search(
  p_query text,
  p_limit integer DEFAULT 5
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
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
  v_agent_id := nullif(current_setting('attobot.current_agent_id', true), '')::bigint;
  v_key := attobot._config_text(v_agent_id, 'exa_api_key');
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
      'SELECT attotools._search_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('query', p_query, 'limit', v_limit)::text
    );
END;
$$;
COMMENT ON FUNCTION attotools._tool_search(text, integer) IS 'Search the public web and return a JSON list of result titles, URLs, and snippets.';

-- Build the WEBFETCH future (a df http graph). Returns the graph text, or an
-- error result text for non-public URLs. Introspected as the WEBFETCH tool schema.
CREATE OR REPLACE FUNCTION attotools._tool_webfetch(
  p_url text,
  p_max_bytes integer DEFAULT 20000
)
RETURNS text
LANGUAGE plpgsql
SET search_path = attobot, attotools, public, pg_temp
AS $$
BEGIN
  IF NOT attotools._http_url_allowed(p_url) THEN
    RETURN format('SELECT %L::text AS result', 'error: WEBFETCH requires a public http(s) URL');
  END IF;

  RETURN df.http(
    p_url, 'GET', '',
    jsonb_build_object(
      'User-Agent', 'attobot-webfetch/1.0',
      'Accept', 'text/html,application/xhtml+xml,application/xml,text/plain,*/*;q=0.8'
    ), 30
  ) |=> 'http'
    ~> format(
      'SELECT attotools._webfetch_result(%L::jsonb, $http::jsonb)::text AS result',
      jsonb_build_object('url', p_url, 'max_bytes', p_max_bytes)::text
    );
END;
$$;
COMMENT ON FUNCTION attotools._tool_webfetch(text, integer) IS 'Fetch an HTTP or HTTPS URL and return status, content type, effective URL, and a truncated text body.';

-- Run one synchronous tool's WORK under the acting role (SET ROLE + GUCs), then
-- RESET. SECURITY INVOKER — SET ROLE is forbidden inside SECURITY DEFINER. The
-- instance that calls this is submitted by attobot_service; we drop to the
-- acting role (the requesting user's tier, or the subconscious role) so RLS
-- binds for the tool's data access. Returns the result text; the orchestrator
-- appends the role='tool' message as service.
CREATE OR REPLACE FUNCTION attotools.run_tool_call_as_role(
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
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_result text;
  v_err text;
BEGIN
  EXECUTE format('SET ROLE %I', p_acting_role);
  PERFORM set_config('attobot.current_agent_id', p_agent_id::text, true);
  PERFORM set_config('attobot.current_chat_id', coalesce(p_chat_id, ''), true);
  PERFORM set_config('attobot.current_user_id', coalesce(p_user_id::text, ''), true);
  BEGIN
    -- Agent context reaches the tool functions via GUCs (they no longer take an
    -- agent_id/agent_slug param, so every parameter is LLM-facing & introspectable).
    v_result := CASE p_name
      WHEN 'SQL' THEN attotools._tool_sql(coalesce(p_args->>'query', ''))
      WHEN 'BASH' THEN attotools._tool_bash(
            coalesce(p_args->>'command', ''),
            coalesce(p_args->>'host', ''))
      WHEN 'SEND_ATTACHMENT' THEN attotools._tool_send_attachment(
            coalesce(p_args->>'content', ''),
            coalesce(p_args->>'encoding', ''),
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
CREATE OR REPLACE FUNCTION attotools.tool_call_future(
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
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_limit text;
  v_max_bytes text;
BEGIN
  IF p_name = 'WEBFETCH' THEN
    -- Safe integer parse: a malformed max_bytes must not abort the whole turn.
    v_max_bytes := p_args->>'max_bytes';
    RETURN attotools._tool_webfetch(
      btrim(coalesce(p_args->>'url', '')),
      CASE WHEN v_max_bytes ~ '^[0-9]+$' THEN v_max_bytes::integer ELSE 20000 END
    );
  ELSIF p_name = 'SEARCH' THEN
    v_limit := p_args->>'limit';
    RETURN attotools._tool_search(
      coalesce(p_args->>'query', ''),
      CASE WHEN v_limit ~ '^[0-9]+$' THEN v_limit::integer ELSE 5 END
    );
  END IF;

  -- synchronous tools run as the acting role
  RETURN format(
    'SELECT attotools.run_tool_call_as_role(%L, %L::jsonb, %L, %s, %L, %L, %L, %s)::text AS result',
    p_name, p_args::text, p_acting_role, p_agent_id, p_agent_slug,
    coalesce(p_user_external_id, ''), coalesce(p_chat_id, ''),
    coalesce(p_user_id::text, 'NULL')
  );
END;
$$;

-- Orchestrator for an assistant message's tool calls, split across TWO graph
-- nodes so the per-call durable instances actually run:
--   start_tool_calls: df.start every call (parallel), return [{id,tc_id},...].
--     Its transaction commits when the node ends, so workers can SEE and run the
--     instances. (Starting and awaiting in the SAME node left the starts
--     uncommitted in that node's transaction, so no worker picked them up and
--     every call timed out as "Instance not found".)
--   await_tool_calls: poll df.status per call (cancel on timeout) and append each
--     result as role='tool'. Runs in the NEXT node, by which point the starts are
--     committed and the tool instances are executing on other workers.
CREATE OR REPLACE FUNCTION attotools.start_tool_calls(
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
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_call jsonb;
  v_tool_call_id text;
  v_name text;
  v_args jsonb;
  v_future text;
  v_tc text;
  v_started jsonb := '[]'::jsonb;
BEGIN
  -- Bind agent context so the SEARCH graph builder (_tool_search) can read the
  -- agent's own secret config (exa_api_key) under RLS. The synchronous tools
  -- bind it again inside run_tool_call_as_role; setting it here is harmless.
  PERFORM set_config('attobot.current_agent_id', v_agent_id::text, true);

  IF p_acting_role IS NULL OR p_acting_role = '' THEN
    p_acting_role := 'attobot_agent_primary';
  END IF;

  -- start every tool call as its own instance (all started before any awaiting)
  FOR v_call IN SELECT value FROM jsonb_array_elements(coalesce(p_tool_calls, '[]'::jsonb))
  LOOP
    v_tool_call_id := coalesce(v_call->>'id', 'call_' || md5(v_call::text));
    v_name := v_call #>> '{function,name}';
    v_args := attobot._try_jsonb(v_call #>> '{function,arguments}');
    v_future := attotools.tool_call_future(
      v_name, v_args, p_acting_role, v_agent_id, p_agent_slug,
      p_user_external_id, p_chat_id, p_user_id
    );
    SELECT df.start(v_future, format('attobot:tool:%s:%s', p_message_id, v_tool_call_id)) INTO v_tc;
    v_started := v_started || jsonb_build_array(
      jsonb_build_object('id', v_tc, 'tc_id', v_tool_call_id)
    );
  END LOOP;

  RETURN v_started::text;
END;
$$;

-- Strip pg_durable's df.result() envelope to recover a tool call's own result
-- text. Each tool call runs as a one-node graph whose body is
-- `SELECT attotools.run_tool_call_as_role(...)::text AS result`, and df.result()
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
CREATE OR REPLACE FUNCTION attotools._unwrap_tool_result(p_result text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(attobot._try_jsonb(p_result) #>> '{rows,0,result}', p_result)
$$;

CREATE OR REPLACE FUNCTION attotools.await_tool_calls(
  p_agent_slug text,
  p_started text,
  p_timeout integer DEFAULT 120
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = attobot, attotools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := attobot.agent_id(p_agent_slug);
  v_item jsonb;
  v_id text;
  v_tcid text;
  v_status text;
  v_result text;
  v_count integer := 0;
BEGIN
  FOR v_item IN SELECT value FROM jsonb_array_elements(
    coalesce(attobot._try_jsonb(p_started), '[]'::jsonb)
  )
  LOOP
    v_count := v_count + 1;
    v_id := v_item->>'id';
    v_tcid := v_item->>'tc_id';

    -- Block in C until the tool instance terminates or p_timeout elapses.
    -- wait_for_completion returns the terminal status ('completed'/'failed'/
    -- 'cancelled') directly. It RAISES on: inside-workflow, timeout<=0,
    -- instance-not-found, or timeout-exceeded-without-a-terminal-state — and
    -- only that last case leaves the tool still running, so only it needs
    -- cancelling (the others are not cancellable or misuse). The tool instances
    -- are already df.started in parallel by start_tool_calls, so awaiting them
    -- in order still resolves in ~max(duration).
    BEGIN
      SELECT df.wait_for_completion(v_id, p_timeout) INTO v_status;
    EXCEPTION WHEN OTHERS THEN
      -- Raised: single out the timeout case. df.status still running/pending ⇒
      -- the wait timed out with the instance alive ⇒ cancel; df.status raising
      -- ⇒ not-found (nothing to cancel) ⇒ 'error'.
      BEGIN
        SELECT df.status(v_id) INTO v_status;
      EXCEPTION WHEN OTHERS THEN
        v_status := NULL;
      END;
      IF v_status IN ('running', 'pending') THEN
        BEGIN
          PERFORM df.cancel(v_id, 'tool call timeout');
        EXCEPTION WHEN OTHERS THEN
          NULL;
        END;
        v_status := 'cancelled';
      ELSE
        v_status := 'error';
      END IF;
    END;

    BEGIN
      SELECT df.result(v_id) INTO v_result;
      v_result := attotools._unwrap_tool_result(v_result);
    EXCEPTION WHEN OTHERS THEN
      v_result := 'error: ' || SQLERRM;
    END;
    IF v_status <> 'completed' THEN
      v_result := coalesce(v_result, 'error: tool ' || v_status);
    END IF;

    PERFORM attotools._append_tool_message(v_agent_id, v_tcid, v_result);
  END LOOP;

  RETURN jsonb_build_object('tool_calls', v_count)::text;
END;
$$;
