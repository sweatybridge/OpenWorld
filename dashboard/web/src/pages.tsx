import { useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { apiGet, type Overview, type WorkflowList, type WorkflowDetail, type AgentRow, type MessageRow, type ConfigRow, type TraceRow } from "./api";
import { messageIdFromLabel } from "./label";
import {
  Card, Column, DataTable, EmptyState, ErrorState, JsonText, JsonView, NodeTree,
  Pager, Spinner, StatusBadge, TypePill,
} from "./components";
import { formatBytes, formatDateTime, formatMs, timeAgo, truncate } from "./format";

const REFRESH_MS = 5000;

// Shared agent selector for filterable pages.
export function useAgents() {
  return useQuery({
    queryKey: ["agents"],
    queryFn: () => apiGet<{ rows: AgentRow[] }>("/api/agents").then((r) => r.rows),
    staleTime: 60_000,
  });
}

function AgentSelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const { data } = useAgents();
  return (
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      <option value="">all agents</option>
      {(data ?? []).map((a) => <option key={a.id} value={a.slug}>{a.slug}</option>)}
    </select>
  );
}

// ---------------------------------------------------------------- overview

export function OverviewPage() {
  const overview = useQuery({
    queryKey: ["overview"],
    queryFn: () => apiGet<Overview>("/api/overview"),
    refetchInterval: REFRESH_MS,
  });
  const recent = useQuery({
    queryKey: ["workflows", { status: "failed", limit: 8 }],
    queryFn: () => apiGet<WorkflowList>("/api/workflows?status=failed&limit=8"),
    refetchInterval: REFRESH_MS,
  });

  if (overview.isLoading) return <Spinner />;
  if (overview.error) return <ErrorState message={(overview.error as Error).message} />;
  const o = overview.data!;
  const m = o.metrics ?? {};
  const workerAlive = o.worker != null && (o.worker.age_seconds ?? 999) < 15;

  const metricCards: Array<[string, string | number]> = [
    ["total instances", m.total_instances ?? "—"],
    ["running", m.running_instances ?? "—"],
    ["completed", m.completed_instances ?? "—"],
    ["failed", m.failed_instances ?? "—"],
    ["total executions", m.total_executions ?? "—"],
    ["total events", m.total_events ?? "—"],
  ];

  return (
    <>
      <h1>Overview</h1>
      <div className="metric-grid">
        {metricCards.map(([label, val]) => (
          <div className="metric" key={label}>
            <div className="metric-val">{val as React.ReactNode}</div>
            <div className="metric-label">{label}</div>
          </div>
        ))}
      </div>

      <div className="grid-2">
        <Card title="pg_durable worker">
          {o.worker ? (
            <dl className="kv">
              <dt>status</dt>
              <dd>
                <span className={`dot ${workerAlive ? "alive" : "dead"}`} />
                {workerAlive ? "alive" : "stale / down"}
              </dd>
              <dt>last heartbeat</dt>
              <dd>{o.worker.age_seconds != null ? `${o.worker.age_seconds.toFixed(1)}s ago` : "—"}</dd>
              <dt>started</dt>
              <dd>{formatDateTime(o.worker.started_at)}</dd>
            </dl>
          ) : <EmptyState>Worker liveness unavailable.</EmptyState>}
        </Card>

        <Card title="By status">
          {o.by_status.length === 0 ? <EmptyState>No instances.</EmptyState> : (
            <ul className="counts">
              {o.by_status.map((r) => (
                <li key={r.status}>
                  <Link to={`/workflows?status=${encodeURIComponent(r.status)}`}>
                    <StatusBadge status={r.status} /> <span className="num">{r.count}</span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card title="By type">
          {o.by_type.length === 0 ? <EmptyState>No instances.</EmptyState> : (
            <ul className="counts">
              {o.by_type.map((r) => (
                <li key={r.type}>
                  <Link to={`/workflows?type=${encodeURIComponent(r.type)}`}>
                    <TypePill type={r.type} /> <span className="num">{r.count}</span>
                  </Link>
                </li>
              ))}
            </ul>
          )}
        </Card>

        <Card title="Agents">
          <ul className="counts">
            {(o.agents ?? []).map((a) => (
              <li key={a.id}>
                <Link to={`/messages?agent_id=${a.id}`}>
                  <span className={`dot ${a.enabled ? "alive" : "dead"}`} />
                  {a.slug}
                </Link>
              </li>
            ))}
          </ul>
        </Card>
      </div>

      <Card title="Recent failed workflows" right={<Link to="/workflows?status=failed">all →</Link>}>
        {recent.isLoading ? <Spinner /> : (
          <DataTable
            rows={recent.data?.rows ?? []}
            columns={[
              { key: "id", header: "id", cell: (r) => <Link to={`/workflows/${r.id}`}><code>{r.id}</code></Link> },
              { key: "label", header: "label", cell: (r) => <span className="cell-break">{r.label}</span> },
              { key: "type", header: "type", cell: (r) => <TypePill type={r.type} /> },
              { key: "status", header: "status", cell: (r) => <StatusBadge status={r.status} /> },
              { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(r.updated_at)}>{timeAgo(r.updated_at)}</span> },
            ]}
          />
        )}
      </Card>
    </>
  );
}

// ---------------------------------------------------------------- workflows list

export function WorkflowsPage() {
  const [params, setParams] = useSearchParams();
  const status = params.get("status") ?? "";
  const type = params.get("type") ?? "";
  const agent = params.get("agent") ?? "";
  const q = params.get("q") ?? "";
  const offset = parseInt(params.get("offset") ?? "0", 10) || 0;
  const limit = 50;

  const set = (k: string, v: string) => {
    const next = new URLSearchParams(params);
    if (v) next.set(k, v); else next.delete(k);
    if (k !== "offset") next.delete("offset");
    setParams(next);
  };

  const query = useQuery({
    queryKey: ["workflows", { status, type, agent, q, offset }],
    queryFn: () => apiGet<WorkflowList>(
      `/api/workflows?limit=${limit}&offset=${offset}` +
      (status ? `&status=${encodeURIComponent(status)}` : "") +
      (type ? `&type=${encodeURIComponent(type)}` : "") +
      (agent ? `&agent=${encodeURIComponent(agent)}` : "") +
      (q ? `&q=${encodeURIComponent(q)}` : "")
    ),
    refetchInterval: REFRESH_MS,
  });

  const rows = query.data?.rows ?? [];
  const columns: Column<typeof rows[number]>[] = [
    { key: "id", header: "id", cell: (r) => <Link to={`/workflows/${r.id}`}><code>{r.id}</code></Link> },
    { key: "label", header: "label", cell: (r) => <span title={r.label} className="cell-break">{r.label}</span> },
    { key: "type", header: "type", cell: (r) => <TypePill type={r.type} /> },
    { key: "agent", header: "agent", cell: (r) => r.agent ?? "—" },
    { key: "status", header: "status", cell: (r) => <StatusBadge status={r.status} /> },
    { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(r.updated_at)}>{timeAgo(r.updated_at)}</span> },
  ];

  return (
    <>
      <h1>Workflows</h1>
      <div className="filters">
        <select value={status} onChange={(e) => set("status", e.target.value)}>
          <option value="">any status</option>
          {["pending", "running", "completed", "failed", "cancelled"].map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <select value={type} onChange={(e) => set("type", e.target.value)}>
          <option value="">any type</option>
          {["loop", "inbox", "cron", "send", "tool", "typing", "other"].map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
        <AgentSelect value={agent} onChange={(v) => set("agent", v)} />
        <input placeholder="search label / id…" value={q} onChange={(e) => set("q", e.target.value)} />
      </div>
      {query.error ? <ErrorState message={(query.error as Error).message} /> : (
        <DataTable rows={rows} columns={columns} />
      )}
      <Pager offset={offset} limit={limit} total={query.data?.total ?? 0} onPage={(o) => set("offset", String(o))} />
    </>
  );
}

// ---------------------------------------------------------------- workflow detail

export function WorkflowDetailPage() {
  const { id } = useParams<{ id: string }>();
  const [flipped, setFlipped] = useState(false);
  const detail = useQuery({
    queryKey: ["workflow", id],
    queryFn: () => apiGet<WorkflowDetail>(`/api/workflows/${id}`),
    refetchInterval: REFRESH_MS,
    enabled: !!id,
  });

  if (detail.isLoading) return <Spinner />;
  if (detail.error) return <ErrorState message={(detail.error as Error).message} />;
  const d = detail.data;
  if (!d) return <EmptyState>Not found.</EmptyState>;

  const info = (d.info ?? {}) as Record<string, unknown>;
  const label = String(info.label ?? id);
  const currentNodes = d.nodes.filter((n) => n.execution_id === d.current_execution_id);

  return (
    <>
      <div className="detail-head">
        <Link to="/workflows" className="back">‹ workflows</Link>
        <h1><code>{id}</code></h1>
        <div className="detail-sub">
          <span title={label}>{label}</span>
          <StatusBadge status={String(info.status ?? "")} />
        </div>
      </div>

      <div className="grid-2">
        <Card title="Instance info">
          <dl className="kv">
            <dt>status</dt><dd><StatusBadge status={String(info.status ?? "")} /></dd>
            <dt>label</dt><dd>{String(info.label ?? "—")}</dd>
            <dt>function</dt><dd><code>{String(info.function_name ?? "—")}</code></dd>
            <dt>version</dt><dd>{String(info.function_version ?? "—")}</dd>
            <dt>current execution</dt><dd>{d.current_execution_id ?? "—"}</dd>
            <dt>output</dt><dd><JsonView value={info.output} /></dd>
          </dl>
        </Card>

        <Card title="Final result">
          <JsonView value={d.result} defaultOpen={true} />
        </Card>
      </div>

      <Card
        title={`Node graph${currentNodes.length !== d.nodes.length ? ` · execution ${d.current_execution_id}` : ""}`}
        right={
          <button
            className="btn"
            onClick={() => setFlipped((f) => !f)}
            title={`Showing ${flipped ? "execution order (sources on top)" : "plan order (sink on top)"} — click for ${flipped ? "plan order (sink on top)" : "execution order (sources on top)"}`}
          >
            ⇅ {flipped ? "execution order" : "plan order"}
          </button>
        }
      >
        <NodeTree nodes={currentNodes} flipped={flipped} />
      </Card>

      <Card title="Executions">
        <DataTable
          rows={d.executions as Array<Record<string, unknown>>}
          columns={[
            { key: "execution_id", header: "execution", cell: (r) => <code>{String(r.execution_id)}</code> },
            { key: "status", header: "status", cell: (r) => <StatusBadge status={String(r.status ?? "")} /> },
            { key: "events", header: "events", cell: (r) => String(r.event_count ?? "—") },
            { key: "duration", header: "duration", cell: (r) => formatMs(r.duration_ms == null ? null : Number(r.duration_ms)) },
            { key: "output", header: "output", cell: (r) => <JsonView value={r.output} /> },
          ]}
        />
      </Card>

      <TurnTraceCard label={label} />

      {d.explain && (
        <Card title="df.explain">
          <pre className="explain">{d.explain}</pre>
        </Card>
      )}
    </>
  );
}

// The correlated instances for the turn this instance belongs to (loop parent +
// typing/tool/send children), looked up by the message id embedded in the label.
// Only shown for traceable labels (loop/send/tool/typing).
function TurnTraceCard({ label }: { label: string }) {
  const messageId = messageIdFromLabel(label);
  if (messageId == null) return null;
  return (
    <Card title={`Turn trace · msg #${messageId}`} right={<Link to={`/trace/${messageId}`} className="link">open ›</Link>}>
      <TurnTraceTable messageId={messageId} />
    </Card>
  );
}

function TurnTraceTable({ messageId }: { messageId: number }) {
  const trace = useQuery({
    queryKey: ["trace", messageId],
    queryFn: () => apiGet<{ rows: TraceRow[] }>(`/api/trace/${messageId}`),
    refetchInterval: REFRESH_MS,
  });
  if (trace.isLoading) return <Spinner />;
  if (trace.error) return <ErrorState message={(trace.error as Error).message} />;
  const rows = trace.data?.rows ?? [];
  if (rows.length === 0) return <EmptyState>No correlated instances for this turn.</EmptyState>;
  const columns: Column<TraceRow>[] = [
    { key: "kind", header: "kind", cell: (r) => <TypePill type={r.kind} /> },
    { key: "id", header: "instance", cell: (r) => <Link to={`/workflows/${r.instance_id}`} title={r.instance_id}><code>{r.instance_id.slice(0, 8)}</code></Link> },
    { key: "msg", header: "message", cell: (r) => (r.message_id ? `#${r.message_id}` : "—") },
    { key: "tc", header: "tool call", cell: (r) => (r.tool_call_id ? <code>{r.tool_call_id}</code> : "—") },
    { key: "status", header: "status", cell: (r) => <StatusBadge status={r.status} /> },
    { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(r.updated_at)}>{timeAgo(r.updated_at)}</span> },
    { key: "result", header: "result", cell: (r) => <JsonView value={r.result} /> },
  ];
  return <DataTable rows={rows} columns={columns} />;
}

// ---------------------------------------------------------------- trace

// Full turn trace for any message id. Resolves the turn's trigger on the server,
// so it works from a user, assistant, or tool message alike.
export function TracePage() {
  const { messageId } = useParams<{ messageId: string }>();
  const id = Number(messageId);
  return (
    <>
      <div className="detail-head">
        <Link to="/messages" className="back">‹ messages</Link>
        <h1>Turn trace · msg #{messageId}</h1>
      </div>
      {!Number.isFinite(id) ? (
        <ErrorState message="bad message id" />
      ) : (
        <Card title="Correlated instances">
          <TurnTraceTable messageId={id} />
        </Card>
      )}
    </>
  );
}

// ---------------------------------------------------------------- agents

export function AgentsPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["agents"],
    queryFn: () => apiGet<{ rows: AgentRow[] }>("/api/agents").then((r) => r.rows),
  });
  if (isLoading) return <Spinner />;
  if (error) return <ErrorState message={(error as Error).message} />;
  const rows = data ?? [];
  const columns: Column<AgentRow>[] = [
    { key: "slug", header: "slug", cell: (a) => <Link to={`/messages?agent_id=${a.id}`}><strong>{a.slug}</strong></Link> },
    { key: "enabled", header: "enabled", cell: (a) => <span className={`dot ${a.enabled ? "alive" : "dead"}`} /> },
    { key: "model", header: "model", cell: (a) => <span>{a.model_name ?? "—"}<br /><small>{a.api_base}</small></span> },
    { key: "max_turn", header: "max turn", cell: (a) => a.max_turn },
    { key: "ctx", header: "ctx tokens", cell: (a) => a.context_tokens ?? "—" },
    { key: "temp", header: "temp / effort", cell: (a) => `${a.temperature ?? "—"} / ${a.reasoning_effort ?? "—"}` },
    { key: "msg", header: "messages", cell: (a) => a.msg_count },
    { key: "mem", header: "memory", cell: (a) => <Link to={`/memory?agent_id=${a.id}`}>{a.mem_count}</Link> },
    { key: "wf", header: "workflows", cell: (a) => <Link to={`/workflows?agent=${a.id}`}>{a.wf_count}</Link> },
    { key: "updated", header: "updated", cell: (a) => <span title={formatDateTime(a.updated_at)}>{timeAgo(a.updated_at)}</span> },
  ];
  return (
    <>
      <h1>Agents</h1>
      <DataTable rows={rows} columns={columns} />
    </>
  );
}

// ---------------------------------------------------------------- messages

export function MessagesPage() {
  const [params] = useSearchParams();
  const agentId = params.get("agent_id") ?? "";
  const [before, setBefore] = useState<number | null>(null);
  const { data: agents } = useAgents();
  const agent = (agents ?? []).find((a) => String(a.id) === agentId) ?? null;

  const query = useQuery({
    queryKey: ["messages", agentId, before],
    queryFn: () => apiGet<{ rows: MessageRow[] }>(
      `/api/agents/${agentId}/messages?limit=50` + (before ? `&before=${before}` : "")
    ),
    enabled: !!agentId,
  });

  if (!agentId) {
    return (
      <>
        <h1>Messages</h1>
        <div className="filters"><span>Pick an agent: </span>
          {(agents ?? []).map((a) => <Link key={a.id} to={`/messages?agent_id=${a.id}`} className="pill-link">{a.slug}</Link>)}
        </div>
      </>
    );
  }

  const rows = (query.data?.rows ?? []).slice().reverse(); // oldest-on-top reading order
  const oldest = rows[0]?.id ?? null;

  return (
    <>
      <div className="detail-head">
        <h1>Messages · {agent?.slug ?? `agent ${agentId}`}</h1>
      </div>
      {query.error ? <ErrorState message={(query.error as Error).message} /> : query.isLoading ? <Spinner /> : (
        <div className="msg-stream">
          {rows.length === 0 && <EmptyState>No messages.</EmptyState>}
          {rows.map((m) => <MessageBubble key={m.id} m={m} />)}
        </div>
      )}
      {oldest != null && rows.length > 0 && (
        <button className="btn" onClick={() => setBefore(oldest)}>Load older</button>
      )}
    </>
  );
}

function MessageBubble({ m }: { m: MessageRow }) {
  const payload = m.payload as Record<string, unknown> | null;
  const toolCalls = Array.isArray(payload?.tool_calls) ? (payload!.tool_calls as Array<Record<string, unknown>>) : [];
  return (
    <div className={`msg msg-${m.role}`}>
      <div className="msg-meta">
        <span className="msg-role">{m.role}</span>
        <span className="msg-id">#{m.id}</span>
        {m.channel && <span className="msg-chan">{m.channel}</span>}
        {m.tool_call_id && <span className="msg-chan">tc {m.tool_call_id}</span>}
        <Link to={`/trace/${m.id}`} className="link" title="Trace this turn's workflows">trace</Link>
        <span className="msg-time" title={formatDateTime(m.created_at)}>{timeAgo(m.created_at)}</span>
      </div>
      {m.content && <div className="msg-content">{m.content}</div>}
      {toolCalls.length > 0 && (
        <ul className="tool-calls">
          {toolCalls.map((tc, i) => (
            <li key={i}><code>{String(tc.name ?? "")}</code> <JsonView value={tc.arguments ?? tc.args} /></li>
          ))}
        </ul>
      )}
      {payload && Object.keys(payload).length > 0 && toolCalls.length === 0 && (
        <details className="node-result"><summary>payload</summary><JsonText value={payload} /></details>
      )}
    </div>
  );
}

// ---------------------------------------------------------------- memory

export function MemoryPage() {
  const [params, setParams] = useSearchParams();
  const agentId = params.get("agent_id") ?? "";
  const query = useQuery({
    queryKey: ["memory", agentId],
    queryFn: () => apiGet<{ rows: Array<Record<string, unknown>> }>(
      `/api/memory` + (agentId ? `?agent_id=${agentId}` : "")
    ),
  });
  const rows = query.data?.rows ?? [];
  return (
    <>
      <h1>Memory</h1>
      <div className="filters">
        <AgentSelect value={agentId} onChange={(v) => { const n = new URLSearchParams(params); v ? n.set("agent_id", v) : n.delete("agent_id"); setParams(n); }} />
      </div>
      {query.error ? <ErrorState message={(query.error as Error).message} /> : query.isLoading ? <Spinner /> : (
        <DataTable
          rows={rows}
          columns={[
            { key: "id", header: "id", cell: (r) => <code>{String(r.id)}</code> },
            { key: "agent", header: "agent", cell: (r) => String(r.agent_id) },
            { key: "content", header: "content", cell: (r) => <span>{truncate(String(r.content ?? ""), 160)}</span> },
            { key: "enabled", header: "enabled", cell: (r) => <span className={`dot ${r.enabled ? "alive" : "dead"}`} /> },
            { key: "sources", header: "sources", cell: (r) => String((r.source_message_ids as unknown[] | null)?.length ?? 0) },
            { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(String(r.updated_at))}>{timeAgo(String(r.updated_at))}</span> },
          ]}
        />
      )}
    </>
  );
}

