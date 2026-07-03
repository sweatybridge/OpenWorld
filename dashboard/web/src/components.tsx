import { useState, type ReactNode } from "react";

// ---------------------------------------------------------------- status pill

const STATUS_CLASS: Record<string, string> = {
  running: "st-running",
  pending: "st-pending",
  completed: "st-completed",
  failed: "st-failed",
  cancelled: "st-cancelled",
};

export function StatusBadge({ status }: { status: string | null | undefined }) {
  const s = (status ?? "unknown").toString();
  return <span className={`badge ${STATUS_CLASS[s] ?? "st-unknown"}`}>{s}</span>;
}

export function TypePill({ type }: { type: string }) {
  return <span className="pill">{type}</span>;
}

// ---------------------------------------------------------------- primitives

export function Spinner({ label = "Loading…" }: { label?: string }) {
  return (
    <div className="centered">
      <div className="spinner" /> <span>{label}</span>
    </div>
  );
}

export function ErrorState({ message }: { message: string }) {
  return <div className="error-box">⚠️ {message}</div>;
}

export function EmptyState({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function Card({ title, children, right }: { title?: ReactNode; children: ReactNode; right?: ReactNode }) {
  return (
    <section className="card">
      {(title || right) && (
        <header className="card-head">
          <h2>{title}</h2>
          {right}
        </header>
      )}
      <div className="card-body">{children}</div>
    </section>
  );
}

// ---------------------------------------------------------------- table

export interface Column<T> {
  key: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
}

export function DataTable<T>({ columns, rows, onRow }: {
  columns: Column<T>[];
  rows: T[];
  onRow?: (row: T) => void;
}) {
  return (
    <table className="data-table">
      <thead>
        <tr>{columns.map((c) => <th key={c.key}>{c.header}</th>)}</tr>
      </thead>
      <tbody>
        {rows.length === 0 && (
          <tr><td className="empty" colSpan={columns.length}>No rows.</td></tr>
        )}
        {rows.map((row, i) => (
          <tr key={i} className={onRow ? "clickable" : ""} onClick={onRow ? () => onRow(row) : undefined}>
            {columns.map((c) => <td key={c.key}>{c.cell(row)}</td>)}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

// ---------------------------------------------------------------- json view

export function JsonView({ value, defaultOpen = false }: { value: unknown; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  let text: string;
  if (typeof value === "string") {
    // Many pg results come back as a JSON string; pretty-print if it parses.
    try {
      text = JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      text = value;
    }
  } else if (value == null) {
    text = "null";
  } else {
    text = JSON.stringify(value, null, 2);
  }
  return (
    <div className="json-view">
      <button className="link" onClick={() => setOpen((o) => !o)}>{open ? "▾ hide" : "▸ show"}</button>
      {open && <pre>{text}</pre>}
    </div>
  );
}

// ---------------------------------------------------------------- node tree

const NODE_MARKER: Record<string, string> = {
  completed: "✓",
  failed: "✗",
  running: "⏳",
  pending: "○",
  cancelled: "✗",
};

export interface TreeNode {
  node_id: string;
  node_type: string;
  query: string | null;
  result_name: string | null;
  left_node: string | null;
  right_node: string | null;
  status: string | null;
  result: string | null;
}

export function NodeTree({ nodes }: { nodes: TreeNode[] }) {
  if (nodes.length === 0) return <EmptyState>No nodes recorded for this instance.</EmptyState>;
  const byId = new Map(nodes.map((n) => [n.node_id, n]));
  const childIds = new Set<string>();
  for (const n of nodes) {
    if (n.left_node != null) childIds.add(n.left_node);
    if (n.right_node != null) childIds.add(n.right_node);
  }
  const roots = nodes.filter((n) => !childIds.has(n.node_id));
  return (
    <div className="node-tree">
      {roots.map((r) => <Node key={r.node_id} node={r} byId={byId} depth={0} />)}
    </div>
  );
}

function Node({ node, byId, depth }: { node: TreeNode; byId: Map<string, TreeNode>; depth: number }) {
  const left = node.left_node != null ? byId.get(node.left_node) : null;
  const right = node.right_node != null ? byId.get(node.right_node) : null;
  const marker = NODE_MARKER[node.status ?? ""] ?? "•";
  const statusClass = STATUS_CLASS[node.status ?? ""] ?? "st-unknown";
  const queryOne = node.query ? node.query.replace(/\s+/g, " ").trim() : "";
  return (
    <div className="node" style={{ marginLeft: depth * 18 }}>
      <div className={`node-line ${statusClass}`}>
        <span className="node-marker">{marker}</span>
        <span className="node-type">{node.node_type}</span>
        {node.result_name && <span className="node-name">|=&gt; {node.result_name}</span>}
        {queryOne && (
          <code className="node-query" title={node.query ?? ""}>
            {queryOne.length > 90 ? queryOne.slice(0, 90) + "…" : queryOne}
          </code>
        )}
        {node.result && (
          <details className="node-result">
            <summary>result</summary>
            <JsonView value={node.result} defaultOpen={false} />
          </details>
        )}
      </div>
      {left && <Node node={left} byId={byId} depth={depth + 1} />}
      {right && <Node node={right} byId={byId} depth={depth + 1} />}
    </div>
  );
}

// ---------------------------------------------------------------- pagination

export function Pager({ offset, limit, total, onPage }: {
  offset: number; limit: number; total: number; onPage: (offset: number) => void;
}) {
  const page = Math.floor(offset / limit) + 1;
  const pages = Math.max(1, Math.ceil(total / limit));
  return (
    <div className="pager">
      <button disabled={offset === 0} onClick={() => onPage(Math.max(0, offset - limit))}>‹ prev</button>
      <span>page {page} / {pages} · {total} total</span>
      <button disabled={offset + limit >= total} onClick={() => onPage(offset + limit)}>next ›</button>
    </div>
  );
}
