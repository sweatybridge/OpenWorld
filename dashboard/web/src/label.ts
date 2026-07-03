// Parse attobot:* durable-instance labels into a friendly type + context.
// The server also derives these in SQL for the list view; this is used for the
// detail page title and badges where only the raw label is available.

export type LabelType =
  | "loop" | "inbox" | "cron" | "send" | "tool" | "typing" | "attobot" | "other";

export interface ParsedLabel {
  type: LabelType;
  agent: string | null;
  ref: string | null; // message id / tool call id / cron name, when present
  friendly: string;
}

const LABEL_META: Record<LabelType, { icon: string; label: string }> = {
  loop: { icon: "🔁", label: "agent loop" },
  inbox: { icon: "📥", label: "telegram inbox" },
  cron: { icon: "⏰", label: "cron" },
  send: { icon: "📤", label: "telegram send" },
  tool: { icon: "🔧", label: "tool call" },
  typing: { icon: "⌨️", label: "typing" },
  attobot: { icon: "🤖", label: "attobot" },
  other: { icon: "•", label: "workflow" },
};

export function labelIcon(type: string): string {
  return (LABEL_META[type as LabelType] ?? LABEL_META.other).icon;
}

export function parseLabel(raw: string): ParsedLabel {
  const parts = raw.split(":");
  if (parts[0] !== "attobot" || parts.length < 2) {
    return { type: "other", agent: null, ref: null, friendly: raw };
  }
  // attobot:<agent>:(loop|inbox)
  if (parts.length === 3 && (parts[2] === "loop" || parts[2] === "inbox")) {
    const type = parts[2] as "loop" | "inbox";
    return { type, agent: parts[1], ref: null, friendly: `${parts[1]} ${LABEL_META[type].label}` };
  }
  // attobot:<agent>:cron:<name>
  if (parts.length >= 4 && parts[2] === "cron") {
    return { type: "cron", agent: parts[1], ref: parts.slice(3).join(":"), friendly: `${parts[1]} cron "${parts.slice(3).join(":")}"` };
  }
  // attobot:send:<id>
  if (parts[1] === "send" && parts.length >= 3) {
    return { type: "send", agent: null, ref: parts[2], friendly: `send msg #${parts[2]}` };
  }
  // attobot:typing:<id>
  if (parts[1] === "typing" && parts.length >= 3) {
    return { type: "typing", agent: null, ref: parts[2], friendly: `typing #${parts[2]}` };
  }
  // attobot:tool:<msg>:<tc>
  if (parts[1] === "tool" && parts.length >= 4) {
    return { type: "tool", agent: null, ref: parts.slice(2).join(":"), friendly: `tool msg #${parts[2]}` };
  }
  return { type: "attobot", agent: null, ref: null, friendly: raw };
}
