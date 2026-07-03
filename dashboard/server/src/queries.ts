import { query } from "./db.js";
import type {
  AgentRow,
  ConfigRow,
  InstanceNode,
  MessageRow,
  OverviewResponse,
  WorkflowRow,
} from "./types.js";

// ---------------------------------------------------------------------------
// Overview / metrics
// ---------------------------------------------------------------------------

export async function getMetrics(): Promise<Record<string, unknown> | null> {
  const { rows } = await query("SELECT * FROM df.metrics()");
  return rows[0] ?? null;
}

export async function getWorkerEpoch(): Promise<OverviewResponse["worker"]> {
  // _worker_epoch is internal; tolerate absence or permission error gracefully.
  // Compute the heartbeat age in SQL: node-postgres parses a raw `interval`
  // column into an object, so EXTRACT(EPOCH ...) gives a clean float8.
  try {
    const { rows } = await query<{
      started_at: string | null;
      last_seen_at: string | null;
      age_seconds: number | null;
    }>("SELECT started_at, last_seen_at, EXTRACT(EPOCH FROM (now() - last_seen_at))::float8 AS age_seconds FROM df._worker_epoch");
    const r = rows[0];
    if (!r) return null;
    return { started_at: r.started_at, last_seen_at: r.last_seen_at, age_seconds: r.age_seconds };
  } catch {
    return null;
  }
}

export async function getOverviewAgents(): Promise<Array<{ id: number; slug: string; enabled: boolean }>> {
  const { rows } = await query<{ id: number; slug: string; enabled: boolean }>(
    "SELECT id, slug, enabled FROM attobot.agents ORDER BY id"
  );
  return rows;
}

export async function getStatusCounts(): Promise<Array<{ status: string; count: string }>> {
  const { rows } = await query<{ status: string; count: string }>(
    "SELECT status, count(*)::text AS count FROM df.instances GROUP BY status ORDER BY count DESC"
  );
  return rows;
}

export async function getTypeCounts(): Promise<Array<{ type: string; count: string }>> {
  const { rows } = await query<{ type: string; count: string }>(`
    SELECT type, count(*)::text AS count FROM (
      SELECT
        CASE
          WHEN label ~ '^attobot:[^:]+:loop$'   THEN 'loop'
          WHEN label ~ '^attobot:[^:]+:inbox$'  THEN 'inbox'
          WHEN label ~ '^attobot:[^:]+:cron:'   THEN 'cron'
          WHEN label ~ '^attobot:send:'         THEN 'send'
          WHEN label ~ '^attobot:tool:'         THEN 'tool'
          WHEN label ~ '^attobot:typing:'       THEN 'typing'
          WHEN label LIKE 'attobot:%'           THEN 'attobot'
          ELSE 'other'
        END AS type
      FROM df.instances
    ) t GROUP BY type ORDER BY count DESC
  `);
  return rows;
}

// ---------------------------------------------------------------------------
// Workflows list (df.instances) with label parsing in SQL for filtering
// ---------------------------------------------------------------------------

const WORKFLOW_LIST_SQL = `
  WITH labeled AS (
    SELECT id, label, status, submitted_by, database AS db, updated_at,
      CASE
        WHEN label ~ '^attobot:[^:]+:loop$'   THEN 'loop'
        WHEN label ~ '^attobot:[^:]+:inbox$'  THEN 'inbox'
        WHEN label ~ '^attobot:[^:]+:cron:'   THEN 'cron'
        WHEN label ~ '^attobot:send:'         THEN 'send'
        WHEN label ~ '^attobot:tool:'         THEN 'tool'
        WHEN label ~ '^attobot:typing:'       THEN 'typing'
        WHEN label LIKE 'attobot:%'           THEN 'attobot'
        ELSE 'other'
      END AS type,
      COALESCE((regexp_match(label, '^attobot:([^:]+):(loop|inbox|cron)'))[1], '') AS agent
    FROM df.instances
  )
  SELECT id, label, status, submitted_by, db, updated_at, type,
         NULLIF(agent, '') AS agent
  FROM labeled
  WHERE ($1::text IS NULL OR status = $1)
    AND ($2::text IS NULL OR type = $2)
    AND ($3::text IS NULL OR agent = $3)
    AND ($4::text IS NULL OR label ILIKE '%' || $4 || '%' OR id ILIKE '%' || $4 || '%')
  ORDER BY updated_at DESC
  LIMIT $5 OFFSET $6`;

