-- Redact blob/attachment bytes from a tool call's arguments before replaying an
-- assistant turn to the LLM. SEND_ATTACHMENT carries media bytes as base64 in
-- arguments.content; those bytes were already consumed (delivered to Telegram)
-- when the call executed, so on history replay the model only needs a size
-- marker. Without this, every prior attachment call is re-sent verbatim each
-- turn and blows the context window. arguments is a JSON-encoded string in the
-- OpenAI tool-call shape; we leave it (and any call to another tool) untouched
-- when it does not parse or has no content key.
CREATE OR REPLACE FUNCTION ow._redact_tool_call_args(p_name text, p_args text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_json jsonb;
  v_len integer;
BEGIN
  IF p_name IS NULL OR p_name NOT IN ('SEND_ATTACHMENT') THEN
    RETURN p_args;
  END IF;

  v_json := ow._try_jsonb(p_args);
  -- _try_jsonb yields {"_raw": ...} on parse failure and {} for empty input; only
  -- redact when it parsed to an object that actually has a content key.
  IF (v_json ? '_raw') OR NOT (v_json ? 'content') THEN
    RETURN p_args;
  END IF;

  v_len := length(coalesce(v_json->>'content', ''));
  RETURN jsonb_set(v_json, '{content}', to_jsonb('[redacted ' || v_len || ' chars]'::text))::text;
END;
$$;

-- Apply _redact_tool_call_args across a tool_calls array. Only string-typed
-- arguments (the OpenAI shape) are rewritten; an object-typed arguments is left
-- as-is so a non-conforming provider is never corrupted. Order is preserved.
CREATE OR REPLACE FUNCTION ow._redact_tool_calls(p_tool_calls jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(jsonb_agg(
           CASE
             WHEN jsonb_typeof(e.value #> '{function,arguments}') = 'string'
             THEN jsonb_set(
                    e.value,
                    '{function,arguments}',
                    to_jsonb(ow._redact_tool_call_args(
                      e.value #>> '{function,name}',
                      e.value #>> '{function,arguments}'
                    ))
                  )
             ELSE e.value
           END
           ORDER BY e.ordinality
         ), '[]'::jsonb)
  FROM jsonb_array_elements(p_tool_calls) WITH ORDINALITY AS e(value, ordinality)
$$;

-- Render one user message as an OpenAI chat message. When the message carries
-- a photo/video attachment ingested as an HLS playlist, and the model is
-- multimodal AND `p_inline` is true (current turn only), the content becomes a
-- multimodal array: the text/caption followed by one `image_url` entry per
-- HLS segment, each built by `ffmpeg.thumbnail(s.data, 0.0, 'jpeg')`. A photo
-- ingests as a single segment → one image; a video → N sampled frames. When
-- either gate is false (next turn, non-multimodal model, or video-but-uninlinable
-- case) the text placeholder is emitted as before. STABLE so the planner can
-- combine it with other reads; pure w.r.t. the message row + the playlist
-- tables (no agent-scoped config reads, no GUC dependency).
CREATE OR REPLACE FUNCTION ow._message_for_openai(
  p_message ow.messages,
  p_multimodal boolean DEFAULT false,
  p_inline boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_base jsonb;
  v_att jsonb;
  v_images jsonb;
  v_text text;
  v_mime text;
BEGIN
  v_base := jsonb_strip_nulls(
    jsonb_build_object(
      'role', p_message.role,
      'content', CASE WHEN p_message.content = '' AND p_message.role = 'assistant'
                      THEN NULL ELSE p_message.content END,
      'tool_call_id', p_message.tool_call_id
    )
    || CASE
      WHEN p_message.payload ? 'tool_calls'
           AND jsonb_typeof(p_message.payload->'tool_calls') = 'array'
      THEN jsonb_build_object('tool_calls', ow._redact_tool_calls(p_message.payload->'tool_calls'))
      ELSE '{}'::jsonb
    END
  );

  IF NOT (p_multimodal AND p_inline) THEN
    RETURN v_base;
  END IF;

  v_att := p_message.payload->'attachment';
  -- Inline thumbnails only for photo OR video attachments with a playlist_id.
  -- (Photos yield one frame; videos yield one frame per segment, sampling the
  -- whole clip at the playlist's segment_duration. Documents are never
  -- inlined, and are not in the supported set anyway.)
  IF v_att IS NULL
     OR jsonb_typeof(v_att) <> 'object'
     OR v_att->>'kind' NOT IN ('photo', 'video')
     OR v_att->>'playlist_id' IS NULL THEN
    RETURN v_base;
  END IF;

  v_text := coalesce(p_message.content, '');
  v_mime := coalesce(v_att->>'mime_type', 'image/jpeg');

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'type', 'image_url',
      'image_url', jsonb_build_object(
        'url', 'data:' || v_mime || ';base64,' ||
               encode(ffmpeg.thumbnail(s.data, 0.0, 'jpeg'), 'base64')
      )
    )
    ORDER BY s.segment_index
  ), '[]'::jsonb)
  INTO v_images
  FROM ffmpeg.hls_segments s
  WHERE s.playlist_id = (v_att->>'playlist_id')::bigint;

  IF jsonb_typeof(v_images) <> 'array' OR jsonb_array_length(v_images) = 0 THEN
    RETURN v_base;
  END IF;

  RETURN jsonb_set(
    v_base,
    '{content}',
    jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_text)) || v_images
  );
