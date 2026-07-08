import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet } from "../lib/api";
import { formatBytes, timeAgo, truncate } from "../lib/format";
import { AgentPills, DataTable, ErrorState, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Blobs">;
type Row = Record<string, unknown>;

export function BlobsScreen({ route }: Props) {
  const [agentId, setAgentId] = useState(route.params?.agentId ?? "");
  useEffect(() => {
    if (route.params?.agentId != null) setAgentId(route.params.agentId);
  }, [route.params?.agentId]);

  const query = useQuery({
    queryKey: ["blobs", agentId],
    queryFn: () =>
      apiGet<{ rows: Row[] }>(
        "/api/blobs" + (agentId ? `?agent_id=${agentId}` : ""),
      ),
  });

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>Blobs</Text>
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
              key: "agent",
              header: "agent",
              width: 70,
              cell: (r) => <Text style={s.cell}>{String(r.agent_id)}</Text>,
            },
            {
              key: "hash",
              header: "hash",
              width: 200,
              cell: (r) => (
                <Text style={s.mono} numberOfLines={1}>
                  {truncate(String(r.hash), 24)}
                </Text>
              ),
            },
            {
              key: "size",
              header: "size",
              width: 90,
              cell: (r) => (
                <Text style={s.cell}>
                  {formatBytes(r.size == null ? null : Number(r.size))}
                </Text>
              ),
            },
            {
              key: "created",
              header: "created",
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
});
