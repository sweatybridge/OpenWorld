import type { ConfigRow } from "./types.js";

// ow.config rows with secret=true hold API keys / tokens. They NEVER leave
// the server in plaintext — we redact the value regardless of the caller. An
// operator who needs the real value uses psql.
export function maskConfig(rows: ConfigRow[]): ConfigRow[] {
  return rows.map((r) =>
    r.secret ? { ...r, value: { redacted: true } } : r
  );
}

// Telegram bot tokens have a stable shape: <bot_id>:<base64ish>. The agent
// loop / inbox / send graphs call ow._telegram_api_url (which reads
// telegram_token from secret config) and pass the resulting
//   https://api.telegram.org/bot<token>/<method>
// URL to df.http / df.http_multipart. df persists that resolved URL inside
// df.instance_nodes.query / .result (and df.instance_executions.output / the
// top-level df.result), so the literal token would otherwise surface in the
// workflow-detail / turn-trace API responses. Redact the pattern everywhere
// it appears before any of those payloads leave the server; an operator who
// needs the real token uses psql (same posture as maskConfig).
const TELEGRAM_BOT_TOKEN = /\b\d{6,}:[A-Za-z0-9_-]{20,}\b/g;

export function redactTelegramTokens(input: string): string {
  return input.replace(TELEGRAM_BOT_TOKEN, "***:***");
}

// Deep-walk a value produced by df (workflowDetail / traceTurn payloads) and
// redact the bot-token pattern inside every string it contains. Non-string
// leaves and the { redacted: true } sentinel are passed through unchanged.
export function redactTelegramTokensDeep<T>(value: T): T {
  if (typeof value === "string") {
    return redactTelegramTokens(value) as unknown as T;
  }
  if (Array.isArray(value)) {
    return value.map(redactTelegramTokensDeep) as unknown as T;
  }
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = redactTelegramTokensDeep(v);
    }
    return out as unknown as T;
  }
  return value;
}
