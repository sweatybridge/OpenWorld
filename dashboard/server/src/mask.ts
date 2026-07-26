import type { ConfigRow } from "./types.js";

// OpenWorld.config rows with secret=true hold API keys / tokens. They NEVER leave
// the server in plaintext — we redact the value regardless of the caller. An
// operator who needs the real value uses psql.
export function maskConfig(rows: ConfigRow[]): ConfigRow[] {
  return rows.map((r) =>
    r.secret ? { ...r, value: { redacted: true } } : r
  );
}
