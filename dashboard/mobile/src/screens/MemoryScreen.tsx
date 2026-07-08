import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet } from "../lib/api";
import { timeAgo, truncate } from "../lib/format";
import { AgentPills, DataTable, ErrorState, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Memory">;
type Row = Record<string, unknown>;

export function MemoryScreen({ route }: Props) {
  const [agentId, setAgentId] = useState(route.params?.agentId ?? "");
  useEffect(() => {
    if (route.params?.agentId != null) setAgentId(route.params.agentId);
  }, [route.params?.agentId]);

  const query = useQuery({
    queryKey: ["memory", agentId],
    queryFn: () =>
      apiGet<{ rows: Row[] }>(
        "/api/memory" + (agentId ? `?agent_id=${agentId}` : ""),
      ),
  });

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>Memory</Text>
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
              width: 80,
              cell: (r) => <Text style={s.mono}>{String(r.id)}</Text>,
            },
            {
              key: "agent",
              header: "agent",
              width: 70,
              cell: (r) => <Text style={s.cell}>{String(r.agent_id)}</Text>,
            },
            {
              key: "content",
              header: "content",
              cell: (r) => (
                <Text style={s.cell} numberOfLines={3}>
                  {truncate(String(r.content ?? ""), 160)}
                </Text>
              ),
            },
            {
              key: "enabled",
              header: "on",
              width: 40,
              cell: (r) => (
                <Text style={r.enabled ? s.ok : s.dead}>
                  {r.enabled ? "●" : "○"}
                </Text>
              ),
            },
            {
              key: "sources",
              header: "sources",
              width: 80,
              cell: (r) => (
                <Text style={s.cell}>
                  {String((r.source_message_ids as unknown[] | null)?.length ?? 0)}
                </Text>
              ),
            },
            {
              key: "updated",
              header: "updated",
              width: 90,
              cell: (r) => <Text style={s.cell}>{timeAgo(String(r.updated_at))}</Text>,
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
  mono: { color: colors.accent, fontFamily: "monospace", fontSize: 12 },
  ok: { color: colors.ok, fontSize: 13 },
  dead: { color: colors.err, fontSize: 13 },
});
