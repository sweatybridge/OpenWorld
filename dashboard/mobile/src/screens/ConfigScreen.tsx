import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet, type ConfigRow } from "../lib/api";
import { timeAgo } from "../lib/format";
import { AgentPills, DataTable, ErrorState, JsonView, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Config">;

export function ConfigScreen({ route }: Props) {
  const [agentId, setAgentId] = useState(route.params?.agentId ?? "");
  useEffect(() => {
    if (route.params?.agentId != null) setAgentId(route.params.agentId);
  }, [route.params?.agentId]);

  const query = useQuery({
    queryKey: ["config", agentId],
    queryFn: () =>
      apiGet<{ rows: ConfigRow[] }>(
        "/api/config" + (agentId ? `?agent_id=${agentId}` : ""),
      ),
  });

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>Config</Text>
      <View style={s.edgeless}>
        <AgentPills value={agentId} onSelect={setAgentId} />
      </View>
      <Text style={s.hint}>
        secrets are redacted server-side — use psql to read values
      </Text>
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
              key: "key",
              header: "key",
              width: 160,
              cell: (r) => (
                <Text style={s.mono} numberOfLines={1}>
                  {r.key}
                </Text>
              ),
            },
            {
              key: "value",
              header: "value",
              cell: (r) =>
                r.secret ? (
                  <Text style={s.redacted}>•••••• (secret)</Text>
                ) : (
                  <JsonView value={r.value} />
                ),
            },
            {
              key: "secret",
              header: "secret",
              width: 70,
              cell: (r) => <Text style={s.cell}>{r.secret ? "yes" : "no"}</Text>,
            },
            {
              key: "updated",
              header: "updated",
              width: 90,
              cell: (r) => <Text style={s.cell}>{timeAgo(r.updated_at)}</Text>,
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
  hint: { color: colors.muted, fontSize: 12, marginBottom: 12, marginTop: -2 },
  cell: { color: colors.text, fontSize: 13 },
  mono: { color: colors.accent, fontFamily: "monospace", fontSize: 12 },
  redacted: { color: colors.muted, fontStyle: "italic", fontSize: 13 },
});