export async function listWorkflows(opts: {
  status?: string | null;
  type?: string | null;
  agent?: string | null;
  q?: string | null;
  limit: number;
  offset: number;
}): Promise<{ rows: WorkflowRow[]; total: number }> {
  const status = opts.status || null;
  const type = opts.type || null;
  const agent = opts.agent || null;
  const q = opts.q || null;
  const limit = Math.min(Math.max(opts.limit, 1), 500);
  const offset = Math.max(opts.offset, 0);

  const { rows } = await query<WorkflowRow>(WORKFLOW_LIST_SQL, [
    status, type, agent, q, limit, offset,
  ]);

  const total = await countWorkflows({ status, type, agent, q });

  return { rows, total };
}

// Separate, correct count (no limit/offset).
const WORKFLOW_COUNT_SQL = `
  WITH labeled AS (
    SELECT id, label, status,
      CASE
        WHEN label ~ '^attobot:[^:]+:loop$'   THEN 'loop'
        WHEN label ~ '^attobot:[^:]+:inbox$'  THEN 'inbox'
        WHEN label ~ '^attobot:[^:]+:cron:'   THEN 'cron'
        WHEN label ~ '^attobot:send:'         THEN 'send'
        WHEN label ~ '^attobot:tool:'         THEN 'tool'
        WHEN label ~ '^attobot:typing:'       THEN 'typing'
        WHEN label LIKE 'attobot:%'           THEN 'attobot'
        ELSE 'other'
      END AS type,
      COALESCE((regexp_match(label, '^attobot:([^:]+):(loop|inbox|cron)'))[1], '') AS agent
    FROM df.instances
  )
  SELECT count(*)::text FROM labeled
  WHERE ($1::text IS NULL OR status = $1)
    AND ($2::text IS NULL OR type = $2)
    AND ($3::text IS NULL OR agent = $3)
    AND ($4::text IS NULL OR label ILIKE '%' || $4 || '%' OR id ILIKE '%' || $4 || '%')`;

export async function countWorkflows(opts: {
  status?: string | null;
  type?: string | null;
  agent?: string | null;
  q?: string | null;
}): Promise<number> {
  const { rows } = await query<{ count: string }>(WORKFLOW_COUNT_SQL, [
    opts.status || null, opts.type || null, opts.agent || null, opts.q || null,
  ]);
  return parseInt(rows[0]?.count ?? "0", 10);
}

// ---------------------------------------------------------------------------
// Workflow detail
// ---------------------------------------------------------------------------

export async function workflowDetail(id: string) {
  const infoRes = await query("SELECT * FROM df.instance_info($1)", [id]);
  const info = infoRes.rows[0] ?? null;

  const explainRes = await query<{ explain: string | null }>(
    "SELECT df.explain($1) AS explain", [id]
  ).catch(() => ({ rows: [{ explain: null }] as Array<{ explain: string | null }> }));
  const explain = explainRes.rows[0]?.explain ?? null;

  const resultRes = await query<{ result: unknown }>(
    "SELECT df.result($1) AS result", [id]
  ).catch(() => ({ rows: [{ result: null }] }));
  const result = resultRes.rows[0]?.result ?? null;

  const nodesRes = await query<InstanceNode>(
    "SELECT execution_id, node_id, node_type, query, result_name, left_node, right_node, status, result FROM df.instance_nodes($1) ORDER BY execution_id DESC, node_id"
    , [id]
  ).catch(() => ({ rows: [] as InstanceNode[] }));
  const nodes = nodesRes.rows;

  const execsRes = await query(
    "SELECT execution_id, status, event_count, duration_ms, output FROM df.instance_executions($1) ORDER BY execution_id DESC"
    , [id]
  ).catch(() => ({ rows: [] }));
  const executions = execsRes.rows;

  // Pick the execution whose node graph to render: the current one if known,
  // else the newest execution present among the nodes. df reports execution ids
  // as text, so compare as strings on the client.
  const currentFromInfo =
    info && (info as { current_execution_id?: unknown }).current_execution_id != null
      ? String((info as { current_execution_id: unknown }).current_execution_id)
      : null;
  const current_execution_id =
    currentFromInfo ?? (nodes[0]?.execution_id ?? null);

  return { info, explain, result, nodes, current_execution_id, executions };
}

