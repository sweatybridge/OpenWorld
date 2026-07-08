import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet, type WorkflowDetail } from "../lib/api";
import { REFRESH_MS } from "../hooks";
import { formatMs } from "../lib/format";
import {
  Card,
  DataTable,
  EmptyState,
  ErrorState,
  JsonView,
  KeyValue,
  NodeTree,
  Scroll,
  Spinner,
  StatusBadge,
} from "../components";
import { colors } from "../lib/theme";
import type { WorkflowDetailScreenProps } from "../nav/types";

type Props = WorkflowDetailScreenProps;

export function WorkflowDetailScreen({ route }: Props) {
  const id = route.params.id;
  const detail = useQuery({
    queryKey: ["workflow", id],
    queryFn: () => apiGet<WorkflowDetail>(`/api/workflows/${id}`),
    refetchInterval: REFRESH_MS,
  });

  if (detail.isLoading) return <Spinner />;
  if (detail.error)
    return (
      <Scroll>
        <ErrorState message={(detail.error as Error).message} />
      </Scroll>
    );
  const d = detail.data;
  if (!d)
    return (
      <Scroll>
        <EmptyState>Not found.</EmptyState>
      </Scroll>
    );

  const info = (d.info ?? {}) as Record<string, unknown>;
  const label = String(info.label ?? id);
  const currentNodes = d.nodes.filter(
    (n) => n.execution_id === d.current_execution_id,
  );

  return (
    <Scroll refreshing={detail.isFetching} onRefresh={() => detail.refetch()}>
      <View style={s.head}>
        <Text style={s.id} numberOfLines={1}>
          {id}
        </Text>
        <View style={s.sub}>
          <Text style={s.label} numberOfLines={1}>
            {label}
          </Text>
          <StatusBadge status={String(info.status ?? "")} />
        </View>
      </View>

      <Card title="Instance info">
        <KeyValue
          items={[
            ["status", <StatusBadge key="s" status={String(info.status ?? "")} />],
            ["label", <Text key="l" style={s.v}>{String(info.label ?? "—")}</Text>],
            [
              "function",
              <Text key="f" style={s.mono}>
                {String(info.function_name ?? "—")}
              </Text>,
            ],
            [
              "version",
              <Text key="v" style={s.v}>
                {String(info.function_version ?? "—")}
              </Text>,
            ],
            [
              "current execution",
              <Text key="e" style={s.mono}>
                {d.current_execution_id ?? "—"}
              </Text>,
            ],
            ["output", <JsonView key="o" value={info.output} />],
          ]}
        />
      </Card>

      <Card title="Final result">
        <JsonView value={d.result} defaultOpen />
      </Card>

      <Card
        title={
          currentNodes.length !== d.nodes.length && d.current_execution_id
            ? `Node graph · execution ${d.current_execution_id}`
            : "Node graph"
        }
      >
        <NodeTree nodes={currentNodes} />
      </Card>

      <Card title="Executions">
        <DataTable
          rows={d.executions as Array<Record<string, unknown>>}
          columns={[
            {
              key: "execution_id",
              header: "execution",
              width: 150,
              cell: (r) => (
                <Text style={s.mono} numberOfLines={1}>
                  {String(r.execution_id)}
                </Text>
              ),
            },
            {
              key: "status",
              header: "status",
              cell: (r) => <StatusBadge status={String(r.status ?? "")} />,
            },
            {
              key: "events",
              header: "events",
              cell: (r) => <Text style={s.v}>{String(r.event_count ?? "—")}</Text>,
            },
            {
              key: "duration",
              header: "duration",
              cell: (r) => (
                <Text style={s.v}>
                  {formatMs(r.duration_ms == null ? null : Number(r.duration_ms))}
                </Text>
              ),
            },
            {
              key: "output",
              header: "output",
              cell: (r) => <JsonView value={r.output} />,
            },
          ]}
        />
      </Card>

      {d.explain ? (
        <Card title="df.explain">
          <Text style={s.explain}>{d.explain}</Text>
        </Card>
      ) : null}
    </Scroll>
  );
}

const s = StyleSheet.create({
  head: { marginBottom: 16 },
  id: { color: colors.text, fontFamily: "monospace", fontSize: 15, fontWeight: "700" },
  sub: { flexDirection: "row", alignItems: "center", gap: 10, marginTop: 4 },
  label: { color: colors.muted, fontSize: 13, flexShrink: 1 },
  v: { color: colors.text, fontSize: 13 },
  mono: { color: colors.text, fontFamily: "monospace", fontSize: 12 },
  explain: {
    color: colors.text,
    fontFamily: "monospace",
    fontSize: 12,
    backgroundColor: colors.panel2,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 6,
    padding: 10,
  },
});
