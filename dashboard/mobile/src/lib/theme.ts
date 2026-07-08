// Visual palette — mirrored from the web dashboard (dashboard/web/src/styles.css :root).
// Keeping these in sync makes the mobile client feel like the same product.

export const colors = {
  bg: "#0f1115",
  panel: "#171a21",
  panel2: "#1e222b",
  border: "#2a2f3a",
  text: "#e6e8ec",
  muted: "#9aa3b2",
  accent: "#4f9cf9",
  ok: "#3fb950",
  warn: "#d29922",
  err: "#f85149",
  run: "#4f9cf9",
  pend: "#8b949e",
  cancel: "#db6d28",
} as const;

// status string -> foreground/border colour, mirroring the web .st-* classes.
export const STATUS_COLOR: Record<string, string> = {
  completed: colors.ok,
  failed: colors.err,
  running: colors.run,
  pending: colors.pend,
  cancelled: colors.cancel,
  cancelled_: colors.cancel, // (defensive; web groups cancelled under --cancel)
  unknown: colors.pend,
};

export function statusColor(status: string | null | undefined): string {
  const s = (status ?? "unknown").toString();
  return STATUS_COLOR[s] ?? colors.pend;
}
