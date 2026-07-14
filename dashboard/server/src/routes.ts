import type { FastifyInstance } from "fastify";
import { pool } from "./db.js";
import {
  countWorkflows,
  getMetrics,
  getOverviewAgents,
  getStatusCounts,
  getTypeCounts,
  getWorkerEpoch,
  listAgentMessages,
  listAgents,
  listBlobs,
  listConfig,
  listMemory,
  listUsers,
  listWorkflows,
  traceTurn,
  workflowDetail,
} from "./queries.js";
import { maskConfig } from "./mask.js";

function parseIntOrNull(v: unknown): number | null {
  const n = parseInt(String(v ?? ""), 10);
  return Number.isFinite(n) ? n : null;
}

function parseStrOrNull(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return s.length ? s : null;
}

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  app.get("/api/health", async () => {
    // Lightweight DB reachability check (used by the compose healthcheck).
    try {
      await pool.query("SELECT 1");
      return { status: "ok" };
    } catch (e) {
      return { status: "degraded", error: (e as Error).message };
    }
  });

  app.get("/api/overview", async () => {
    const [metrics, worker, by_type, by_status, agents] = await Promise.all([
      getMetrics().catch(() => null),
      getWorkerEpoch(),
      getTypeCounts().catch(() => []),
      getStatusCounts().catch(() => []),
      getOverviewAgents().catch(() => []),
    ]);
    return { metrics, worker, by_type, by_status, agents };
  });

  app.get("/api/workflows", async (req) => {
    const q = req.query as Record<string, string | undefined>;
    const limit = parseInt(q.limit ?? "50", 10) || 50;
    const offset = parseInt(q.offset ?? "0", 10) || 0;
    const { rows, total } = await listWorkflows({
      status: parseStrOrNull(q.status),
      type: parseStrOrNull(q.type),
      agent: parseStrOrNull(q.agent),
      q: parseStrOrNull(q.q),
      limit,
      offset,
    });
    return { rows, total, limit, offset };
  });

  app.get("/api/workflows/:id", async (req, reply) => {
    const { id } = req.params as { id: string };
    const detail = await workflowDetail(id);
    if (!detail.info && detail.nodes.length === 0 && detail.executions.length === 0) {
      reply.code(404);
      return { error: "not found" };
    }
    return detail;
  });

  app.get("/api/agents", async () => ({ rows: await listAgents() }));

  // Cross-workflow trace for one agent turn (loop + tool/send/typing children).
  app.get("/api/trace/:messageId", async (req, reply) => {
    const { messageId } = req.params as { messageId: string };
    const id = parseIntOrNull(messageId);
    if (id === null) {
      reply.code(400);
      return { error: "bad message id" };
    }
    return { rows: await traceTurn(id) };
  });

  app.get("/api/agents/:id/messages", async (req, reply) => {
    const { id } = req.params as { id: string };
    const q = req.query as Record<string, string | undefined>;
    const agentId = parseIntOrNull(id);
    if (agentId === null) {
      reply.code(400);
      return { error: "bad agent id" };
    }
    const before = parseIntOrNull(q.before);
    const limit = parseInt(q.limit ?? "50", 10) || 50;
    return { rows: await listAgentMessages(agentId, before, limit) };
  });

  app.get("/api/memory", async (req) => {
    const q = req.query as Record<string, string | undefined>;
    return { rows: await listMemory(parseIntOrNull(q.agent_id)) };
  });

  app.get("/api/users", async () => ({ rows: await listUsers() }));

  app.get("/api/config", async (req) => {
    const q = req.query as Record<string, string | undefined>;
    const rows = await listConfig(parseIntOrNull(q.agent_id));
    // Secrets masked before they ever leave the server.
    return { rows: maskConfig(rows) };
  });

  app.get("/api/blobs", async (req) => {
    const q = req.query as Record<string, string | undefined>;
    return { rows: await listBlobs(parseIntOrNull(q.agent_id)) };
  });

  // Re-export for parity / future use (e.g. a counts-only widget).
  app.get("/api/workflows/count", async (req) => {
    const q = req.query as Record<string, string | undefined>;
    return { count: await countWorkflows({
      status: parseStrOrNull(q.status),
      type: parseStrOrNull(q.type),
      agent: parseStrOrNull(q.agent),
      q: parseStrOrNull(q.q),
    }) };
  });
}