// ---------------------------------------------------------------- users

export function UsersPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["users"],
    queryFn: () => apiGet<{ rows: Array<Record<string, unknown>> }>("/api/users"),
  });
  if (isLoading) return <Spinner />;
  if (error) return <ErrorState message={(error as Error).message} />;
  return (
    <>
      <h1>Users</h1>
      <DataTable
        rows={data?.rows ?? []}
        columns={[
          { key: "id", header: "id", cell: (r) => <code>{String(r.id)}</code> },
          { key: "channel", header: "channel", cell: (r) => String(r.channel) },
          { key: "ext", header: "external id", cell: (r) => <code>{String(r.external_id)}</code> },
          { key: "name", header: "username", cell: (r) => String(r.username ?? r.display_name ?? "—") },
          { key: "tier", header: "tier", cell: (r) => <span className="pill">{String(r.tier)}</span> },
          { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(String(r.updated_at))}>{timeAgo(String(r.updated_at))}</span> },
        ]}
      />
    </>
  );
}

// ---------------------------------------------------------------- config

export function ConfigPage() {
  const [params, setParams] = useSearchParams();
  const agentId = params.get("agent_id") ?? "";
  const query = useQuery({
    queryKey: ["config", agentId],
    queryFn: () => apiGet<{ rows: ConfigRow[] }>(
      `/api/config` + (agentId ? `?agent_id=${agentId}` : "")
    ),
  });
  const rows = query.data?.rows ?? [];
  return (
    <>
      <h1>Config</h1>
      <div className="filters">
        <AgentSelect value={agentId} onChange={(v) => { const n = new URLSearchParams(params); v ? n.set("agent_id", v) : n.delete("agent_id"); setParams(n); }} />
        <span className="hint">secrets are redacted server-side — use <code>psql</code> to read values</span>
      </div>
      {query.error ? <ErrorState message={(query.error as Error).message} /> : query.isLoading ? <Spinner /> : (
        <DataTable
          rows={rows}
          columns={[
            { key: "agent", header: "agent", cell: (r) => String(r.agent_id) },
            { key: "key", header: "key", cell: (r) => <code>{r.key}</code> },
            { key: "value", header: "value", cell: (r) => r.secret ? <span className="redacted">•••••• (secret)</span> : <JsonView value={r.value} /> },
            { key: "secret", header: "secret", cell: (r) => (r.secret ? "yes" : "no") },
            { key: "updated", header: "updated", cell: (r) => <span title={formatDateTime(r.updated_at)}>{timeAgo(r.updated_at)}</span> },
          ]}
        />
      )}
    </>
  );
}

