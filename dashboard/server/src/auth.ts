import type { FastifyInstance, FastifyRequest, FastifyReply } from "fastify";
import { config } from "./config.js";

const TOKEN_PREFIX = "Bearer ";

// When DASHBOARD_TOKEN is set, every /api request must carry
// `Authorization: Bearer <token>`. A missing/wrong token yields 401, which the
// SPA treats as "prompt for token". When the env var is unset, auth is open
// (host exposure is already limited to loopback by the compose port mapping).
//
// Asset requests such as GET /api/media/:id/thumbnail are rendered via <img>,
// which cannot attach an Authorization header, so a ?token=<token> query param
// is accepted as a fallback (the web client appends it only when a token is
// stored; the native clients send the header through their HTTP stacks).
export function registerAuth(app: FastifyInstance): void {
  app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
    if (!req.url.startsWith("/api/")) return;
    if (!config.dashboardToken) return;

    const header = req.headers.authorization;
    const headerOk = typeof header === "string" && header.startsWith(TOKEN_PREFIX)
      && header.slice(TOKEN_PREFIX.length) === config.dashboardToken;
    // req.query isn't parsed yet at the onRequest stage, so pull the param off
    // the raw URL ourselves.
    const queryOk = (() => {
      try {
        return new URL(req.url, "http://x").searchParams.get("token") === config.dashboardToken;
      } catch {
        return false;
      }
    })();
    if (!headerOk && !queryOk) {
      reply.code(401).send({ error: "unauthorized" });
      return reply;
    }
  });
}
