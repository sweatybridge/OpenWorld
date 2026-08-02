-- ============================================================================
-- Cross-workflow execution tracing.
--
-- Problem: a single agent "turn" fans out into several df.instances — a loop
-- (the turn parent), zero or more tool-call instances, an outbound send per
-- assistant message, and a typing indicator — but nothing joined them: tool/send
-- /typing labels embed a message id, the loop label did not, and df.instances
-- has no parent_instance_id. A turn could only be reassembled by time heuristic.
--
-- start_agent_loop (30-OpenWorld-durable.sql) now embeds the trigger message id
-- into the loop label (ow:<slug>:loop:<msg_id>), so every instance in a
-- turn shares a message-id key. This file adds:
--   * ow.parse_instance_label — pure label → (kind, agent, msg, tool_call)
--     parser. Single source of truth for classification (replaces the
--     triplicated regex in the dashboard server) and the unit tested directly.
--   * ow.instance_index       — structured projection of df.instances via
--     the parser. security_invoker, so it sees what the caller sees.
--   * ow.turn_trigger_id      — given any message id in a turn, resolve the
--     turn's trigger (the owning user/system message). Pure, unit tested.
--   * ow.trace_turn(msg)      — the full instance tree for a turn (loop +
--     typing + per-assistant-message tool/send), built on the pieces above.
--
-- All run as the caller (SECURITY INVOKER / security_invoker view). The
-- ow_dashboard role already has BYPASSRLS + USAGE on df + EXECUTE on the
-- df read functions, so tracing works for it with no extra surface.
-- ============================================================================

-- Pure label parser. Extracted so it can be unit-tested without any
-- df.instances rows (the RBAC test harness creates none). Classification is
-- backward-compatible: the loop arm matches both legacy `ow:x:loop` and
-- the new `ow:x:loop:<id>`.
CREATE OR REPLACE FUNCTION ow.parse_instance_label(p_label text)
RETURNS TABLE(
  kind         text,
  agent_slug   text,
  message_id   bigint,
  tool_call_id text
)
LANGUAGE sql
IMMUTABLE
AS $$
SELECT
     CASE
       WHEN p_label ~ '^ow:[^:]+:loop($|:)' THEN 'loop'
       WHEN p_label ~ '^ow:[^:]+:inbox$'    THEN 'inbox'
       WHEN p_label ~ '^ow:[^:]+:cron:'     THEN 'cron'
       WHEN p_label ~ '^ow:send:'           THEN 'send'
       WHEN p_label ~ '^ow:download:'       THEN 'download'
       WHEN p_label ~ '^ow:tool:'           THEN 'tool'
       WHEN p_label ~ '^ow:typing:'         THEN 'typing'
       WHEN p_label LIKE 'ow:%'             THEN 'ow'
       ELSE 'other'
     END,
     COALESCE(
       (regexp_match(p_label, '^ow:([^:]+):loop($|:)'))[1],
       (regexp_match(p_label, '^ow:([^:]+):inbox$'))[1],
       (regexp_match(p_label, '^ow:([^:]+):cron:'))[1]
     ),
     CASE
       WHEN p_label ~ '^ow:[^:]+:loop:' THEN NULLIF((regexp_match(p_label, '^ow:[^:]+:loop:([0-9]+)'))[1], '')::bigint
       WHEN p_label ~ '^ow:typing:'     THEN NULLIF((regexp_match(p_label, '^ow:typing:([0-9]+)'))[1], '')::bigint
       WHEN p_label ~ '^ow:send:'       THEN NULLIF((regexp_match(p_label, '^ow:send:([0-9]+)'))[1], '')::bigint
       WHEN p_label ~ '^ow:download:'   THEN NULLIF((regexp_match(p_label, '^ow:download:([0-9]+)'))[1], '')::bigint
       WHEN p_label ~ '^ow:tool:'       THEN NULLIF((regexp_match(p_label, '^ow:tool:([0-9]+):'))[1], '')::bigint
       ELSE NULL
     END,
     CASE
       WHEN p_label ~ '^ow:tool:' THEN (regexp_match(p_label, '^ow:tool:[0-9]+:(.+)$'))[1]
       ELSE NULL
     END;
