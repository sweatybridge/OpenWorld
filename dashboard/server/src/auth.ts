import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import { config } from "./config.js";

const TOKEN_PREFIX = "Bearer ";

// When DASHBOARD_TOKEN is set, every /api request must carry
// `Authorization: Bearer <token>`. A missing/wrong token yields 401, which the
// SPA treats as "prompt for token". When the env var is unset, auth is open
// (host exposure is already limited to loopback by the compose port mapping).
export function registerAuth(app: FastifyInstance): void {
  app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
    if (!req.url.startsWith("/api/")) return;
    if (!config.dashboardToken) return;

    const header = req.headers.authorization;
    const ok = typeof header === "string" && header.startsWith(TOKEN_PREFIX)
      && header.slice(TOKEN_PREFIX.length) === config.dashboardToken;
    if (!ok) {
      reply.code(401).send({ error: "unauthorized" });
      return reply;
    }
  });
}
