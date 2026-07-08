// Typed read-only API client — port of dashboard/web/src/api.ts.
//
// The server is view-only; every call is a GET. If the server has
// DASHBOARD_TOKEN set, a missing/wrong bearer token yields 401, which we surface
// as AuthError so the UI can prompt (SetupScreen). The only changes vs the web
// client: the base URL is configurable (a phone can't reach localhost) and the
// token is read from the in-memory store (backed by SecureStore).

import { baseUrl, token } from "./store";

export class AuthError extends Error {
  constructor() {
    super("unauthorized");
    this.name = "AuthError";
  }
}

async function apiFetch(path: string): Promise<Response> {
  const headers: Record<string, string> = {};
  const t = token();
  if (t) headers["Authorization"] = "Bearer " + t;
  const base = baseUrl();
  // If no base URL is configured, the request is intentionally malformed so the
  // gate routes the user to setup rather than silently hanging.
  const url = base ? base + path : path;
  let res: Response;
  try {
    res = await fetch(url, { headers });
  } catch {
    throw new Error(
      "Cannot reach the dashboard API. Check the server URL and that the host is reachable from this device.",
    );
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

export type InstanceStatus =
  | "pending"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

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

export interface Overview {
  metrics: Record<string, string | number> | null;
  worker: {
    started_at: string | null;
    last_seen_at: string | null;
    age_seconds: number | null;
  } | null;
  by_type: Array<{ type: string; count: string }>;
  by_status: Array<{ status: string; count: string }>;
  agents: Array<{ id: number; slug: string; enabled: boolean }>;
}

export interface AgentRow {
  id: number;
  slug: string;
  soul: string;
  enabled: boolean;
  max_turn: number;
  model_id: number;
  model_name: string | null;
  api_base: string | null;
  temperature: string | null;
  reasoning_effort: string | null;
  context_tokens: number | null;
  multimodal_support: boolean | null;
  created_at: string;
  updated_at: string;
  msg_count: string;
  mem_count: string;
  wf_count: string;
}
export interface MessageRow {
  id: number;
  agent_id: number;
  role: string;
  content: string;
  payload: unknown;
  channel: string | null;
  chat_id: string | null;
  tool_call_id: string | null;
  created_at: string;
}
export interface ConfigRow {
  agent_id: number;
  key: string;
  value: unknown;
  secret: boolean;
  updated_at: string;
}