END;
$$;

-- Tool schemas are inferred from the ow_tools._tool_* functions: parameter
-- names/types and required-vs-optional come from pg_proc (pronargdefaults marks
-- the trailing optional args), enum values from pg_enum, and the description
-- from COMMENT ON FUNCTION. Defined here in 21; the _tool_* functions live in 22
-- but are read from the catalog only at call time (during an agent turn), so the
-- load order is fine.
CREATE OR REPLACE FUNCTION ow_tools.tool_schemas()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
  WITH tools AS (
    SELECT
      p.oid,
      upper(substr(p.proname, 7))                     AS tool_name,
      p.pronargs,
      p.pronargdefaults,
      obj_description(p.oid, 'pg_proc')               AS description,
      coalesce(p.proallargtypes, p.proargtypes::oid[]) AS argtypes,
      p.proargnames
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'ow_tools'
      AND p.proname ~ '^_tool_'
  ),
  args AS (
    SELECT
      t.tool_name,
      t.description,
      a.ordinality                                      AS pos,
      an.argname,
      regexp_replace(an.argname, '^p_', '')             AS param_name,
      (a.ordinality <= t.pronargs - t.pronargdefaults)  AS required,
      CASE
        WHEN ty.typtype = 'e' THEN
          jsonb_build_object(
            'type', 'string',
            'enum', (SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
                     FROM pg_enum e WHERE e.enumtypid = ty.oid)
          )
        WHEN ty.typname IN ('int2', 'int4', 'int8')        THEN jsonb_build_object('type', 'integer')
        WHEN ty.typname = 'bool'                           THEN jsonb_build_object('type', 'boolean')
        WHEN ty.typname IN ('float4', 'float8', 'numeric') THEN jsonb_build_object('type', 'number')
        WHEN ty.typname IN ('jsonb', 'json')               THEN jsonb_build_object('type', 'object')
        ELSE jsonb_build_object('type', 'string')
      END AS schema
    FROM tools t
    LEFT JOIN LATERAL unnest(t.argtypes) WITH ORDINALITY AS a(argtypeoid, ordinality) ON true
    LEFT JOIN LATERAL unnest(t.proargnames) WITH ORDINALITY AS an(argname, ordinality) ON an.ordinality = a.ordinality
    JOIN pg_type ty ON ty.oid = a.argtypeoid
  ),
  tool_obj AS (
    SELECT
      tool_name,
      jsonb_build_object(
        'type', 'function',
        'function', jsonb_build_object(
          'name', tool_name,
          'description', description,
          'parameters', jsonb_build_object(
            'type', 'object',
            'properties', coalesce(jsonb_object_agg(param_name, schema) FILTER (WHERE argname IS NOT NULL), '{}'::jsonb),
            'required',   coalesce(jsonb_agg(param_name ORDER BY pos) FILTER (WHERE required), '[]'::jsonb)
          )
        )
      ) AS obj
    FROM args
    GROUP BY tool_name, description
  )
  SELECT coalesce(jsonb_agg(obj ORDER BY tool_name), '[]'::jsonb)
  FROM tool_obj;
$$;

