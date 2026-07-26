-- ============================================================================
-- Trigger-driven agent loop
--   Primary: an AFTER INSERT STATEMENT trigger on OpenWorld.messages starts a
--   bounded df.loop whenever a role='user' row for the primary agent lands.
--   Each iteration: compose → LLM http → record assistant → run tool calls as
--   per-call instances under the acting role → loop until no tool calls or
--   max_turn. Outbound delivery is a separate row-level trigger (below).
-- ============================================================================

CREATE OR REPLACE FUNCTION OpenWorld.start_agent_loop(
  p_agent_slug text,
  p_trigger_message_id bigint,
  p_requesting_user_id bigint DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = OpenWorld, OpenWorld_tools, public, pg_temp
AS $$
DECLARE
  v_agent_id bigint := OpenWorld.agent_id(p_agent_slug);
  -- Embed the trigger message id so a turn can be traced across workflows by a
  -- single correlation key (tool/send/typing instances already key on a message
  -- id; now the loop does too). See OpenWorld.trace_turn / OpenWorld.instance_index.
  v_label text := format('OpenWorld:%s:loop:%s', p_agent_slug, coalesce(p_trigger_message_id::text, '0'));
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
  -- per-trigger (OpenWorld:<slug>:loop:<msg_id>), so prefix-match any running loop
  -- for this agent instead of comparing the full per-trigger label for equality.
  SELECT id INTO v_existing
    FROM df.instances
    WHERE label LIKE format('OpenWorld:%s:loop:%%', p_agent_slug)
      AND status IN ('pending', 'running')
    LIMIT 1;
  IF v_existing IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT max_turn INTO v_max_turn FROM OpenWorld.agents WHERE id = v_agent_id;

  -- SECURITY INVOKER: this runs as the entry-starter's owner (OpenWorld_agent_primary
  -- via the inbox/user-message trigger, OpenWorld_agent_sidecar via the cron
  -- loop). Bind the agent GUC for this session so the agent-scoped reads below
  -- resolve under RLS (no service bypass anymore).
  PERFORM set_config('OpenWorld.current_agent_id', v_agent_id::text, true);

  -- acting role + user context. Primary user turns drop tool calls to the
  -- requesting user's tier; sidecar (no requesting user) drops to
  -- OpenWorld_service (broad, secret-free) so it can review any agent; otherwise
  -- tools run at the agent's own role.
  IF p_requesting_user_id IS NOT NULL THEN
    SELECT 'OpenWorld_' || u.tier, u.external_id, u.id::text
      INTO v_acting_role, v_ext_id, v_user_id
      FROM OpenWorld.users u WHERE u.id = p_requesting_user_id;
    v_channel := 'telegram';
    SELECT chat_id INTO v_chat_id FROM OpenWorld.messages WHERE id = p_trigger_message_id;
  ELSIF p_agent_slug = 'sidecar' THEN
    v_acting_role := 'OpenWorld_service';
  ELSE
    v_acting_role := 'OpenWorld_agent_' || p_agent_slug;
  END IF;

  v_body :=
    format('SELECT OpenWorld.compose_llm_request(%L)::text AS body', p_agent_slug) |=> 'request'
    ~> df.http(OpenWorld._llm_url(p_agent_slug), 'POST', '$request',
               OpenWorld._llm_headers(p_agent_slug), 120) |=> 'response'
    ~> df.if(
         'SELECT OpenWorld._http_status($response::jsonb) >= 200 AND OpenWorld._http_status($response::jsonb) < 300',
         format('SELECT OpenWorld.record_assistant(%L, $response::jsonb, %s, %L, %L)::jsonb AS assistant',
                p_agent_slug, coalesce(p_requesting_user_id::text, 'NULL'), v_channel, v_chat_id),
         format('SELECT OpenWorld.append_message(%L, ''system'', format(''[llm http error %%s]'', OpenWorld._http_status($response::jsonb)))::text AS e',
                p_agent_slug)
           ~> df.break('llm_error')
       ) |=> 'assistant'
    ~> df.if(
         'SELECT coalesce(jsonb_array_length(($assistant::jsonb)->''tool_calls''), 0) > 0',
         format('SELECT OpenWorld_tools.start_tool_calls(%L, (($assistant::jsonb)->>''message_id'')::bigint, ($assistant::jsonb)->''tool_calls'', %L, %L, %L, %s)::text AS started',
                p_agent_slug, v_acting_role, coalesce(v_ext_id, ''), coalesce(v_chat_id, ''), coalesce(v_user_id, 'NULL'))
           |=> 'started'
           ~> format('SELECT OpenWorld_tools.await_tool_calls(%L, $started)::text AS tools', p_agent_slug),
         df.break('done')
       );

  -- The loop condition runs as its own statement in the instance, so bind the
  -- agent GUC inline (FROM is evaluated before WHERE) before the messages count.
  v_cond := format(
    'SELECT (SELECT count(*) FROM OpenWorld.messages CROSS JOIN (SELECT set_config(''OpenWorld.current_agent_id'', %L, true)) AS cfg WHERE agent_id = %s AND role = ''assistant'' AND id > %s) < coalesce((SELECT max_turn FROM OpenWorld.agents WHERE id = %s), 1)',
    v_agent_id::text, v_agent_id, p_trigger_message_id, v_agent_id
  );

  SELECT df.start(df.loop(v_body, v_cond), v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- AFTER INSERT STATEMENT trigger: start the primary loop when user messages land
CREATE OR REPLACE FUNCTION OpenWorld.after_user_message_loop()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = OpenWorld, OpenWorld_tools, public, pg_temp
AS $$
DECLARE
  v_primary_id bigint;
  v_trigger_id bigint;
  v_from_id text;
  v_req_user_id bigint;
  v_chat_id text;
BEGIN
  SELECT id INTO v_primary_id FROM OpenWorld.agents WHERE slug = 'primary';
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
    SELECT id INTO v_req_user_id FROM OpenWorld.users
      WHERE channel = 'telegram' AND external_id = v_from_id;
    -- Show a typing indicator in the originating chat while the agent loop runs.
    -- Fire-and-forget before start_agent_loop: the indicator auto-expires (~5s)
    -- and is cleared once the loop's reply is delivered by the outbound send
    -- trigger, so there is no reset step.
    PERFORM df.start(
      OpenWorld.send_chat_action_future('primary', v_chat_id, 'typing'),
      format('OpenWorld:typing:%s', v_trigger_id)
    );
  END IF;

  PERFORM OpenWorld.start_agent_loop('primary', v_trigger_id, v_req_user_id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_user_loop_trigger
AFTER INSERT ON OpenWorld.messages
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT
EXECUTE FUNCTION OpenWorld.after_user_message_loop();

-- ============================================================================
-- Outbound delivery trigger (replaces the outbox)
--   role in ('assistant','system') + channel='telegram' → df.start a send
-- ============================================================================

CREATE OR REPLACE FUNCTION OpenWorld.after_outbound_message_send()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = OpenWorld, OpenWorld_tools, public, pg_temp
AS $$
DECLARE
  v_slug text;
BEGIN
  -- send_message_future takes the slug and self-binds the agent GUC, so the
  -- trigger no longer needs to bind it (the prior is_local bind never reached
  -- the send instance's own transaction anyway). Resolve the owning agent's slug.
  SELECT slug INTO v_slug FROM OpenWorld.agents WHERE id = NEW.agent_id;
  PERFORM df.start(OpenWorld.send_message_future(v_slug, NEW.id), format('OpenWorld:send:%s', NEW.id));
  RETURN NULL;
END;
$$;

CREATE TRIGGER messages_outbound_send_trigger
AFTER INSERT ON OpenWorld.messages
FOR EACH ROW
WHEN (NEW.role IN ('assistant', 'system') AND NEW.channel = 'telegram'
      AND (coalesce(NEW.content, '') <> ''
           OR NEW.payload ? 'attachment'
           OR (NEW.payload ? 'tool_calls'
               AND jsonb_typeof(NEW.payload->'tool_calls') = 'array'
               AND jsonb_array_length(NEW.payload->'tool_calls') > 0)))
EXECUTE FUNCTION OpenWorld.after_outbound_message_send();

-- ============================================================================
-- Inbound long-poll loop (Telegram getUpdates → poll_messages → trigger)
-- ============================================================================

CREATE OR REPLACE FUNCTION OpenWorld.ensure_telegram_inbox_loop(
  p_agent_slug text DEFAULT 'primary',
  p_timeout integer DEFAULT 60
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = OpenWorld, OpenWorld_tools, public, pg_temp
AS $$
DECLARE
  v_label text := format('OpenWorld:%s:inbox', p_agent_slug);
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
  -- SECURITY DEFINER owned by the agent role, so RLS on OpenWorld.config binds us
  -- (config_agent_read_own requires current_agent_id) — same requirement as
  -- poll_messages. Without this the init-time call can't see telegram_token.
  PERFORM set_config('OpenWorld.current_agent_id', OpenWorld.agent_id(p_agent_slug)::text, true);

  v_future := df.loop(
    format('SELECT OpenWorld.telegram_get_updates_body(%L, %s)::text AS body', p_agent_slug, p_timeout) |=> 'req'
    ~> df.http(OpenWorld._telegram_api_url(p_agent_slug, 'getUpdates'), 'POST', '$req',
               OpenWorld._telegram_headers(), p_timeout + 5) |=> 'resp'
    ~> format('SELECT OpenWorld.poll_messages(%L, $resp::jsonb)::jsonb AS result', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;

-- ============================================================================
-- Cron-driven agent loop (sidecar): on schedule, append a system prompt
-- and start that agent's loop (tools run as the agent's own role)
-- ============================================================================

CREATE OR REPLACE FUNCTION OpenWorld.ensure_agent_cron_loop(
  p_agent_slug text DEFAULT 'sidecar',
  p_name text DEFAULT 'review',
  p_cron text DEFAULT '*/10 * * * *',
  p_message text DEFAULT 'review agent streams for actionable memory corrections'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = OpenWorld, OpenWorld_tools, public, pg_temp
AS $$
DECLARE
  v_label text := format('OpenWorld:%s:cron:%s', p_agent_slug, p_name);
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
    ~> format('SELECT OpenWorld.append_message(%L, ''system'', %L)::bigint AS m',
              p_agent_slug, format('[schedule %s] %s', p_name, p_message)) |=> 'm'
    ~> format('SELECT OpenWorld.start_agent_loop(%L, $m, NULL)::text AS loop_id', p_agent_slug)
  );

  SELECT df.start(v_future, v_label) INTO v_instance;
  RETURN v_instance;
END;
$$;
