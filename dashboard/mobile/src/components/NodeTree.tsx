import { useState } from "react";
import { Pressable, StyleSheet, Text, View } from "react-native";
import type { InstanceNode } from "../lib/api";
import { colors, statusColor } from "../lib/theme";
import { truncate } from "../lib/format";
import { JsonView } from "./JsonView";
import { EmptyState } from "./States";

const NODE_MARKER: Record<string, string> = {
  completed: "✓",
  failed: "✗",
  running: "⏳",
  pending: "○",
  cancelled: "✗",
};

// Recursive rendering of a pg_durable node graph. Same roots/childId logic as
// the web NodeTree: a node is a root when no other node points at it via
// left_node / right_node; children follow those pointers.
export function NodeTree({ nodes }: { nodes: InstanceNode[] }) {
  if (nodes.length === 0) {
    return <EmptyState>No nodes recorded for this instance.</EmptyState>;
  }
  const byId = new Map(nodes.map((n) => [n.node_id, n]));
  const childIds = new Set<string>();
  for (const n of nodes) {
    if (n.left_node != null) childIds.add(n.left_node);
    if (n.right_node != null) childIds.add(n.right_node);
  }
  const roots = nodes.filter((n) => !childIds.has(n.node_id));
  return (
    <View>
      {roots.map((r) => (
        <NodeRow key={r.node_id} node={r} byId={byId} depth={0} />
      ))}
    </View>
  );
}

function NodeRow({
  node,
  byId,
  depth,
}: {
  node: InstanceNode;
  byId: Map<string, InstanceNode>;
  depth: number;
}) {
  const [openResult, setOpenResult] = useState(false);
  const left = node.left_node != null ? byId.get(node.left_node) : null;
  const right = node.right_node != null ? byId.get(node.right_node) : null;
  const marker = NODE_MARKER[node.status ?? ""] ?? "•";
  const markerColor = statusColor(node.status);
  const queryOne = node.query ? truncate(node.query, 90) : "";
  return (
    <View style={{ paddingLeft: depth * 18, paddingVertical: 2 }}>
      <View style={s.line}>
        <Text style={[s.marker, { color: markerColor }]}>{marker}</Text>
        <Text style={s.type}>{node.node_type}</Text>
        {node.result_name != null && (
          <Text style={s.name}>|=&gt; {node.result_name}</Text>
        )}
        {queryOne ? (
          <Text style={s.query} numberOfLines={1}>
            {queryOne}
          </Text>
        ) : null}
      </View>
      {node.result != null && (
        <View style={{ marginTop: 2 }}>
          <Pressable onPress={() => setOpenResult((o) => !o)} hitSlop={8}>
            <Text style={s.toggle}>
              {openResult ? "▾ result" : "▸ result"}
            </Text>
          </Pressable>
          {openResult && <JsonView value={node.result} defaultOpen={false} />}
        </View>
      )}
      {left ? <NodeRow node={left} byId={byId} depth={depth + 1} /> : null}
      {right ? <NodeRow node={right} byId={byId} depth={depth + 1} /> : null}
    </View>
  );
}

const s = StyleSheet.create({
  line: { flexDirection: "row", flexWrap: "wrap", alignItems: "flex-start", gap: 8 },
  marker: { width: 14, fontFamily: "monospace", fontSize: 13 },
  type: { color: colors.accent, fontWeight: "700", fontFamily: "monospace", fontSize: 13 },
  name: { color: colors.warn, fontFamily: "monospace", fontSize: 13 },
  query: { color: colors.muted, fontFamily: "monospace", fontSize: 13, flexShrink: 1 },
  toggle: { color: colors.accent, fontSize: 12, paddingVertical: 2 },
});