$$;

-- Structured projection of every df.instances row. security_invoker so it does
-- not leak rows through the superuser-owned view; the dashboard (BYPASSRLS) sees
-- all, a normal submitter role sees only its own — same as df.instances itself.
CREATE OR REPLACE VIEW ow.instance_index
WITH (security_invoker = true) AS
SELECT i.id, i.label, p.kind, p.agent_slug, p.message_id, p.tool_call_id,
       i.status, i.submitted_by, i.database AS db, i.updated_at
FROM df.instances i,
     LATERAL ow.parse_instance_label(i.label) AS p;

-- Resolve the trigger message id for whatever message id is handed in. A
-- user/system message is its own trigger; an assistant/tool message walks back
-- to the nearest preceding user/system message for the same agent. Returns NULL
-- for an unknown message id.
CREATE OR REPLACE FUNCTION ow.turn_trigger_id(p_message_id bigint)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ow, public, pg_temp
AS $$
DECLARE
  v_role      text;
  v_agent_id  bigint;
  v_trigger_id bigint;
BEGIN
  SELECT role, agent_id INTO v_role, v_agent_id
    FROM ow.messages WHERE id = p_message_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_role IN ('user', 'system') THEN
    RETURN p_message_id;
  END IF;

  SELECT id INTO v_trigger_id
    FROM ow.messages
    WHERE agent_id = v_agent_id
      AND role IN ('user', 'system')
      AND id <= p_message_id
    ORDER BY id DESC
    LIMIT 1;

  RETURN COALESCE(v_trigger_id, p_message_id);
END;
$$;

-- df.result() may raise for some instance states (e.g. still pending). Wrap it
-- so trace_turn can include results without aborting the whole trace.
CREATE OR REPLACE FUNCTION ow._instance_result(p_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ow, public, pg_temp
AS $$
BEGIN
  RETURN df.result(p_id);
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END;
$$;

-- The full instance tree for the turn containing p_message_id. Resolves the
-- trigger via turn_trigger_id, then joins every correlated instance by the
-- message ids embedded in their labels: loop + typing key on the trigger; each
-- tool/send keys on the assistant message that produced it.
CREATE OR REPLACE FUNCTION ow.trace_turn(p_message_id bigint)
RETURNS TABLE(
  instance_id  text,
  kind         text,
  agent_slug   text,
  message_id   bigint,
  tool_call_id text,
  status       text,
  updated_at   timestamptz,
  result       jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ow, public, pg_temp
AS $$
DECLARE
  v_trigger_id    bigint;
  v_agent_id      bigint;
  v_next_boundary bigint;
BEGIN
  v_trigger_id := ow.turn_trigger_id(p_message_id);
  IF v_trigger_id IS NULL THEN
    RETURN;  -- unknown message → empty trace
  END IF;

  SELECT agent_id INTO v_agent_id FROM ow.messages WHERE id = v_trigger_id;

  -- Assistant messages in this turn: same agent, after the trigger, up to the
  -- next user/system message (which starts a new turn).
  SELECT id INTO v_next_boundary
    FROM ow.messages
    WHERE agent_id = v_agent_id
      AND role IN ('user', 'system')
      AND id > v_trigger_id
    ORDER BY id ASC
    LIMIT 1;

  RETURN QUERY
  SELECT ix.id::text, ix.kind, ix.agent_slug, ix.message_id, ix.tool_call_id,
         ix.status::text, ix.updated_at, ow._instance_result(ix.id) AS result
  FROM ow.instance_index ix
  WHERE ix.message_id = v_trigger_id                       -- loop + typing for the trigger
     OR ix.message_id IN (                                  -- tool/send for each assistant msg
          SELECT m.id FROM ow.messages m
          WHERE m.agent_id = v_agent_id
            AND m.role = 'assistant'
            AND m.id > v_trigger_id
            AND (v_next_boundary IS NULL OR m.id < v_next_boundary)
        )
  ORDER BY (ix.kind = 'loop') DESC, ix.message_id NULLS LAST, ix.updated_at;
END;
$$;
