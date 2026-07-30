CREATE OR REPLACE FUNCTION ow.configure_telegram(
  p_agent_slug text,
  p_token text,
  p_chat_id text,
  p_thread_id text DEFAULT NULL,
  p_api_base text DEFAULT 'https://api.telegram.org'
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
BEGIN
  PERFORM ow.set_config(p_agent_slug, 'telegram_token', to_jsonb(p_token), true);
  PERFORM ow.set_config(p_agent_slug, 'telegram_chat_id', to_jsonb(p_chat_id));
  PERFORM ow.set_config(p_agent_slug, 'telegram_api_base', to_jsonb(p_api_base));
  PERFORM ow.set_config(p_agent_slug, 'telegram_update_offset', to_jsonb(0));

  IF p_thread_id IS NULL OR p_thread_id = '' THEN
    DELETE FROM ow.config
    WHERE agent_id = v_agent_id AND key = 'telegram_thread_id';
  ELSE
    PERFORM ow.set_config(p_agent_slug, 'telegram_thread_id', to_jsonb(p_thread_id));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ow._telegram_api_url(p_agent_slug text, p_method text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_token text;
  v_api_base text;
BEGIN
  v_token := ow._config_text(v_agent_id, 'telegram_token');
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'agent % has no telegram_token config', p_agent_slug;
  END IF;
  v_api_base := ow._config_text(v_agent_id, 'telegram_api_base', 'https://api.telegram.org');
  RETURN rtrim(v_api_base, '/') || '/bot' || v_token || '/' || p_method;
END;
$$;

CREATE OR REPLACE FUNCTION ow._telegram_headers()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  SELECT jsonb_build_object('Content-Type', 'application/json');
$$;

CREATE OR REPLACE FUNCTION ow.telegram_get_updates_body(p_agent_slug text, p_timeout integer)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_offset bigint;
BEGIN
  -- Bind the agent GUC before reading config: this runs as the agent role in the
  -- inbox loop, so RLS on ow.config binds us (config_agent_read_own requires
  -- current_agent_id). Without it the offset read returns NULL and falls back to
  -- 0 every cycle, re-fetching the same updates forever. Mirrors poll_messages
  -- (line 128 below). Mutating a session GUC is a side effect, so this is no
  -- longer STABLE.
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  v_offset := coalesce(ow._config_text(v_agent_id, 'telegram_update_offset', '0')::bigint, 0);
  RETURN jsonb_build_object(
    'offset', v_offset,
    'timeout', p_timeout,
    'allowed_updates', jsonb_build_array('message')
  );
END;
$$;

CREATE OR REPLACE FUNCTION ow._telegram_attachment_filename(
  p_filename text,
  p_kind text,
  p_msg_id bigint
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_ext text := CASE p_kind WHEN 'photo' THEN 'jpg' WHEN 'audio' THEN 'mp3' WHEN 'video' THEN 'mp4' ELSE 'bin' END;
  v_default text := 'attachment-' || coalesce(p_msg_id, 0) || '.' || v_ext;
  v_filename text := coalesce(nullif(btrim(p_filename), ''), v_default);
BEGIN
  v_filename := regexp_replace(v_filename, '[^A-Za-z0-9._-]+', '_', 'g');
  v_filename := left(v_filename, 160);
  IF v_filename = '' OR v_filename IN ('.', '..') THEN
    v_filename := v_default;
  END IF;
  IF left(v_filename, 1) = '.' THEN
    v_filename := 'attachment-' || coalesce(p_msg_id, 0) || v_filename;
  END IF;
  RETURN v_filename;
END;
$$;

-- Long-poll intake: parse Telegram getUpdates, track senders, and batch-insert
-- user messages (channel='telegram', chat_id set). The insert fires the
-- user→loop trigger; no explicit start_turn. Returns {accepted, ignored}.
CREATE OR REPLACE FUNCTION ow.poll_messages(
  p_agent_slug text,
  p_http_response jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_status integer;
  v_body jsonb;
  v_update jsonb;
  v_update_id bigint;
  v_max_update_id bigint := NULL;
  v_chat_id text;
  v_thread_id text;
  v_message jsonb;
  v_message_chat_id text;
  v_message_thread_id text;
  v_text text;
  v_from_id text;
  v_accepted jsonb := '[]'::jsonb;
  v_accepted_count integer := 0;
  v_ignored integer := 0;
BEGIN
  -- Bind the agent GUC (the inbox loop runs as the agent role, not
  -- service-bypass) before any agent-scoped config/message read.
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  v_chat_id := ow._config_text(v_agent_id, 'telegram_chat_id');
  v_thread_id := ow._config_text(v_agent_id, 'telegram_thread_id');

  v_status := ow._http_status(p_http_response);
  v_body := ow._http_body_json(p_http_response);

  IF v_status < 200 OR v_status >= 300 OR coalesce((v_body->>'ok')::boolean, false) IS NOT TRUE THEN
    RETURN jsonb_build_object('accepted', 0, 'ignored', 0, 'error', true);
  END IF;

  FOR v_update IN SELECT value FROM jsonb_array_elements(coalesce(v_body->'result', '[]'::jsonb))
  LOOP
    v_update_id := (v_update->>'update_id')::bigint;
    v_max_update_id := greatest(coalesce(v_max_update_id, v_update_id), v_update_id);
    v_message := v_update->'message';

    IF v_message IS NULL OR v_message = 'null'::jsonb THEN
      v_ignored := v_ignored + 1;
      CONTINUE;
    END IF;

    v_message_chat_id := v_message #>> '{chat,id}';
    v_message_thread_id := v_message->>'message_thread_id';
    v_text := coalesce(v_message->>'text', v_message->>'caption', '');

    IF v_message_chat_id IS DISTINCT FROM v_chat_id
       OR (v_thread_id IS NOT NULL AND v_message_thread_id IS DISTINCT FROM v_thread_id)
       OR v_text = '' THEN
      v_ignored := v_ignored + 1;
      CONTINUE;
    END IF;

    -- track the sender (channel-agnostic ledger)
    v_from_id := v_message #>> '{from,id}';
    IF v_from_id IS NOT NULL AND v_from_id <> '' THEN
      PERFORM ow.upsert_user(
        'telegram', v_from_id,
        v_message #>> '{from,username}',
        v_message #>> '{from,first_name}',
        v_message->'from'
      );
    END IF;

    v_accepted := v_accepted || jsonb_build_array(jsonb_build_object(
      'update_id', v_update_id,
      'text', v_text,
      'chat_id', v_message_chat_id,
      'update', v_update
    ));
    v_accepted_count := v_accepted_count + 1;
  END LOOP;

  -- batch insert (one statement → one user→loop trigger fire)
  IF v_accepted_count > 0 THEN
    INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
    SELECT v_agent_id, 'user',
           format('[telegram %s] %s', (e->>'update_id')::bigint, e->>'text'),
           jsonb_build_object('telegram_update', e->'update'),
           'telegram', e->>'chat_id'
    FROM jsonb_array_elements(v_accepted) AS e
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_max_update_id IS NOT NULL THEN
    PERFORM ow.set_config(p_agent_slug, 'telegram_update_offset', to_jsonb(v_max_update_id + 1));
  END IF;

  RETURN jsonb_build_object('accepted', v_accepted_count, 'ignored', v_ignored, 'error', false);
END;
$$;

-- Queue an outbound attachment by appending a system message (channel='telegram')
-- that the outbound trigger delivers. The media bytes (base64) and detected kind
-- ride in the payload; send_message reads them and routes to sendPhoto/
-- sendAudio/sendVideo/sendDocument. SECURITY DEFINER owner ow_agent_primary
-- so it works even when called from the anonymous acting role inside a tool call.
CREATE OR REPLACE FUNCTION ow.queue_outbound_attachment(
  p_agent_slug text,
  p_content_b64 text,
  p_kind text,
  p_filename text DEFAULT NULL,
  p_caption text DEFAULT NULL,
  p_mime_type text DEFAULT NULL,
  p_chat_id text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ow, ow_tools, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_id bigint;
BEGIN
  IF p_chat_id IS NULL OR p_chat_id = '' THEN
    p_chat_id := ow._config_text(v_agent_id, 'telegram_chat_id');
  END IF;

  INSERT INTO ow.messages(agent_id, role, content, payload, channel, chat_id)
  VALUES (
    v_agent_id, 'system', '',
    jsonb_build_object(
      'attachment', jsonb_strip_nulls(jsonb_build_object(
        'kind', coalesce(nullif(p_kind, ''), 'document'),
        'content', p_content_b64,
        'filename', nullif(p_filename, ''),
        'caption', nullif(p_caption, ''),
        'mime_type', nullif(p_mime_type, '')
      ))
    ),
    'telegram', p_chat_id
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Final node of the send graph (df.start-ed as ow:send:<msg_id> from the
-- outbound trigger). The request itself was already delivered upstream by the
-- graph: df.http (sendMessage) for a text reply, or df.http_multipart
-- (sendPhoto/sendAudio/sendVideo/sendDocument) for an attachment — p_http_response
-- carries either response, both shaped {status, body, headers, ok}.
--
-- On a Telegram API error (non-2xx, or ok:false in the body) it RAISEs, which
-- fails the send instance — pg_durable has no df.fail, so an unhandled exception
-- in a node is what marks the workflow failed. df.http / df.http_multipart treat a
-- 4xx response as success (not a failure), so a rejected send only surfaces here;
-- raising makes a failed send visible as a failed instance instead of a silent
-- completed one. (The text and attachment paths now share this one guard.)
--
-- Pure: it parses only p_http_response, so it needs no agent-scoped reads and no
-- GUC bind. p_agent_slug / p_message_id are kept in the signature for the graph
-- node call and the instance label.
CREATE OR REPLACE FUNCTION ow.send_message(
  p_agent_slug text,
  p_message_id bigint,
  p_http_response jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_status integer := 0;
BEGIN
  v_status := ow._http_status(p_http_response);
  -- The ok flag is checked too because Telegram errors carry ok:false even
  -- inside a 2xx envelope (df.http passes Telegram's JSON body through verbatim).
  IF v_status < 200 OR v_status >= 299
     OR coalesce((ow._http_body_json(p_http_response)->>'ok')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'telegram send failed: http_status=% body=%',
      v_status, left(coalesce(p_http_response->>'body', ''), 500);
  END IF;
  RETURN jsonb_build_object('sent', true, 'status', v_status);
END;
$$;

-- True when Telegram rejected a sendMessage because the MarkdownV2 text could
-- not be parsed ("Bad Request: can't parse entities: ..."). ow.telegramify
-- escapes every special char in plain text, so in practice only an
-- unfortunate 4096-char truncation can unbalance an entity; on exactly this
-- error the send graph retries the ORIGINAL text without parse_mode instead
-- of failing the send instance. Any other error (chat not found, blocked, too
-- long) is not a parse error and still fails the instance on the first
-- response. Pure: parses only p_http_response.
CREATE OR REPLACE FUNCTION ow._telegram_is_parse_error(p_http_response jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT ow._http_status(p_http_response) = 400
     AND coalesce(ow._http_body_json(p_http_response)->>'description', '')
         ILIKE '%can''t parse entities%';
$$;

-- Render an OpenAI tool_calls array as a compact, human-readable block so a
-- tool-call assistant turn can be delivered to Telegram (where the raw turn is
-- usually empty text). One line per call: "🔧 NAME(<arguments json>)", wrapped
-- in a fenced Markdown code block so the turn stands out from prose and the raw
-- JSON arguments render verbatim (Telegram's Markdown parser otherwise mangles
-- brackets/underscores/asterisks inside the args). Returns '' when there are
-- no calls or the input is not an array — an empty input is not wrapped, to
-- avoid emitting an empty code block.
CREATE OR REPLACE FUNCTION ow._render_tool_calls(p_tool_calls jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  WITH rendered AS (
    SELECT coalesce(string_agg(
      format('🔧 %s(%s)', tc -> 'function' ->> 'name', tc -> 'function' ->> 'arguments'),
      E'\n'
    ), '') AS body
    FROM jsonb_array_elements(
      CASE WHEN jsonb_typeof(p_tool_calls) = 'array' THEN p_tool_calls ELSE '[]'::jsonb END
    ) AS t(tc)
  )
  SELECT CASE WHEN body = '' THEN body ELSE E'```\n' || body || E'\n```' END
  FROM rendered;
$$;

-- ---------------------------------------------------------------------------
-- Markdown → Telegram MarkdownV2 conversion, modeled on telegramify-markdown
-- (https://github.com/skoropadas/telegramify-markdown). The LLM writes
-- CommonMark (**bold**, '#' headings, '-' bullets, fenced code blocks); the
-- send graph converts it here and posts with parse_mode=MarkdownV2, replacing
-- the legacy-Markdown attempt whose parser rejected unbalanced CommonMark
-- markers with "can't parse entities".
--
-- Mapping (telegramify defaults):
--   heading #..######   → *bold*
--   **b** / __b__       → *b*        (strong)
--   *i* / _i_           → _i_        (emphasis)
--   ~~s~~               → ~s~        (strikethrough)
--   - / * / + bullet    → • bullet   (ordered marker N. → N\.)
--   > quote             → > quote    (MarkdownV2 blockquote)
--   `code` / ```pre```  → verbatim; only \ and ` escaped inside
--   [text](url)         → [text](url); the url part escapes only \ ( )
--   ![alt](url)         → [alt](url)
--   every other MarkdownV2 special char in plain text (_ * [ ] ( ) ~ ` > # +
--   - = | { } . ! and \ itself) is backslash-escaped.
--
-- _telegramify_inline handles one line (no block constructs): code spans and
-- links are spliced out behind chr(1)..chr(2) placeholders so the escape and
-- formatting passes can't mangle them, then restored last. Both functions are
-- pure/IMMUTABLE so they are unit-testable (tests/pgtap/55_telegram.sql).
CREATE OR REPLACE FUNCTION ow._telegramify_inline(p_line text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_line text := p_line;
  v_keep text[] := '{}';
  v_m text[];
  v_pos integer;
  v_url text;
  v_text text;
  v_i integer;
BEGIN
  IF v_line IS NULL OR v_line = '' THEN
    RETURN v_line;
  END IF;

  -- inline code spans (``...`` first, then `...`): content verbatim (only \
  -- and ` escaped, MarkdownV2 code rule), parked behind a placeholder.
  LOOP
    v_pos := regexp_instr(v_line, '``(.+?)``');
    EXIT WHEN v_pos = 0;
    v_m := regexp_match(v_line, '``(.+?)``');
    v_keep := v_keep || ('`' || replace(regexp_replace(v_m[1], '\\', '\\\\', 'g'), '`', '\`') || '`');
    v_line := left(v_line, v_pos - 1) || chr(1) || array_length(v_keep, 1) || chr(2)
              || substr(v_line, v_pos + length(v_m[1]) + 4);
  END LOOP;
  LOOP
    v_pos := regexp_instr(v_line, '`([^`]+)`');
    EXIT WHEN v_pos = 0;
    v_m := regexp_match(v_line, '`([^`]+)`');
    v_keep := v_keep || ('`' || replace(regexp_replace(v_m[1], '\\', '\\\\', 'g'), '`', '\`') || '`');
    v_line := left(v_line, v_pos - 1) || chr(1) || array_length(v_keep, 1) || chr(2)
              || substr(v_line, v_pos + length(v_m[1]) + 2);
  END LOOP;

  -- images/links: [text](url) — the url may contain one level of balanced
  -- parens (wiki/…_(…)). Text is inline-formatted (recursion); the url keeps
  -- only \ ( ) escaped — over-escaping it would corrupt the destination.
  LOOP
    v_pos := regexp_instr(v_line, '!?\[[^\]]*\]\((?:[^()]|\([^()]*\))*\)');
    EXIT WHEN v_pos = 0;
    v_m := regexp_match(v_line, '(!?\[([^\]]*)\]\(((?:[^()]|\([^()]*\))*)\))');
    v_url := regexp_replace(coalesce(v_m[3], ''), '\\', '\\\\', 'g');
    v_url := replace(replace(v_url, '(', '\('), ')', '\)');
    v_text := ow._telegramify_inline(coalesce(v_m[2], ''));
    IF v_text = '' THEN
      v_text := ow._telegramify_inline(coalesce(v_m[3], ''));
    END IF;
    IF v_text = '' AND v_url = '' THEN
      v_keep := v_keep || ''; -- []() carries nothing; drop it
    ELSE
      v_keep := v_keep || ('[' || v_text || '](' || v_url || ')');
    END IF;
    v_line := left(v_line, v_pos - 1) || chr(1) || array_length(v_keep, 1) || chr(2)
              || substr(v_line, v_pos + length(v_m[1]));
  END LOOP;

  -- escape every MarkdownV2 special char in the remaining plain text
  -- (backslash first), then re-enable the formatting constructs on their
  -- escaped forms.
  v_line := regexp_replace(v_line, '\\', '\\\\', 'g');
  v_line := regexp_replace(v_line, '([]_*[()~`>#+=|{}.!-])', '\\\1', 'g');

  -- protect intraword underscores from the emphasis passes: an escaped \_
  -- with alphanumerics on BOTH sides is a literal underscore per CommonMark
  -- flanking rules (snake_case, snake__case), never a delimiter. Parked as
  -- chr(3) until the passes are done (also covers an open/close candidate
  -- touching a word char, e.g. x\_em\_ or \_em\_x, which stays literal).
  v_line := regexp_replace(v_line, '([[:alnum:]])\\_\\_([[:alnum:]])', '\1' || chr(3) || chr(3) || '\2', 'g');
  v_line := regexp_replace(v_line, '([[:alnum:]])\\_([[:alnum:]])', '\1' || chr(3) || '\2', 'g');

  -- strong: **x** / __x__. Every quantifier in these passes must be
  -- non-greedy: ARE treats an RE mixing greedy and non-greedy quantifiers as
  -- all-greedy, which would span one match across two separate spans.
  v_line := regexp_replace(v_line, '\\\*\\\*(\S(?:.*?\S)??)\\\*\\\*', '*\1*', 'g');
  v_line := regexp_replace(v_line, '\\_\\_(\S(?:.*?\S)??)\\_\\_', '*\1*', 'g');
  -- strikethrough: ~~x~~
  v_line := regexp_replace(v_line, '\\~\\~(\S(?:.*?\S)??)\\~\\~', '~\1~', 'g');
  -- emphasis: *x* / _x_ (content may not start/end with a space)
  v_line := regexp_replace(v_line, '\\\*(\S(?:.*?\S)??)\\\*', '_\1_', 'g');
  v_line := regexp_replace(v_line, '\\_(\S(?:.*?\S)??)\\_', '_\1_', 'g');

  -- unprotect intraword underscores
  v_line := replace(v_line, chr(3), '\_');

  FOR v_i IN 1 .. coalesce(array_length(v_keep, 1), 0) LOOP
    v_line := replace(v_line, chr(1) || v_i || chr(2), v_keep[v_i]);
  END LOOP;
  RETURN v_line;
END;
$$;

CREATE OR REPLACE FUNCTION ow.telegramify(p_text text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_line text;
  v_out text := '';
  v_in_pre boolean := false;
  v_m text[];
  v_lang text;
BEGIN
  IF p_text IS NULL THEN
    RETURN NULL;
  END IF;

  FOR v_line IN SELECT regexp_split_to_table(replace(p_text, E'\r', ''), E'\n')
  LOOP
    IF v_in_pre THEN
      -- inside a fenced block: only a bare ``` line closes it; everything
      -- else is verbatim with \ and ` escaped (MarkdownV2 pre rule)
      IF v_line ~ '^\s{0,3}```+\s*$' THEN
        v_out := v_out || '```' || E'\n';
        v_in_pre := false;
      ELSE
        v_out := v_out || replace(regexp_replace(v_line, '\\', '\\\\', 'g'), '`', '\`') || E'\n';
      END IF;
      CONTINUE;
    END IF;

    -- fenced code block open (```lang; the info string keeps safe chars only)
    v_m := regexp_match(v_line, '^\s{0,3}```+([^`]*)$');
    IF v_m IS NOT NULL THEN
      v_lang := regexp_replace(btrim(coalesce(v_m[1], '')), '[^A-Za-z0-9_+.#-]+', '', 'g');
      v_out := v_out || '```' || v_lang || E'\n';
      v_in_pre := true;
      CONTINUE;
    END IF;

    -- heading #..###### → bold (telegramify renders headings as strong)
    v_m := regexp_match(v_line, '^\s{0,3}#{1,6}\s+(.+?)\s*$');
    IF v_m IS NOT NULL THEN
      v_out := v_out || '*' || ow._telegramify_inline(v_m[1]) || '*' || E'\n';
      CONTINUE;
    END IF;

    -- blockquote → MarkdownV2 blockquote ('> ' prefix kept, content converted)
    v_m := regexp_match(v_line, '^\s{0,3}>\s?(.+)$');
    IF v_m IS NOT NULL THEN
      v_out := v_out || '> ' || ow._telegramify_inline(v_m[1]) || E'\n';
      CONTINUE;
    END IF;

    -- unordered bullet (-, *, +) → '•' (telegramify swaps remark's bullet)
    v_m := regexp_match(v_line, '^(\s*)[-*+]\s+(.+)$');
    IF v_m IS NOT NULL THEN
      v_out := v_out || v_m[1] || '• ' || ow._telegramify_inline(v_m[2]) || E'\n';
      CONTINUE;
    END IF;

    -- ordered list marker N. / N) → N\. (telegramify escapes the dot)
    v_m := regexp_match(v_line, '^(\s*)(\d+)[.)]\s+(.+)$');
    IF v_m IS NOT NULL THEN
      v_out := v_out || v_m[1] || v_m[2] || '\. ' || ow._telegramify_inline(v_m[3]) || E'\n';
      CONTINUE;
    END IF;

    v_out := v_out || ow._telegramify_inline(v_line) || E'\n';
  END LOOP;

  -- an unterminated fence is closed so the pre entity stays balanced
  IF v_in_pre THEN
    v_out := v_out || '```' || E'\n';
  END IF;

  RETURN rtrim(v_out, E'\n');
END;
$$;

-- Build the send-graph for an outbound message. Text → df.http sendMessage then
-- send_message (parses the status); attachment → df.http_multipart sendPhoto/
-- sendAudio/sendVideo/sendDocument then send_message. Used by the outbound
-- trigger to df.start a send instance. SELF-BINDS the agent GUC for the
-- build-time message + config reads (send_message is now a pure response-parse
-- with no agent-scoped reads), so no graph node depends on session state carried
-- over from the trigger.
CREATE OR REPLACE FUNCTION ow.send_message_future(p_agent_slug text, p_message_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_msg ow.messages%ROWTYPE;
  v_chat_id text;
  v_thread_id text;
  v_is_attachment boolean;
  v_tools text;
  v_text text;
  v_text_v2 text;
  v_body jsonb;
  v_body_plain jsonb;
  v_att jsonb;
  v_content_b64 text;
  v_kind text;
  v_field text;
  v_method text;
  v_filename text;
  v_mime_type text;
  v_caption text;
  v_parts jsonb;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);

  SELECT * INTO v_msg FROM ow.messages WHERE id = p_message_id;
  v_chat_id := coalesce(nullif(v_msg.chat_id, ''), ow._config_text(v_agent_id, 'telegram_chat_id'));
  v_thread_id := ow._config_text(v_agent_id, 'telegram_thread_id');
  v_is_attachment := v_msg.payload ? 'attachment'
    AND jsonb_typeof(v_msg.payload->'attachment') = 'object'
    AND (v_msg.payload->'attachment') ? 'content';

  IF v_is_attachment THEN
    -- attachment: df.http_multipart uploads via sendPhoto/sendAudio/sendVideo/
    -- sendDocument (field + method chosen by the kind queued with the attachment).
    -- The media bytes are already base64 in the payload, so they slot straight
    -- into a part's data_b64 — no /tmp file, no lo_export, no curl. The form
    -- fields (chat_id, optional thread_id, optional caption) are text parts
    -- (name + data_b64 of the value). df.http_multipart validates parts at
    -- graph-build time and bakes them into the node (no $var indirection), so the
    -- base64 rides in the graph node — which also makes the upload durable-retryable
    -- without re-reading the message.
    v_att := v_msg.payload->'attachment';
    v_content_b64 := translate(coalesce(v_att->>'content', ''), E'\n', '');
    v_kind := coalesce(nullif(v_att->>'kind', ''), 'document');
    v_field := CASE v_kind WHEN 'photo' THEN 'photo' WHEN 'audio' THEN 'audio' WHEN 'video' THEN 'video' ELSE 'document' END;
    v_method := CASE v_kind WHEN 'photo' THEN 'sendPhoto' WHEN 'audio' THEN 'sendAudio' WHEN 'video' THEN 'sendVideo' ELSE 'sendDocument' END;
    v_filename := ow._telegram_attachment_filename(v_att->>'filename', v_kind, p_message_id);
    v_mime_type := coalesce(nullif(btrim(v_att->>'mime_type'), ''), 'application/octet-stream');
    IF v_mime_type !~ '^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$' THEN
      v_mime_type := 'application/octet-stream';
    END IF;
    v_caption := left(coalesce(v_att->>'caption', ''), 1024);

    IF v_content_b64 = '' THEN
      -- nothing to upload: emit a no-op node so df.start still works (mirrors
      -- send_chat_action_future's no_chat fallback).
      RETURN format('SELECT %L::text AS result', 'no_content');
    END IF;

    v_parts := jsonb_build_array(
      jsonb_build_object('name', 'chat_id', 'data_b64', encode(coalesce(v_chat_id, '')::bytea, 'base64'))
    );
    IF v_thread_id IS NOT NULL AND v_thread_id <> '' THEN
      v_parts := v_parts || jsonb_build_array(
        jsonb_build_object('name', 'message_thread_id', 'data_b64', encode(v_thread_id::bytea, 'base64'))
      );
    END IF;
    IF v_caption <> '' THEN
      v_parts := v_parts || jsonb_build_array(
        jsonb_build_object('name', 'caption', 'data_b64', encode(v_caption::bytea, 'base64'))
      );
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'name', v_field,
      'filename', v_filename,
      'content_type', v_mime_type,
      'data_b64', v_content_b64
    )));

    RETURN df.http_multipart(
      ow._telegram_api_url(p_agent_slug, v_method), 'POST', v_parts,
      ow._telegram_headers(), 30
    ) |=> 'r'
      ~> format(
        'SELECT ow.send_message(%L, %s, $r::jsonb)::jsonb AS result',
        p_agent_slug, p_message_id
      );
  END IF;

  -- text: df.http sends via sendMessage, then send_message parses the status.
  -- A tool-call turn with empty content is rendered to its tool name + params
  -- so the chat sees what the agent is doing instead of an empty message.
  --
  -- The LLM's CommonMark output (**bold**, '#' headings, '-' bullets, fenced
  -- code) is converted to Telegram MarkdownV2 (ow.telegramify, modeled on
  -- telegramify-markdown) and sent with parse_mode=MarkdownV2 — the converter
  -- escapes every special char in plain text, so unbalanced CommonMark
  -- markers can no longer trip "can't parse entities". The graph keeps a
  -- plain-text retry of the ORIGINAL (unconverted) text for any residual
  -- MarkdownV2 rejection (e.g. the 4096-char cut unbalancing an entity), so
  -- the reply is delivered verbatim instead of failing the send instance.
  -- Both branches end in send_message, so any other Telegram error (or a
  -- failed retry) raises and fails the instance as before.
  v_tools := ow._render_tool_calls(v_msg.payload->'tool_calls');
  v_text := left(concat_ws(E'\n', nullif(v_msg.content, ''), nullif(v_tools, '')), 4096);
  -- Conversion escapes special chars with backslashes, inflating length, so
  -- the 4096 cap is applied again after conversion; a trailing '\' (a cut
  -- escape pair) is dropped so the tail can't dangle.
  v_text_v2 := left(ow.telegramify(v_text), 4096);
  WHILE right(v_text_v2, 1) = '\' LOOP
    v_text_v2 := left(v_text_v2, length(v_text_v2) - 1);
  END LOOP;
  v_body := jsonb_build_object(
    'chat_id', v_chat_id,
    'parse_mode', 'MarkdownV2',
    'text', v_text_v2
  );
  v_body_plain := jsonb_build_object('chat_id', v_chat_id, 'text', v_text);
  IF v_thread_id IS NOT NULL AND v_thread_id <> '' THEN
    v_body := v_body || jsonb_build_object('message_thread_id', v_thread_id::bigint);
    v_body_plain := v_body_plain || jsonb_build_object('message_thread_id', v_thread_id::bigint);
  END IF;

  RETURN df.http(
    ow._telegram_api_url(p_agent_slug, 'sendMessage'), 'POST', v_body::text,
    ow._telegram_headers(), 30
  ) |=> 'r'
    ~> df.if(
      'SELECT ow._telegram_is_parse_error($r::jsonb)',
      df.http(
        ow._telegram_api_url(p_agent_slug, 'sendMessage'), 'POST', v_body_plain::text,
        ow._telegram_headers(), 30
      ) |=> 'r2'
        ~> format(
          'SELECT ow.send_message(%L, %s, $r2::jsonb)::jsonb AS result',
          p_agent_slug, p_message_id
        ),
      format(
        'SELECT ow.send_message(%L, %s, $r::jsonb)::jsonb AS result',
        p_agent_slug, p_message_id
      )
    );
END;
$$;

-- Build the graph for a Telegram sendChatAction (used for the typing indicator).
-- SELF-BINDS the agent GUC like send_message_future so the token + thread reads
-- resolve under RLS; meant to be fire-and-forget via df.start. Falls back to the
-- configured telegram_chat_id when p_chat_id is empty, and targets the same
-- message_thread_id replies use. The status set here auto-expires after ~5s and
-- is cleared automatically once the bot's reply is delivered, so callers need
-- not (and cannot) send an explicit reset.
CREATE OR REPLACE FUNCTION ow.send_chat_action_future(
  p_agent_slug text,
  p_chat_id text,
  p_action text DEFAULT 'typing'
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, ow_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_chat_id text;
  v_thread_id text;
  v_body jsonb;
BEGIN
  PERFORM set_config('ow.current_agent_id', v_agent_id::text, true);
  v_chat_id := coalesce(nullif(p_chat_id, ''), ow._config_text(v_agent_id, 'telegram_chat_id'));
  -- no resolvable chat (not configured): emit a no-op node so df.start still works
  IF v_chat_id IS NULL OR v_chat_id = '' THEN
    RETURN format('SELECT %L::text AS result', 'no_chat');
  END IF;
  v_thread_id := ow._config_text(v_agent_id, 'telegram_thread_id');
  v_body := jsonb_build_object('chat_id', v_chat_id, 'action', coalesce(nullif(p_action, ''), 'typing'));
  IF v_thread_id IS NOT NULL AND v_thread_id <> '' THEN
    v_body := v_body || jsonb_build_object('message_thread_id', v_thread_id::bigint);
  END IF;
  RETURN df.http(
    ow._telegram_api_url(p_agent_slug, 'sendChatAction'), 'POST', v_body::text,
    ow._telegram_headers(), 15
  );
END;
$$;
