import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet } from "../lib/api";
import { REFRESH_MS } from "../hooks";
import { timeAgo } from "../lib/format";
import { AgentPills, DataTable, ErrorState, JsonView, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Lifecycle">;
type Row = Record<string, unknown>;

export function LifecycleScreen({ route }: Props) {
  const [agentId, setAgentId] = useState(route.params?.agentId ?? "");
  useEffect(() => {
    if (route.params?.agentId != null) setAgentId(route.params.agentId);
  }, [route.params?.agentId]);

  const query = useQuery({
    queryKey: ["lifecycle", agentId],
    queryFn: () =>
      apiGet<{ rows: Row[] }>(
        "/api/lifecycle?limit=200" + (agentId ? `&agent_id=${agentId}` : ""),
      ),
    refetchInterval: REFRESH_MS,
  });

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>Lifecycle</Text>
      <View style={s.edgeless}>
        <AgentPills value={agentId} onSelect={setAgentId} />
      </View>
      {query.error ? (
        <ErrorState message={(query.error as Error).message} />
      ) : query.isLoading ? (
        <Spinner />
      ) : (
        <DataTable
          rows={query.data?.rows ?? []}
          columns={[
            {
              key: "id",
              header: "id",
              width: 70,
              cell: (r) => <Text style={s.mono}>{String(r.id)}</Text>,
            },
            {
              key: "agent",
              header: "agent",
              width: 70,
              cell: (r) => <Text style={s.cell}>{String(r.agent_id ?? "—")}</Text>,
            },
            {
              key: "event",
              header: "event",
              width: 130,
              cell: (r) => (
                <Text style={s.event}>{String(r.event)}</Text>
              ),
            },
            {
              key: "detail",
              header: "detail",
              cell: (r) => <JsonView value={r.detail} />,
            },
            {
              key: "time",
              header: "time",
              width: 90,
              cell: (r) => <Text style={s.cell}>{timeAgo(String(r.created_at))}</Text>,
            },
          ]}
        />
      )}
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  edgeless: { marginHorizontal: -16, marginBottom: 8 },
  cell: { color: colors.text, fontSize: 13 },
  mono: { color: colors.text, fontFamily: "monospace", fontSize: 12 },
  event: { color: colors.text, fontWeight: "700", fontSize: 13 },
});
