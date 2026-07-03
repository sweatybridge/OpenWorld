import pg from "pg";
import { config } from "./config.js";

// Single shared pool. The attobot_dashboard role is BYPASSRLS + SELECT/EXECUTE
// only, so this connection can read everything but write nothing.
export const pool = new pg.Pool({
  host: config.pg.host,
  port: config.pg.port,
  database: config.pg.database,
  user: config.pg.user,
  password: config.pg.password,
  max: 8,
  idleTimeoutMillis: 30_000,
  // The pg_durable worker / agent-init may not be ready the instant the dashboard
  // starts. Let the pool retry via query-level handling rather than failing fast.
  connectionTimeoutMillis: 10_000,
});

export async function query<T extends pg.QueryResultRow = pg.QueryResultRow>(
  text: string,
  params?: ReadonlyArray<unknown>
): Promise<pg.QueryResult<T>> {
  return pool.query<T>(text, params as unknown as Array<unknown>);
}