// ---------------------------------------------------------------- blobs

export function BlobsPage() {
  const [params, setParams] = useSearchParams();
  const agentId = params.get("agent_id") ?? "";
  const query = useQuery({
    queryKey: ["blobs", agentId],
    queryFn: () => apiGet<{ rows: Array<Record<string, unknown>> }>(
      `/api/blobs` + (agentId ? `?agent_id=${agentId}` : "")
    ),
  });
  const rows = query.data?.rows ?? [];
  return (
    <>
      <h1>Blobs</h1>
      <div className="filters">
        <AgentSelect value={agentId} onChange={(v) => { const n = new URLSearchParams(params); v ? n.set("agent_id", v) : n.delete("agent_id"); setParams(n); }} />
      </div>
      {query.error ? <ErrorState message={(query.error as Error).message} /> : query.isLoading ? <Spinner /> : (
        <DataTable
          rows={rows}
          columns={[
            { key: "agent", header: "agent", cell: (r) => String(r.agent_id) },
            { key: "hash", header: "hash", cell: (r) => <code>{truncate(String(r.hash), 24)}</code> },
            { key: "size", header: "size", cell: (r) => formatBytes(r.size == null ? null : Number(r.size)) },
            { key: "created", header: "created", cell: (r) => <span title={formatDateTime(String(r.created_at))}>{timeAgo(String(r.created_at))}</span> },
          ]}
        />
      )}
    </>
  );
}
