// Runtime configuration, all from environment (compose injects these).
export const config = {
  pg: {
    host: required("PGHOST", "harness"),
    port: parseInt(process.env.PGPORT ?? "5432", 10),
    database: process.env.PGDATABASE ?? "postgres",
    user: required("PGUSER", "ow_dashboard"),
    password: process.env.PGPASSWORD ?? "dashboard",
  },
  port: parseInt(process.env.PORT ?? "8088", 10),
  // Optional shared secret. When set, every /api request must carry
  // `Authorization: Bearer <token>`. Host exposure is already restricted to
  // loopback by the compose port mapping; this adds app-level auth for when the
  // port is republished more broadly.
  dashboardToken: process.env.DASHBOARD_TOKEN ?? "",
};

function required(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) {
    throw new Error(`Missing required env var ${name}`);
  }
  return v;
}
