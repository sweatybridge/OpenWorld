-- ============================================================================
-- Trigger-driven agent loop
--   Primary: an AFTER INSERT STATEMENT trigger on ow.messages starts a
--   bounded df.loop whenever a role='user' row for the primary agent lands.
--   Each iteration: compose → LLM http → record assistant → run tool calls as
--   per-call instances under the acting role → loop until no tool calls or
--   max_turn. Outbound delivery is a separate row-level trigger (below).
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

  v_body :=
    format('SELECT ow.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
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
-- A user row whose payload.attachment_pending is true carries an inbound photo/
-- video whose download instance has not yet written its playlist_id; the loop
-- is deferred until ow.start_agent_loop is fired from the download instance's
-- terminal node (see ow.store_inbound_attachment / ow.fail_inbound_attachment).
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
  v_pending boolean;
BEGIN
  SELECT id INTO v_primary_id FROM ow.agents WHERE slug = 'primary';
  IF v_primary_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM new_rows WHERE role = 'user' AND agent_id = v_primary_id
  ) THEN
    RETURN NULL;
  END IF;

  SELECT id, chat_id, payload #>> '{telegram_update,message,from,id}',
         coalesce((payload->>'attachment_pending')::boolean, false)
    INTO v_trigger_id, v_chat_id, v_from_id, v_pending
    FROM new_rows
    WHERE role = 'user' AND agent_id = v_primary_id
    ORDER BY id DESC LIMIT 1;

  -- Defer the loop while an attachment is pending. The download instance
  -- (ow:download:<msg_id>) starts the loop when the playlist_id (or the
  -- failure note) is written. A mixed batch (text + photo/video) defers as
  -- one unit — the text waits ~1–2 s for the media, which is the desired
  -- behaviour anyway. No typing indicator either: the photo has not landed.
  IF v_pending THEN
    RETURN NULL;
  END IF;

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
    ~> format('SELECT ow.start_inbound_downloads(%L, $poll::jsonb)::text AS downloads', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- ============================================================================
-- Inbound attachment download (photo/video): one durable instance per file.
--
-- The poll stays a single node (ow.poll_messages); each accepted photo/video
-- becomes an ow:download:<msg_id> one-shot instance started by
-- ow.start_inbound_downloads. The instance resolves file_id → file_path via
-- getFile, builds the file URL, and ingests it with ffmpeg.hls (which fetches
-- the URL itself and stores HLS segments durably in ffmpeg.hls_*). The message
-- row only ever holds the small playlist_id reference; the agent loop is
-- deferred until that reference (or the failure note) is written.
-- ============================================================================

-- Build the per-file download graph. The fetched file is ingested directly by
-- ffmpeg.hls (no df.http GET node, no bytes on ow.messages); the message row
-- only ever carries a playlist_id. Self-binds the agent GUC like
-- send_message_future so the getFile URL + RLS-bound reads resolve.
CREATE OR REPLACE FUNCTION ow.download_inbound_file_future(
  p_agent_slug text,
  p_message_id bigint,
  p_kind text,
  p_file_id text,
  p_meta jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, ffmpeg, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_getfile_url text;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  v_getfile_url := ow._telegram_api_url(p_agent_slug, 'getFile');

  RETURN df.http(v_getfile_url, 'POST',
           jsonb_build_object('file_id', p_file_id)::text,
           ow._telegram_headers(), 30) |=> 'meta'
    ~> df.if(
      'SELECT $meta.ok AND (ow._http_body_json($meta::jsonb)->>''ok'')::boolean',
      -- The node SQL runs in its own transaction, so the build-time GUC bind
      -- above does not carry over; bind the agent GUC inline (CROSS JOIN,
      -- evaluated before the _telegram_file_url read) so RLS on ow.config
      -- lets _telegram_file_url see the telegram_token row. Parenthesise the
      -- #>> extraction: || binds looser than #>>, so without parens the
      -- expression parses as (base || body) #>> path → text #>> unknown.
      format('SELECT ow._telegram_file_url(%L) || (ow._http_body_json($meta::jsonb) #>> ''{result,file_path}'') AS url FROM (SELECT set_config(''ow.current_agent_id'', %L, true)) AS cfg', p_agent_slug, v_agent_id::text) |=> 'url'
      ~> format(
           'SELECT ow.store_inbound_attachment(%L, %s, %L::jsonb, $url::text, 2.0)::text AS stored',
           p_agent_slug, p_message_id, p_meta::text
         )
      ~> format('SELECT ow.start_agent_loop(%L, %s)::text AS loop_id', p_agent_slug, p_message_id),
      format(
        'SELECT ow.fail_inbound_attachment(%L, %s, ''getFile failed'')::text AS failed',
        p_agent_slug, p_message_id
      )
      ~> format('SELECT ow.start_agent_loop(%L, %s)::text AS loop_id', p_agent_slug, p_message_id)
    );
END;
$$;

-- Start one ow:download:<msg_id> instance per accepted file in the poll result.
-- Runs as a node of the inbox loop (as ow_agent_primary, which holds
-- include_http); starts commit when the node ends, same as start_tool_calls.
-- Label gate: skip when an instance with the same label is already pending/
-- running/completed — the inbox loop node replays after a crash, and df.start
-- has no idempotency of its own. A failed instance may be re-started (retry).
CREATE OR REPLACE FUNCTION ow.start_inbound_downloads(
  p_agent_slug text,
  p_poll_result jsonb
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_item jsonb;
  v_update_id bigint;
  v_msg_id bigint;
  v_kind text;
  v_file_id text;
  v_meta jsonb;
  v_label text;
  v_existing text;
  v_started jsonb := '[]'::jsonb;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);

  FOR v_item IN SELECT value FROM jsonb_array_elements(
    coalesce(p_poll_result->'downloads', '[]'::jsonb))
  LOOP
    v_update_id := (v_item->>'update_id')::bigint;
    v_kind := v_item->>'kind';
    v_meta := v_item->'meta';
    v_file_id := v_meta->>'file_id';
    IF v_file_id IS NULL OR v_file_id = '' THEN
      CONTINUE;
    END IF;

    -- Resolve the message id via the telegram_update unique key (the row was
    -- just inserted by poll_messages in the same poll batch).
    SELECT m.id INTO v_msg_id
      FROM ow.messages m
      WHERE m.agent_id = v_agent_id
        AND (m.payload #>> '{telegram_update,update_id}') = v_update_id::text
      LIMIT 1;
    IF v_msg_id IS NULL THEN
      CONTINUE;
    END IF;

    v_label := format('ow:download:%s', v_msg_id);
    SELECT id INTO v_existing
      FROM df.instances
      WHERE label = v_label
        AND status IN ('pending', 'running', 'completed')
      LIMIT 1;
    IF v_existing IS NOT NULL THEN
      CONTINUE;
    END IF;

    PERFORM df.start(
      ow.download_inbound_file_future(p_agent_slug, v_msg_id, v_kind, v_file_id, v_meta),
      v_label
    );
    v_started := v_started || jsonb_build_array(jsonb_build_object('msg_id', v_msg_id, 'label', v_label));
  END LOOP;

  RETURN v_started::text;
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
