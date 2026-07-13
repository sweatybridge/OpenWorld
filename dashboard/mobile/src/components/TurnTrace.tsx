import { useQuery } from "@tanstack/react-query";
import { useNavigation } from "@react-navigation/native";
import { StyleSheet, Text } from "react-native";
import { apiGet, type TraceRow } from "../lib/api";
import { REFRESH_MS } from "../hooks";
import { timeAgo } from "../lib/format";
import { colors } from "../lib/theme";
import type { AppNav } from "../nav/types";
import {
  DataTable,
  EmptyState,
  ErrorState,
  JsonView,
  Spinner,
  StatusBadge,
  TypePill,
} from ".";
import type { Column } from "./DataTable";

// The correlated df.instances for one agent turn (loop parent + typing/tool/send
// children), looked up by message id. Tapping a row opens that instance's
// WorkflowDetail. Shared by TraceScreen and the WorkflowDetail trace card.
export function TurnTraceTable({ messageId }: { messageId: number }) {
  const navigation = useNavigation<AppNav>();
  const trace = useQuery({
    queryKey: ["trace", messageId],
    queryFn: () => apiGet<{ rows: TraceRow[] }>(`/api/trace/${messageId}`),
    refetchInterval: REFRESH_MS,
  });

  if (trace.isLoading) return <Spinner />;
  if (trace.error)
    return <ErrorState message={(trace.error as Error).message} />;
  const rows = trace.data?.rows ?? [];
  if (rows.length === 0)
    return <EmptyState>No correlated instances for this turn.</EmptyState>;

  const columns: Column<TraceRow>[] = [
    { key: "kind", header: "kind", width: 90, cell: (r) => <TypePill type={r.kind} /> },
    {
      key: "id",
      header: "instance",
      width: 110,
      cell: (r) => (
        <Text style={s.mono} numberOfLines={1}>
          {r.instance_id.slice(0, 8)}
        </Text>
      ),
    },
    {
      key: "msg",
      header: "message",
      width: 90,
      cell: (r) => <Text style={s.v}>{r.message_id ? `#${r.message_id}` : "—"}</Text>,
    },
    {
      key: "tc",
      header: "tool call",
      width: 150,
      cell: (r) =>
        r.tool_call_id ? (
          <Text style={s.mono} numberOfLines={1}>
            {r.tool_call_id}
          </Text>
        ) : (
          <Text style={s.v}>—</Text>
        ),
    },
    { key: "status", header: "status", width: 110, cell: (r) => <StatusBadge status={r.status} /> },
    {
      key: "updated",
      header: "updated",
      width: 100,
      cell: (r) => <Text style={s.v}>{timeAgo(r.updated_at)}</Text>,
    },
    { key: "result", header: "result", width: 160, cell: (r) => <JsonView value={r.result} /> },
  ];

  return (
    <DataTable
      rows={rows}
      columns={columns}
      onRow={(r) => navigation.navigate("WorkflowDetail", { id: r.instance_id })}
    />
  );
}

const s = StyleSheet.create({
  v: { color: colors.muted, fontSize: 13 },
  mono: { color: colors.text, fontFamily: "monospace", fontSize: 12 },
});
