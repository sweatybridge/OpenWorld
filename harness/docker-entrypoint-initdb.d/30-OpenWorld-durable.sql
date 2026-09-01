-- ============================================================================
-- Trigger-driven agent loop
--   Primary: an AFTER INSERT STATEMENT trigger on ow.messages starts a
--   bounded df.loop whenever a role='user' row for the primary agent lands.
--   Each iteration: resolve pending attachment (if any) → compose → LLM http →
--   record assistant → run tool calls as per-call instances under the acting
--   role → loop until no tool calls or max_turn. Outbound delivery is a
--   separate row-level trigger (below).
--
--   Inbound photo/video attachments are resolved INLINE as the first nodes of
--   the loop body: getFile (df.http) → resolve_inbound_attachment (ffmpeg.hls +
--   store playlist_id). No separate download instance is df.start-ed; the loop
--   starts immediately on the trigger message (no deferral).
-- ============================================================================

CREATE OR REPLACE FUNCTION ow.start_agent_loop(
  p_agent_slug text,
  p_trigger_message_id bigint,
  p_requesting_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  -- Embed the trigger message id so a turn can be traced across workflows by a
  -- single correlation key (tool/send/typing instances already key on a message
  -- id; now the loop does too). See ow.trace_turn / ow.instance_index.
  v_label text := format('ow:%s:loop:%s', p_agent_slug, coalesce(p_trigger_message_id::text, '0'));
  v_existing text;
  v_max_turn integer;
  v_acting_role text;
  v_ext_id text;
  v_user_id text;
  v_channel text;
  v_chat_id text;
  v_body text;
  v_cond text;
  v_instance text;
BEGIN
  -- gate: a single loop per agent at a time (a running loop reads recent
  -- history, so it absorbs messages that arrive mid-turn). The loop label is now
  -- per-trigger (ow:<slug>:loop:<msg_id>), so prefix-match any running loop
  -- for this agent instead of comparing the full per-trigger label for equality.
  SELECT id INTO v_existing
    FROM df.instances
    WHERE label LIKE format('ow:%s:loop:%%', p_agent_slug)
      AND status IN ('pending', 'running')
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT max_turn INTO v_max_turn FROM ow.agents WHERE id = v_agent_id;

  -- SECURITY INVOKER: this runs as the entry-starter's owner (ow_agent_primary
  -- via the inbox/user-message trigger, ow_agent_sidecar via the cron
  -- loop). Bind the agent GUC for this session so the agent-scoped reads below
  -- resolve under RLS (no service bypass anymore).
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);

  -- acting role + user context. Primary user turns drop tool calls to the
  -- requesting user's tier; sidecar (no requesting user) drops to
  -- ow_service (broad, secret-free) so it can review any agent; otherwise
  -- tools run at the agent's own role.
  IF p_requesting_user_id IS NOT NULL THEN
    SELECT 'ow_' || u.tier, u.external_id, u.id::text
      INTO v_acting_role, v_ext_id, v_user_id
      FROM ow.users u WHERE u.id = p_requesting_user_id;
    v_channel := 'telegram';
    SELECT chat_id INTO v_chat_id FROM ow.messages WHERE id = p_trigger_message_id;
  ELSIF p_agent_slug = 'sidecar' THEN
    v_acting_role := 'ow_service';
  ELSE
    v_acting_role := 'ow_agent_' || p_agent_slug;
  END IF;

  -- Loop body: resolve pending attachment → compose → LLM → record → tools.
  -- The resolve prefix (3 nodes) runs on every iteration but is a no-op once
  -- the attachment is resolved: prepare_inbound_getfile returns '{}' when
  -- there is no pending attachment, getFile gets an expected 400, and
  -- resolve_inbound_attachment skips without touching the response. The cost
  -- is one trivial HTTP call per iteration — negligible vs the LLM call that
  -- follows.
  v_body :=
    format('SELECT ow.prepare_inbound_getfile(%L, %s)::text AS gf_req', p_agent_slug, p_trigger_message_id) |=> 'gf_req'
    ~> df.http(ow._telegram_api_url(p_agent_slug, 'getFile'), 'POST', '$gf_req',
               ow._telegram_headers(), 30) |=> 'gf_resp'
    ~> format('SELECT ow.resolve_inbound_attachment(%L, %s, $gf_resp::jsonb)::text AS resolved', p_agent_slug, p_trigger_message_id) |=> 'resolved'
    ~> format('SELECT ow.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
    ~> df.http(ow._llm_url(p_agent_slug), 'POST', '$request',
               ow._llm_headers(p_agent_slug), 120) |=> 'response'
    ~> df.if(
         'SELECT $response.ok',
         format('SELECT ow.record_assistant(%L, $response::jsonb, %s, %L, %L)::jsonb AS assistant',
                p_agent_slug, coalesce(p_requesting_user_id::text, 'NULL'), v_channel, v_chat_id),
         format('SELECT ow.append_message(%L, ''system'', format(''[llm http error %%s]'', ow._http_status($response::jsonb)))::text AS e',
                p_agent_slug)
           ~> df.break('llm_error')
       ) |=> 'assistant'
    ~> df.if(
         'SELECT coalesce(jsonb_array_length(($assistant::jsonb)->''tool_calls''), 0) > 0',
         format('SELECT ow_tools.start_tool_calls(%L, (($assistant::jsonb)->>''message_id'')::bigint, ($assistant::jsonb)->''tool_calls'', %L, %L, %L, %s)::text AS started',
                p_agent_slug, v_acting_role, coalesce(v_ext_id, ''), coalesce(v_chat_id, ''), coalesce(v_user_id, 'NULL'))
           |=> 'started'
           ~> format('SELECT ow_tools.await_tool_calls(%L, $started)::text AS tools', p_agent_slug),
         df.break('done')
       );

  -- The loop condition runs as its own statement in the instance, so bind the
  -- agent GUC inline (FROM is evaluated before WHERE) before the messages count.
  v_cond := format(
    'SELECT (SELECT count(*) FROM ow.messages CROSS JOIN (SELECT set_config(''ow.current_agent_id'', %L, true)) AS cfg WHERE agent_id = %s AND role = ''assistant'' AND id > %s) < coalesce((SELECT max_turn FROM ow.agents WHERE id = %s), 1)',
    v_agent_id::text, v_agent_id, p_trigger_message_id, v_agent_id
  );

  SELECT df.start(df.loop(v_body, v_cond), v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- AFTER INSERT STATEMENT trigger: start the primary loop when user messages land.
-- Inbound photo/video attachments are resolved inline as the first nodes of the
-- loop body (see start_agent_loop), so there is no deferral: the trigger starts
-- the loop immediately.
CREATE OR REPLACE FUNCTION ow.after_user_message_loop()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_primary_id bigint;
  v_trigger_id bigint;
  v_from_id text;
  v_req_user_id bigint;
  v_chat_id text;
BEGIN
  SELECT id INTO v_primary_id FROM ow.agents WHERE slug = 'primary';
  IF v_primary_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM new_rows WHERE role = 'user' AND agent_id = v_primary_id
  ) THEN
    RETURN NULL;
  END IF;

  SELECT id, chat_id, payload #>> '{telegram_update,message,from,id}'
    INTO v_trigger_id, v_chat_id, v_from_id
    FROM new_rows
    WHERE role = 'user' AND agent_id = v_primary_id
    ORDER BY id DESC LIMIT 1;

  IF v_from_id IS NOT NULL THEN
    SELECT id INTO v_req_user_id FROM ow.users
      WHERE channel = 'telegram' AND external_id = v_from_id;
    -- Show a typing indicator in the originating chat while the agent loop runs.
    -- Fire-and-forget before start_agent_loop: the indicator auto-expires (~5s)
    -- and is cleared once the loop's reply is delivered by the outbound send
    -- trigger, so there is no reset step.
    PERFORM df.start(
      ow.send_chat_action_future('primary', v_chat_id, 'typing'),
      format('ow:typing:%s', v_trigger_id)
    );
  END IF;

  PERFORM ow.start_agent_loop('primary', v_trigger_id, v_req_user_id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_user_loop_trigger
AFTER INSERT ON ow.messages
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION ow.after_user_message_loop();

-- ============================================================================
-- Outbound delivery trigger (replaces the outbox)
--   role in ('assistant','system') + channel='telegram' → df.start a send
-- ============================================================================

CREATE OR REPLACE FUNCTION ow.after_outbound_message_send()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_slug text;
BEGIN
  -- send_message_future takes the slug and self-binds the agent GUC, so the
  -- trigger no longer needs to bind it (the prior is_local bind never reached
  -- the send instance's own transaction anyway). Resolve the owning agent's slug.
  SELECT slug INTO v_slug FROM ow.agents WHERE id = NEW.agent_id;
  PERFORM df.start(ow.send_message_future(v_slug, NEW.id), format('ow:send:%s', NEW.id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_outbound_send_trigger
AFTER INSERT ON ow.messages
FOR EACH ROW
WHEN (NEW.role IN ('assistant', 'system') AND NEW.channel = 'telegram'
      AND (coalesce(NEW.content, '') <> ''
           OR NEW.payload ? 'attachment'
           OR (NEW.payload ? 'tool_calls'
               AND jsonb_typeof(NEW.payload->'tool_calls') = 'array'
               AND jsonb_array_length(NEW.payload->'tool_calls') > 0)))
EXECUTE FUNCTION ow.after_outbound_message_send();

-- ============================================================================
-- Inbound long-poll loop (Telegram getUpdates → poll_messages → trigger)
-- ============================================================================

CREATE OR REPLACE FUNCTION ow.ensure_telegram_inbox_loop(
  p_agent_slug text DEFAULT 'primary',
  p_timeout integer DEFAULT 60
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_label text := format('ow:%s:inbox', p_agent_slug);
  v_existing text;
  v_future text;
  v_instance text;
BEGIN
  SELECT id INTO v_existing
    FROM df.instances WHERE label = v_label AND status IN ('pending', 'running') LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- Bind the agent GUC before any agent-scoped config read. This function is
  -- SECURITY DEFINER owned by the agent role, so RLS on ow.config binds us
  -- (config_agent_read_own requires current_agent_id) — same requirement as
  -- poll_messages. Without this the init-time call can't see telegram_token.
  PERFORM set_config('ow.current_agent_id', ow.agent_id(p_agent_slug)::text, true);

  v_future := df.loop(
    format('SELECT ow.telegram_get_updates_body(%L, %s)::text AS body', p_agent_slug, p_timeout) |=> 'req'
    ~> df.http(ow._telegram_api_url(p_agent_slug, 'getUpdates'), 'POST', '$req',
               ow._telegram_headers(), p_timeout + 5) |=> 'resp'
    ~> format('SELECT ow.poll_messages(%L, $resp::jsonb)::jsonb AS result', p_agent_slug) |=> 'poll'
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- ============================================================================
-- Inbound attachment resolution (photo/video): inline nodes in the agent loop.
--
-- The agent loop body starts with three nodes that resolve any pending
-- attachment on the trigger message:
--   1. prepare_inbound_getfile  — SQL: read the trigger message's file_id
--      and build the getFile request body (or '{}' when no attachment is
--      pending, in which case the next two nodes are a harmless no-op).
--   2. df.http(getFile)          — HTTP: call Telegram getFile.
--   3. resolve_inbound_attachment — SQL: extract file_path from the response,
--      build the file URL, ingest via ffmpeg.hls (stores HLS segments), and
--      write playlist_id onto the message row. On failure (getFile error or
--      ffmpeg.hls raises) the fail note is written in-place; the loop
--      continues to compose_llm_request regardless.
--
-- No separate download instance is df.start-ed; the loop starts immediately on
-- the trigger message (no deferral).
-- ============================================================================

-- Read the trigger message's pending attachment and return the getFile request
-- body. When the message has no pending attachment (or is not a media
-- message at all), return '{}' — the subsequent df.http(getFile) call will
-- get an expected 400 from Telegram, and resolve_inbound_attachment ignores
-- the response. Self-binds the agent GUC for RLS.
CREATE OR REPLACE FUNCTION ow.prepare_inbound_getfile(
  p_agent_slug text,
  p_trigger_message_id bigint
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_file_id text;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  SELECT payload->'attachment_meta'->>'file_id'
    INTO v_file_id
    FROM ow.messages
    WHERE id = p_trigger_message_id AND agent_id = v_agent_id
      AND payload->>'attachment_pending' = 'true';
  IF v_file_id IS NULL OR v_file_id = '' THEN
    RETURN '{}';
  END IF;
  RETURN jsonb_build_object('file_id', v_file_id)::text;
END;
$$;

-- Resolve the pending attachment using the getFile HTTP response. Extracts
-- file_path, builds the file URL, ingests via ffmpeg.hls, and writes
-- playlist_id onto the message row. On any failure (getFile error, no
-- file_path, ffmpeg.hls raises) the fail note is written in-place and the
-- function returns ok=false — but it NEVER RAISES, so the loop continues to
-- compose_llm_request regardless. When the trigger message has no pending
-- attachment, the function is a no-op (returns ok=true, skipped=true).
-- Self-binds the agent GUC for RLS.
CREATE OR REPLACE FUNCTION ow.resolve_inbound_attachment(
  p_agent_slug text,
  p_trigger_message_id bigint,
  p_getfile_response jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_pending boolean;
  v_meta jsonb;
  v_file_path text;
  v_file_url text;
  v_status integer;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);

  SELECT coalesce((payload->>'attachment_pending')::boolean, false),
         payload->'attachment_meta'
    INTO v_pending, v_meta
    FROM ow.messages
    WHERE id = p_trigger_message_id AND agent_id = v_agent_id;

  -- No pending attachment (text-only message, or already resolved in a
  -- prior iteration): the getFile call was a wasted no-op with an expected
  -- 400 — ignore it entirely.
  IF NOT v_pending THEN
    RETURN jsonb_build_object('ok', true, 'skipped', true)::text;
  END IF;

  -- getFile failed (non-2xx, ok:false, or missing file_path)
  v_status := ow._http_status(p_getfile_response);
  IF v_status < 200 OR v_status >= 300
     OR coalesce((ow._http_body_json(p_getfile_response)->>'ok')::boolean, false) IS NOT TRUE THEN
    PERFORM ow.fail_inbound_attachment(p_agent_slug, p_trigger_message_id, 'getFile failed');
    RETURN jsonb_build_object('ok', false, 'reason', 'getFile failed')::text;
  END IF;

  v_file_path := ow._http_body_json(p_getfile_response) #>> '{result,file_path}';
  IF v_file_path IS NULL OR v_file_path = '' THEN
    PERFORM ow.fail_inbound_attachment(p_agent_slug, p_trigger_message_id, 'getFile returned no file_path');
    RETURN jsonb_build_object('ok', false, 'reason', 'no file_path')::text;
  END IF;

  v_file_url := ow._telegram_file_url(p_agent_slug) || v_file_path;

  -- Ingest via ffmpeg.hls (fetches the URL itself, stores HLS segments).
  -- store_inbound_attachment handles the update + exception path.
  RETURN ow.store_inbound_attachment(p_agent_slug, p_trigger_message_id, v_meta, v_file_url, 2.0);
END;
$$;

-- Store the inbound attachment by ingesting file_url with ffmpeg.hls. The
-- network/decode call is folded in here: on success the message row carries
-- only a small playlist_id reference; on failure the fail note is written
-- in-place. NEVER RAISES: a raised node would roll back the un-blocking
-- UPDATE, and a stuck-pending message is worse than a lost file (the content
-- note is the visibility).
--
-- pg_ffmpeg v0.3.5+ is required: for still-image inputs (photos), hls() stores
-- the original image bytes as one segment (bypassing the mpegts muxer that
-- previously emitted opaque bin_data with no decodeable frame), so
-- ffmpeg.thumbnail works on both photo and video segments.
CREATE OR REPLACE FUNCTION ow.store_inbound_attachment(
  p_agent_slug text,
  p_message_id bigint,
  p_meta jsonb,
  p_file_url text,
  p_segment_duration float DEFAULT 2.0
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_playlist_id bigint;
  v_seg_int integer;
  v_mime text;
  v_attachment jsonb;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  v_seg_int := greatest(coalesce(p_segment_duration::integer, 1), 1);

  BEGIN
    v_playlist_id := ffmpeg.hls(p_file_url, v_seg_int);
  EXCEPTION WHEN OTHERS THEN
    -- fold the failure into the message row instead of failing the instance
    PERFORM ow.fail_inbound_attachment(p_agent_slug, p_message_id,
      'ffmpeg.hls: ' || SQLERRM);
    RETURN jsonb_build_object('ok', false, 'reason', SQLERRM)::text;
  END;

  v_mime := coalesce(p_meta->>'mime_type', CASE p_meta->>'kind'
                       WHEN 'photo' THEN 'image/jpeg'
                       WHEN 'video' THEN 'video/mp4'
                       ELSE 'application/octet-stream' END);

  v_attachment := jsonb_strip_nulls(jsonb_build_object(
    'kind', p_meta->>'kind',
    'playlist_id', v_playlist_id,
    'mime_type', v_mime,
    'filename', p_meta->>'filename',
    'file_size', nullif(p_meta->>'file_size', '')::integer,
    'width', nullif(p_meta->>'width', '')::integer,
    'height', nullif(p_meta->>'height', '')::integer,
    'duration', nullif(p_meta->>'duration', '')::integer
  ));

  UPDATE ow.messages
    SET payload = (payload - 'attachment_pending') || jsonb_build_object('attachment', v_attachment)
    WHERE id = p_message_id AND agent_id = v_agent_id;

  RETURN jsonb_build_object('ok', true, 'playlist_id', v_playlist_id)::text;
END;
$$;

-- Mark the inbound attachment as failed: clear attachment_pending and append a
-- note to content (the visibility for a lost file). Used by the getFile-failed
-- path (download_inbound_file_future's else branch) and as the in-place
-- fallback inside store_inbound_attachment.
CREATE OR REPLACE FUNCTION ow.fail_inbound_attachment(
  p_agent_slug text,
  p_message_id bigint,
  p_reason text
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  UPDATE ow.messages
    SET payload = payload - 'attachment_pending',
        content = content || format(' [attachment download failed: %s]', p_reason)
    WHERE id = p_message_id AND agent_id = v_agent_id;
  RETURN jsonb_build_object('ok', false, 'reason', p_reason)::text;
END;
$$;

-- ============================================================================
-- Optional live camera ingest (per agent): hls_live + bounded segment retention
--
-- hls_live is a top-level procedure that holds one backend connection open and
-- commits every completed segment. A parallel infinite branch periodically
-- prunes old segments. df.race ties their lifetimes together: a graceful
-- hls_live_stop completes the CALL and cancels the pruning branch.
-- ============================================================================

-- source_url is pg_ffmpeg's stream identity. Keep it exclusive to one agent so
-- changing an agent's own config cannot be used to claim another agent's live
-- playlist through the ffmpeg RLS policies below.
CREATE UNIQUE INDEX IF NOT EXISTS config_camera_feed_url_unique
  ON ow.config ((value #>> '{}'))
  WHERE key = 'camera_feed_url';

-- RLS policies on the extension-owned ffmpeg tables call this SECURITY DEFINER
-- predicate so they can resolve role ownership without depending on the
-- transaction-local agent GUC (hls_live commits between segments). It returns
-- only a boolean; the configured secret URL is never exposed by this helper.
CREATE OR REPLACE FUNCTION ow._camera_role_owns_url(
  p_role text,
  p_url text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ow, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM ow.agents a
      JOIN ow.config c ON c.agent_id = a.id
     WHERE p_role = 'ow_agent_' || a.slug
       AND c.key = 'camera_feed_url'
       AND c.value #>> '{}' = p_url
  );
$$;

-- Bind camera operations to the calling agent role. Besides protecting each
-- agent's secret URL, this ensures a retention loop can only resolve and prune
-- the stream configured by the agent that submitted it.
CREATE OR REPLACE FUNCTION ow._camera_agent_id(p_agent_slug text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, public, pg_temp
AS $$
DECLARE
  v_expected_role text := 'ow_agent_' || p_agent_slug;
  v_agent_id bigint;
BEGIN
  IF current_user::text IS DISTINCT FROM v_expected_role THEN
    RAISE EXCEPTION 'camera ingest for agent % must run as role %',
      p_agent_slug, v_expected_role;
  END IF;

  v_agent_id := ow.agent_id(p_agent_slug);
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  RETURN v_agent_id;
END;
$$;

-- Resolve the secret URL at execution time instead of embedding it in the
-- durable graph stored in df.nodes. hls_live itself records source_url in its
-- playlist table because the URL is the extension's stable stream key.
CREATE OR REPLACE FUNCTION ow._camera_feed_url(p_agent_slug text DEFAULT 'primary')
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint;
  v_url text;
BEGIN
  v_agent_id := ow._camera_agent_id(p_agent_slug);
  v_url := ow._config_text(v_agent_id, 'camera_feed_url');
  IF v_url IS NULL OR btrim(v_url) = '' THEN
    RAISE EXCEPTION 'camera feed is not configured for agent %', p_agent_slug;
  END IF;
  RETURN v_url;
END;
$$;

CREATE OR REPLACE FUNCTION ow.prune_camera_feed(
  p_agent_slug text DEFAULT 'primary',
  p_retention_segments integer DEFAULT 300
)
RETURNS integer
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_url text;
  v_deleted integer;
BEGIN
  IF p_retention_segments IS NULL OR p_retention_segments <= 0 THEN
    RAISE EXCEPTION 'camera retention_segments must be greater than 0';
  END IF;

  v_url := ow._camera_feed_url(p_agent_slug);
  WITH live_playlist AS (
    SELECT p.id,
           (SELECT max(s.segment_index)
              FROM ffmpeg.hls_segments s
             WHERE s.playlist_id = p.id) AS max_segment_index
      FROM ffmpeg.hls_playlists p
     WHERE p.source_url = v_url
  )
  DELETE FROM ffmpeg.hls_segments s
   USING live_playlist p
   WHERE s.playlist_id = p.id
     AND s.segment_index <= p.max_segment_index - p_retention_segments;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

CREATE OR REPLACE FUNCTION ow.ensure_camera_ingest_loop(
  p_agent_slug text,
  p_url text,
  p_segment_duration integer DEFAULT 2,
  p_stall_timeout double precision DEFAULT 10.0,
  p_retention_segments integer DEFAULT 300
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint;
  v_label text := format('ow:%s:camera', p_agent_slug);
  v_existing text;
  v_existing_url text;
  v_ingest text;
  v_prune text;
  v_instance text;
BEGIN
  v_agent_id := ow._camera_agent_id(p_agent_slug);
  IF p_url IS NULL OR btrim(p_url) = '' THEN
    RAISE EXCEPTION 'camera feed URL must not be empty';
  END IF;
  IF p_segment_duration IS NULL OR p_segment_duration <= 0 THEN
    RAISE EXCEPTION 'camera segment_duration must be greater than 0';
  END IF;
  IF p_stall_timeout IS NULL
     OR p_stall_timeout::text IN ('NaN', 'Infinity', '-Infinity')
     OR p_stall_timeout <= 0 THEN
    RAISE EXCEPTION 'camera stall_timeout must be finite and greater than 0';
  END IF;
  IF p_retention_segments IS NULL OR p_retention_segments <= 0 THEN
    RAISE EXCEPTION 'camera retention_segments must be greater than 0';
  END IF;

  -- Serialize start/stop for this agent. If disablement races with a start,
  -- stop waits until df.start has recorded the instance and then cancels it.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_label, 0));

  SELECT id INTO v_existing
    FROM df.instances
    WHERE label = v_label AND status IN ('pending', 'running')
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    v_existing_url := ow._config_text(v_agent_id, 'camera_feed_url');
    IF v_existing_url IS DISTINCT FROM p_url
       OR coalesce(ow._config_text(v_agent_id, 'camera_segment_duration'), '2')::integer
            IS DISTINCT FROM p_segment_duration
       OR coalesce(ow._config_text(v_agent_id, 'camera_stall_timeout'), '10')::double precision
            IS DISTINCT FROM p_stall_timeout
       OR coalesce(ow._config_text(v_agent_id, 'camera_retention_segments'), '300')::integer
            IS DISTINCT FROM p_retention_segments THEN
      RAISE EXCEPTION
        'camera ingest is already running for agent %; stop it before changing camera settings',
        p_agent_slug;
    END IF;
    RETURN v_existing;
  END IF;

  PERFORM ow.set_config(p_agent_slug, 'camera_feed_url', to_jsonb(p_url), true);
  PERFORM ow.set_config(p_agent_slug, 'camera_segment_duration', to_jsonb(p_segment_duration));
  PERFORM ow.set_config(p_agent_slug, 'camera_stall_timeout', to_jsonb(p_stall_timeout));
  PERFORM ow.set_config(p_agent_slug, 'camera_retention_segments', to_jsonb(p_retention_segments));

  -- CALL remains the top-level SQL statement inside its activity connection,
  -- which is required for hls_live's per-segment COMMIT AND CHAIN behavior.
  v_ingest := format(
    'CALL ffmpeg.hls_live(ow._camera_feed_url(%L), %s, %s)',
    p_agent_slug, p_segment_duration, p_stall_timeout
  );
  v_prune := df.loop(
    format('SELECT ow.prune_camera_feed(%L, %s)::text AS deleted',
           p_agent_slug, p_retention_segments)
    ~> df.sleep(greatest(p_segment_duration, 1))
  );

  SELECT df.start(df.race(v_ingest, v_prune), v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

CREATE OR REPLACE FUNCTION ow.stop_camera_ingest_loop(
  p_agent_slug text DEFAULT 'primary'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint;
  v_label text := format('ow:%s:camera', p_agent_slug);
  v_instance_id text;
  v_url text;
  v_stop_requested boolean := false;
  v_cancelled boolean := false;
BEGIN
  v_agent_id := ow._camera_agent_id(p_agent_slug);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_label, 0));

  v_url := ow._config_text(v_agent_id, 'camera_feed_url');
  IF v_url IS NOT NULL
     AND btrim(v_url) <> ''
     AND EXISTS (
       SELECT 1
         FROM ffmpeg.hls_playlists
        WHERE source_url = v_url
     ) THEN
    v_stop_requested := ffmpeg.hls_live_stop(v_url);
  END IF;

  -- The playlist row does not exist until hls_live claims the source, and a
  -- retry resets its stop flag. Cancel the owning durable workflow as the
  -- persistent stop signal so pending/retrying ingest cannot start later.
  FOR v_instance_id IN
    SELECT id
      FROM df.instances
     WHERE label = v_label
       AND status IN ('pending', 'running')
  LOOP
    PERFORM df.cancel(v_instance_id, 'camera ingest stopped');
    v_cancelled := true;
  END LOOP;

  RETURN v_stop_requested OR v_cancelled;
END;
$$;

-- ============================================================================
-- Cron-driven agent loop (sidecar): on schedule, append a system prompt
-- and start that agent's loop (tools run as the agent's own role)
-- ============================================================================

CREATE OR REPLACE FUNCTION ow.ensure_agent_cron_loop(
  p_agent_slug text DEFAULT 'sidecar',
  p_name text DEFAULT 'review',
  p_cron text DEFAULT '*/10 * * * *',
  p_message text DEFAULT 'review agent streams for actionable memory corrections'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_label text := format('ow:%s:cron:%s', p_agent_slug, p_name);
  v_existing text;
  v_future text;
  v_instance text;
BEGIN
  SELECT id INTO v_existing
    FROM df.instances WHERE label = v_label AND status IN ('pending', 'running') LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  v_future := df.loop(
    df.wait_for_schedule(p_cron)
    ~> format('SELECT ow.append_message(%L, ''system'', %L)::bigint AS m',
              p_agent_slug, format('[schedule %s] %s', p_name, p_message)) |=> 'm'
    ~> format('SELECT ow.start_agent_loop(%L, $m, NULL)::text AS loop_id', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;
