// Small formatting helpers shared across pages.

export function timeAgo(iso: string | null | undefined): string {
  if (!iso) return "—";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return iso;
  const s = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  return `${d}d ago`;
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "—";
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return iso;
  return new Date(iso).toLocaleString();
}

export function formatBytes(n: number | string | null | undefined): string {
  const num = typeof n === "string" ? parseInt(n, 10) : n;
  if (num == null || Number.isNaN(num)) return "—";
  if (num < 1024) return `${num} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = num / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(v >= 100 ? 0 : 1)} ${units[i]}`;
}

export function formatMs(ms: number | null | undefined): string {
  if (ms == null) return "—";
  if (ms < 1000) return `${ms} ms`;
  return `${(ms / 1000).toFixed(1)} s`;
}

// Format a duration in seconds (e.g. an HLS playlist's total runtime). Used by
// the Media page; the server sends total_duration as a float8 seconds sum.
export function formatDuration(seconds: number | string | null | undefined): string {
  const n = typeof seconds === "string" ? parseFloat(seconds) : seconds;
  if (n == null || Number.isNaN(n) || n <= 0) return "—";
  if (n < 60) return `${n.toFixed(n < 10 ? 1 : 0)}s`;
  const m = Math.floor(n / 60);
  const s = Math.round(n % 60);
  if (m < 60) return `${m}m ${s}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

// Truncate a SQL query for table cells; full text kept in the title attribute.
export function truncate(s: string | null | undefined, n = 100): string {
  if (!s) return "";
  const one = s.replace(/\s+/g, " ").trim();
  return one.length > n ? one.slice(0, n) + "…" : one;
}
