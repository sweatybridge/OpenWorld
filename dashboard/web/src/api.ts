// Typed read-only API client. The server is view-only; every call is a GET.
// Token auth: if the server has DASHBOARD_TOKEN set, a missing/wrong bearer token
// yields 401, which we surface as AuthError so the UI can prompt.

const TOKEN_KEY = "attobot_dashboard_token";

export class AuthError extends Error {
  constructor() {
    super("unauthorized");
    this.name = "AuthError";
  }
}

export function getToken(): string {
  return localStorage.getItem(TOKEN_KEY) ?? "";
}

export function setToken(token: string): void {
  if (token) localStorage.setItem(TOKEN_KEY, token);
  else localStorage.removeItem(TOKEN_KEY);
}

async function apiFetch(path: string): Promise<Response> {
  const headers: Record<string, string> = {};
  const t = getToken();
  if (t) headers["Authorization"] = "Bearer " + t;
  let res: Response;
  try {
    res = await fetch(path, { headers });
  } catch {
    throw new Error("Cannot reach the dashboard API. Is the server running?");
  }
  if (res.status === 401) throw new AuthError();
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
  return res;
}

export async function apiGet<T>(path: string): Promise<T> {
  const res = await apiFetch(path);
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

// ---- Response shapes (mirror the server) -------------------------------

export type InstanceStatus = "pending" | "running" | "completed" | "failed" | "cancelled";

export interface WorkflowRow {
  id: string;
  label: string;
  status: InstanceStatus | string;
  submitted_by: string;
  db: string | null;
  updated_at: string;
  type: string;
  agent: string | null;
}
export interface WorkflowList {
  rows: WorkflowRow[];
  total: number;
  limit: number;
  offset: number;
}

export interface InstanceNode {
  execution_id: string;
  node_id: string;
  node_type: string;
  query: string | null;
  result_name: string | null;
  left_node: string | null;
  right_node: string | null;
  status: string | null;
  result: string | null;
}
export interface WorkflowDetail {
  info: Record<string, unknown> | null;
  explain: string | null;
  result: unknown;
  nodes: InstanceNode[];
  current_execution_id: string | null;
  executions: Array<Record<string, unknown>>;
}

// One row of a turn trace: the df.instances correlated to a single agent turn
// (loop parent + typing/tool/send children), joined on message id.
export interface TraceRow {
  instance_id: string;
  kind: string; // loop|typing|tool|send|...
  agent_slug: string | null;
  message_id: string | null; // bigint arrives as a string
  tool_call_id: string | null;
  status: string;
  updated_at: string;
  result: unknown;
}
export interface TraceResponse {
  rows: TraceRow[];
}

export interface Overview {
  metrics: Record<string, string | number> | null;
  worker: { started_at: string | null; last_seen_at: string | null; age_seconds: number | null } | null;
  by_type: Array<{ type: string; count: string }>;
  by_status: Array<{ status: string; count: string }>;
  agents: Array<{ id: number; slug: string; enabled: boolean }>;
}

export interface AgentRow {
  id: number; slug: string; soul: string; enabled: boolean; max_turn: number;
  model_id: number; model_name: string | null; api_base: string | null;
  temperature: string | null; reasoning_effort: string | null;
  context_tokens: number | null; multimodal_support: boolean | null;
  created_at: string; updated_at: string;
  msg_count: string; mem_count: string; wf_count: string;
}
export interface MessageRow {
  id: number; agent_id: number; role: string; content: string; payload: unknown;
  channel: string | null; chat_id: string | null; tool_call_id: string | null;
  created_at: string;
}
export interface ToolCall {
  id: string; type: "function";
  function: { name: string; arguments: unknown };
}
export interface ConfigRow {
  agent_id: number; key: string; value: unknown; secret: boolean; updated_at: string;
}