CREATE OR REPLACE FUNCTION ow._memory_prompt(p_agent_id bigint)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT coalesce(
    string_agg(
      format(
        '- memory_id=%s source_message_ids=[%s]: %s',
        m.id,
        (SELECT coalesce(string_agg(ms.message_id::text, ',' ORDER BY ms.message_id), '')
         FROM ow.memory_sources ms WHERE ms.memory_id = m.id),
        m.content
      ),
      E'\n'
      ORDER BY m.id
    ),
    ''
  )
  FROM ow.memory m
  WHERE m.agent_id = p_agent_id
    AND m.enabled;
$$;

CREATE OR REPLACE FUNCTION ow._system_prompt(p_agent_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent ow.agents%ROWTYPE;
  v_memory text;
BEGIN
  SELECT * INTO v_agent FROM ow.agents WHERE id = p_agent_id;
  v_memory := ow._memory_prompt(p_agent_id);

  RETURN format(
    '<soul>%s</soul>%s

<harness>
You run inside PostgreSQL. Your canonical state is ow.messages.
Use tool calls when you need to act. Final assistant text with no tool calls is
delivered to the operator automatically.
Use SEARCH for web discovery, WEBFETCH to read a URL, SQL for database work,
and BASH to run a shell command on a registered SSH host.
</harness>',
    v_agent.soul,
    CASE
      WHEN v_memory = '' THEN ''
      ELSE E'\n\n<memory>\n' || v_memory || E'\n</memory>'
    END
  );
END;
$$;

CREATE OR REPLACE FUNCTION ow.compose_llm_request(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent ow.agents%ROWTYPE;
  v_model ow.models%ROWTYPE;
  v_history_limit integer;
  v_messages jsonb;
  v_body jsonb;
  v_last_turn_boundary bigint;
  v_multimodal boolean;
BEGIN
  SELECT * INTO v_agent FROM ow.agents WHERE slug = p_agent_slug AND enabled;
  IF v_agent.id IS NULL THEN
    RAISE EXCEPTION 'agent is missing or disabled: %', p_agent_slug;
  END IF;

  -- Bind the agent GUC so the agent-scoped history/memory reads below resolve
  -- under RLS (the loop now runs as the agent role, not service-bypass).
  PERFORM set_config('ow.current_agent_id', v_agent.id::text, true);

  SELECT m.*
  INTO v_model
  FROM ow.models m
  WHERE m.id = v_agent.model_id;
  IF v_model.id IS NULL THEN
    RAISE EXCEPTION 'agent % has no model config', p_agent_slug;
  END IF;

  v_history_limit := coalesce(ow._config_text(v_agent.id, 'history_limit', '200')::integer, 200);
  v_multimodal := coalesce(v_model.multimodal_support, false);

  -- Inline attachments for the current turn only: messages after the most
  -- recent assistant turn with NO tool_calls (the turn boundary). Earlier
  -- turns' attachments become text placeholders again — the per-turn
  -- ffmpeg.thumbnail cost is paid once, not per iteration.
  SELECT coalesce(max(id), 0) INTO v_last_turn_boundary
    FROM ow.messages
    WHERE agent_id = v_agent.id
      AND role = 'assistant'
      AND (NOT (payload ? 'tool_calls')
           OR jsonb_typeof(payload->'tool_calls') <> 'array'
           OR jsonb_array_length(payload->'tool_calls') = 0);

  SELECT coalesce(jsonb_agg(
    ow._message_for_openai(
      m,
      v_multimodal,
      m.role = 'user' AND m.id > v_last_turn_boundary
    ) ORDER BY m.id
  ), '[]'::jsonb)
  INTO v_messages
  FROM (
    SELECT *
    FROM ow.messages
    WHERE agent_id = v_agent.id
    ORDER BY id DESC
    LIMIT v_history_limit
  ) AS m;

  v_body := jsonb_build_object(
    'model', v_model.name,
    'temperature', v_model.temperature,
    'messages',
      jsonb_build_array(jsonb_build_object(
        'role', 'system',
        'content', ow._system_prompt(v_agent.id)
      )) || coalesce(v_messages, '[]'::jsonb),
    'tools', ow_tools.tool_schemas()
  );

  IF v_model.reasoning_effort <> '' THEN
    v_body := v_body || jsonb_build_object('reasoning_effort', v_model.reasoning_effort);
  END IF;

  RETURN v_body;
END;
$$;

CREATE OR REPLACE FUNCTION ow._llm_url(p_agent_slug text)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_api_base text;
BEGIN
  SELECT m.api_base
  INTO v_api_base
  FROM ow.agents a
  JOIN ow.models m ON m.id = a.model_id
  WHERE a.slug = p_agent_slug;

  IF v_api_base IS NULL OR v_api_base = '' THEN
    RAISE EXCEPTION 'agent % has no model api_base', p_agent_slug;
  END IF;

  RETURN rtrim(v_api_base, '/') || '/chat/completions';
END;
$$;

CREATE OR REPLACE FUNCTION ow._llm_headers(p_agent_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_api_key text;
BEGIN
  v_api_key := ow._config_text(v_agent_id, 'api_key');
  IF v_api_key IS NULL OR v_api_key = '' THEN
    RAISE EXCEPTION 'agent % has no api_key config', p_agent_slug;
  END IF;

  RETURN jsonb_build_object(
    'Authorization', 'Bearer ' || v_api_key,
    'Content-Type', 'application/json'
  );
END;
$$;

-- Record the assistant turn from the LLM HTTP response: append the assistant
-- message (with channel/chat_id so the outbound trigger delivers it) and the
-- parsed tool_calls. No outbox — outbound delivery is trigger-driven.
CREATE OR REPLACE FUNCTION ow.record_assistant(
  p_agent_slug text,
  p_http_response jsonb,
  p_requesting_user_id bigint DEFAULT NULL,
  p_channel text DEFAULT NULL,
  p_chat_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_agent_id bigint := ow.agent_id(p_agent_slug);
  v_status integer;
  v_body_text text;
  v_body jsonb;
  v_message jsonb;
  v_tool_calls jsonb;
  v_message_id bigint;
  v_content text;
  v_payload jsonb;
BEGIN
  v_status := ow._http_status(p_http_response);
  v_body_text := coalesce(p_http_response->>'body', '');

  IF v_status < 200 OR v_status >= 300 THEN
    v_message_id := ow.append_message(
      p_agent_slug, 'system',
      format('[llm http error %s] %s', v_status, left(v_body_text, 4000)),
      jsonb_build_object('http_response', p_http_response),
      NULL, p_channel, p_chat_id
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', '[]'::jsonb, 'error', true);
  END IF;

  v_body := ow._try_jsonb(v_body_text);
  v_message := v_body #> '{choices,0,message}';

  IF v_message IS NULL OR v_message = 'null'::jsonb THEN
    v_message_id := ow.append_message(
      p_agent_slug, 'system',
      '[llm parse error] missing choices[0].message',
      jsonb_build_object('http_response', p_http_response),
      NULL, p_channel, p_chat_id
    );
    RETURN jsonb_build_object('message_id', v_message_id, 'tool_calls', '[]'::jsonb, 'error', true);
  END IF;

  v_content := coalesce(v_message->>'content', '');
  v_tool_calls := CASE
    WHEN jsonb_typeof(v_message->'tool_calls') = 'array' THEN v_message->'tool_calls'
    ELSE '[]'::jsonb
  END;

  -- Flatten the raw LLM message (content/reasoning_content/tool_calls/…) straight
  -- into the payload rather than nesting it under a `raw` key, so consumers can
  -- read e.g. reasoning_content without descending into payload.raw. tool_calls
  -- is re-stamped so the key is always present as an array even when the model
  -- emitted none; requesting_user_id scopes any tool calls to that user.
  v_payload := v_message
    || jsonb_build_object('tool_calls', v_tool_calls, 'requesting_user_id', p_requesting_user_id);

  -- Only mark a turn for delivery when it is a final reply: an assistant turn
  -- that carries tool calls is an intermediate step (often with empty text), so
  -- leaving its channel NULL keeps the outbound trigger from sending an empty
  -- message to Telegram. The final no-tool-call reply is delivered as usual.
  -- Always stamp the delivery channel: a final reply is sent as-is, and a
  -- tool-call turn (usually empty text) is rendered to its tool name + params
  -- by send_message_future, so the outbound trigger delivers both.
  v_message_id := ow.append_message(
    p_agent_slug, 'assistant', v_content, v_payload,
    NULL, p_channel, p_chat_id
  );

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'message_id', v_message_id,
    'tool_calls', v_tool_calls,
    'error', false
  ));
END;
$$;