// ---------------------------------------------------------------------------
// Agents + messages
// ---------------------------------------------------------------------------

export async function listAgents(): Promise<AgentRow[]> {
  const { rows } = await query<AgentRow>(`
    SELECT a.id, a.slug, a.soul, a.enabled, a.max_turn, a.model_id,
           a.created_at, a.updated_at,
           m.name AS model_name, m.api_base, m.temperature::text AS temperature,
           m.reasoning_effort, m.context_tokens, m.multimodal_support,
           (SELECT count(*) FROM attobot.messages WHERE agent_id = a.id)::text AS msg_count,
           (SELECT count(*) FROM attobot.memory   WHERE agent_id = a.id)::text AS mem_count,
           (SELECT count(*) FROM df.instances     WHERE label LIKE 'attobot:' || a.slug || ':%')::text AS wf_count
    FROM attobot.agents a
    LEFT JOIN attobot.models m ON m.id = a.model_id
    ORDER BY a.id`);
  return rows;
}

export async function listAgentMessages(
  agentId: number,
  before: number | null,
  limit: number
): Promise<MessageRow[]> {
  const cap = Math.min(Math.max(limit, 1), 200);
  const { rows } = await query<MessageRow>(
    `SELECT id, agent_id, role, content, payload, channel, chat_id, tool_call_id, created_at
     FROM attobot.messages
     WHERE agent_id = $1 AND ($2::bigint IS NULL OR id < $2)
     ORDER BY id DESC
     LIMIT $3`,
    [agentId, before, cap]
  );
  return rows;
}

// ---------------------------------------------------------------------------
// Memory / users / lifecycle / config / blobs
// ---------------------------------------------------------------------------

export async function listMemory(agentId: number | null) {
  const { rows } = await query(
    `SELECT m.id, m.agent_id, m.content, m.payload, m.enabled, m.created_at, m.updated_at,
            COALESCE(array_agg(ms.message_id) FILTER (WHERE ms.message_id IS NOT NULL), '{}') AS source_message_ids
     FROM attobot.memory m
     LEFT JOIN attobot.memory_sources ms ON ms.memory_id = m.id
     WHERE ($1::bigint IS NULL OR m.agent_id = $1)
     GROUP BY m.id
     ORDER BY m.id DESC`,
    [agentId]
  );
  return rows;
}

export async function listUsers() {
  const { rows } = await query(
    `SELECT id, channel, external_id, username, display_name, tier, payload, created_at, updated_at
     FROM attobot.users ORDER BY updated_at DESC LIMIT 500`
  );
  return rows;
}

export async function listLifecycle(agentId: number | null, limit: number) {
  const cap = Math.min(Math.max(limit, 1), 1000);
  const { rows } = await query(
    `SELECT id, agent_id, event, detail, created_at
     FROM attobot.lifecycle
     WHERE ($1::bigint IS NULL OR agent_id = $1)
     ORDER BY id DESC LIMIT $2`,
    [agentId, cap]
  );
  return rows;
}

export async function listConfig(agentId: number | null): Promise<ConfigRow[]> {
  const { rows } = await query<ConfigRow>(
    `SELECT agent_id, key, value, secret, updated_at
     FROM attobot.config
     WHERE ($1::bigint IS NULL OR agent_id = $1)
     ORDER BY agent_id, key`,
    [agentId]
  );
  return rows;
}

export async function listBlobs(agentId: number | null) {
  const { rows } = await query(
    `SELECT agent_id, hash, octet_length(content) AS size, created_at
     FROM attotools.blobs
     WHERE ($1::bigint IS NULL OR agent_id = $1)
     ORDER BY created_at DESC LIMIT 500`,
    [agentId]
  );
  return rows;
}
