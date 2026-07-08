import { useQuery } from "@tanstack/react-query";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { apiGet, type Overview, type WorkflowList } from "../lib/api";
import { REFRESH_MS } from "../hooks";
import { formatDateTime, timeAgo } from "../lib/format";
import {
  Card,
  DataTable,
  EmptyState,
  ErrorState,
  Scroll,
  Spinner,
  StatusBadge,
  TypePill,
} from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Overview">;

export function OverviewScreen({ navigation }: Props) {
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
  if (overview.error)
    return (
      <Scroll>
        <ErrorState message={(overview.error as Error).message} />
      </Scroll>
    );

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
    <Scroll
      refreshing={overview.isFetching}
      onRefresh={() => {
        overview.refetch();
        recent.refetch();
      }}
    >
      <Text style={s.h1}>Overview</Text>

      <View style={s.metricGrid}>
        {metricCards.map(([label, val]) => (
          <View key={label} style={s.metric}>
            <Text style={s.metricVal}>{String(val)}</Text>
            <Text style={s.metricLabel}>{label}</Text>
          </View>
        ))}
      </View>

      <Card title="pg_durable worker">
        {o.worker ? (
          <View>
            <View style={s.kvRow}>
              <Text style={s.kvK}>status</Text>
              <View style={s.row}>
                <View style={[s.dot, workerAlive ? s.dotAlive : s.dotDead]} />
                <Text style={s.kvV}>{workerAlive ? "alive" : "stale / down"}</Text>
              </View>
            </View>
            <View style={s.kvRow}>
              <Text style={s.kvK}>last heartbeat</Text>
              <Text style={s.kvV}>
                {o.worker.age_seconds != null
                  ? `${o.worker.age_seconds.toFixed(1)}s ago`
                  : "—"}
              </Text>
            </View>
            <View style={s.kvRow}>
              <Text style={s.kvK}>started</Text>
              <Text style={s.kvV}>{formatDateTime(o.worker.started_at)}</Text>
            </View>
          </View>
        ) : (
          <EmptyState>Worker liveness unavailable.</EmptyState>
        )}
      </Card>

      <Card title="By status">
        {o.by_status.length === 0 ? (
          <EmptyState>No instances.</EmptyState>
        ) : (
          <View>
            {o.by_status.map((r) => (
              <Pressable
                key={r.status}
                style={({ pressed }) => [s.countRow, pressed && s.pressed]}
                onPress={() => navigation.navigate("Workflows", { status: r.status })}
              >
                <StatusBadge status={r.status} />
                <Text style={s.num}>{r.count}</Text>
              </Pressable>
            ))}
          </View>
        )}
      </Card>

      <Card title="By type">
        {o.by_type.length === 0 ? (
          <EmptyState>No instances.</EmptyState>
        ) : (
          <View>
            {o.by_type.map((r) => (
              <Pressable
                key={r.type}
                style={({ pressed }) => [s.countRow, pressed && s.pressed]}
                onPress={() => navigation.navigate("Workflows", { type: r.type })}
              >
                <TypePill type={r.type} />
                <Text style={s.num}>{r.count}</Text>
              </Pressable>
            ))}
          </View>
        )}
      </Card>

      <Card title="Agents">
        {(o.agents ?? []).length === 0 ? (
          <EmptyState>No agents.</EmptyState>
        ) : (
          <View>
            {(o.agents ?? []).map((a) => (
              <Pressable
                key={a.id}
                style={({ pressed }) => [s.countRow, pressed && s.pressed]}
                onPress={() => navigation.navigate("Messages", { agentId: String(a.id) })}
              >
                <View style={[s.dot, a.enabled ? s.dotAlive : s.dotDead]} />
                <Text style={s.countLabel}>{a.slug}</Text>
              </Pressable>
            ))}
          </View>
        )}
      </Card>

      <Card title="Recent failed workflows">
        {recent.isLoading ? (
          <Spinner />
        ) : (
          <DataTable
            rows={recent.data?.rows ?? []}
            onRow={(r) => navigation.navigate("WorkflowDetail", { id: r.id })}
            columns={[
              {
                key: "id",
                header: "id",
                width: 140,
                cell: (r) => (
                  <Text style={s.mono} numberOfLines={1}>
                    {r.id}
                  </Text>
                ),
              },
              {
                key: "label",
                header: "label",
                cell: (r) => (
                  <Text style={s.cell} numberOfLines={1}>
                    {r.label}
                  </Text>
                ),
              },
              { key: "type", header: "type", cell: (r) => <TypePill type={r.type} /> },
              {
                key: "status",
                header: "status",
                cell: (r) => <StatusBadge status={r.status} />,
              },
              {
                key: "updated",
                header: "updated",
                cell: (r) => <Text style={s.cell}>{timeAgo(r.updated_at)}</Text>,
              },
            ]}
          />
        )}
      </Card>
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  metricGrid: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "space-between",
    marginBottom: 8,
  },
  metric: {
    width: "48%",
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    padding: 14,
    marginBottom: 12,
  },
  metricVal: { fontSize: 24, fontWeight: "700", color: colors.text },
  metricLabel: { color: colors.muted, fontSize: 12, marginTop: 2 },
  kvRow: { flexDirection: "row", paddingVertical: 3, gap: 12 },
  kvK: { color: colors.muted, fontSize: 13, width: 120 },
  kvV: { color: colors.text, fontSize: 13, flexShrink: 1 },
  row: { flexDirection: "row", alignItems: "center", gap: 8 },
  dot: { width: 9, height: 9, borderRadius: 5, backgroundColor: colors.pend },
  dotAlive: { backgroundColor: colors.ok },
  dotDead: { backgroundColor: colors.err },
  countRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 10,
    paddingVertical: 6,
  },
  countLabel: { color: colors.text, fontSize: 14, flex: 1 },
  num: { color: colors.muted, fontSize: 14, marginLeft: "auto" },
  pressed: { opacity: 0.6 },
  mono: { color: colors.accent, fontFamily: "monospace", fontSize: 12 },
  cell: { color: colors.text, fontSize: 13 },
});
