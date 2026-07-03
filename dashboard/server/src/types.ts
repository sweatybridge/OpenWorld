// Shared response types (the API returns JSON shaped like these).

export type InstanceStatus = "pending" | "running" | "completed" | "failed" | "cancelled";

export interface WorkflowRow {
  id: string;
  label: string;
  status: string;
  submitted_by: string;
  db: string | null;
  updated_at: string;
  type: string; // parsed from label: loop|inbox|cron|send|tool|typing|attobot|other
  agent: string | null; // parsed from label, when present
}

export interface WorkflowListResponse {
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
  value: unknown; // secret rows are masked before leaving the server
  secret: boolean;
  updated_at: string;
}

export interface OverviewResponse {
  metrics: Record<string, unknown> | null;
  worker: { started_at: string | null; last_seen_at: string | null; age_seconds: number | null } | null;
  by_type: Array<{ type: string; count: string }>;
  by_status: Array<{ status: string; count: string }>;
  agents: Array<{ id: number; slug: string; enabled: boolean }>;
}
