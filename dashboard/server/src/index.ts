import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import Fastify from "fastify";
import fastifyStatic from "@fastify/static";
import { config } from "./config.js";
import { registerAuth } from "./auth.js";
import { registerRoutes } from "./routes.js";

async function resolveStaticDir(): Promise<string | null> {
  const candidates = [
    process.env.STATIC_DIR ? resolve(process.env.STATIC_DIR) : null,
    join(__dirname, "..", "public"), // docker runtime: /app/public
    join(__dirname, "..", "..", "web", "dist"), // local dev run from server/
  ].filter(Boolean) as string[];
  for (const c of candidates) {
    if (c && existsSync(join(c, "index.html"))) return c;
  }
  return null;
}

async function main(): Promise<void> {
  const app = Fastify({ logger: true });

  registerAuth(app);
  await registerRoutes(app);

  const staticDir = await resolveStaticDir();
  if (staticDir) {
    // Standard SPA recipe: serve static files under "/", and fall back to
    // index.html for unknown non-/api paths so client-side routing (e.g.
    // /workflows/abc12345) survives a refresh. API routes are registered above
    // and match before the static wildcard.
    await app.register(fastifyStatic, { root: staticDir, prefix: "/" });
    app.setNotFoundHandler((req, reply) => {
      if (req.url.startsWith("/api/")) {
        reply.code(404);
        return { error: "not found" };
      }
      return reply.sendFile("index.html");
    });
  } else {
    app.log.warn("No built SPA found (web/dist). Serving API only.");
  }

  try {
    await app.listen({ host: "0.0.0.0", port: config.port });
    app.log.info({ staticDir }, `attobot dashboard on http://0.0.0.0:${config.port}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

main().catch((e) => {
  // eslint-disable-next-line no-console
  console.error(e);
  process.exit(1);
});
