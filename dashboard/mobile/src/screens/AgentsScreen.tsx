import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text } from "react-native";
import { apiGet, type AgentRow } from "../lib/api";
import { timeAgo } from "../lib/format";
import { DataTable, ErrorState, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Agents">;

// Wide table — scrolls horizontally like the web. Each row taps through to the
// agent's message stream.
export function AgentsScreen({ navigation }: Props) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["agents"],
    queryFn: () => apiGet<{ rows: AgentRow[] }>("/api/agents").then((r) => r.rows),
  });

  if (isLoading) return <Spinner />;
  if (error)
    return (
      <Scroll>
        <ErrorState message={(error as Error).message} />
      </Scroll>
    );

  return (
    <Scroll>
      <Text style={s.h1}>Agents</Text>
      <DataTable
        rows={data ?? []}
        onRow={(a) => navigation.navigate("Messages", { agentId: String(a.id) })}
        columns={[
          {
            key: "slug",
            header: "slug",
            width: 120,
            cell: (a) => (
              <Text style={s.slug} numberOfLines={1}>
                {a.slug}
              </Text>
            ),
          },
          {
            key: "enabled",
            header: "on",
            width: 40,
            cell: (a) => <Text style={a.enabled ? s.ok : s.dead}>{a.enabled ? "●" : "○"}</Text>,
          },
          {
            key: "model",
            header: "model",
            width: 150,
            cell: (a) => (
              <Text style={s.cell} numberOfLines={2}>
                {a.model_name ?? "—"}
                {"\n"}
                <Text style={s.muted}>{a.api_base ?? ""}</Text>
              </Text>
            ),
          },
          {
            key: "max_turn",
            header: "max turn",
            width: 80,
            cell: (a) => <Text style={s.cell}>{a.max_turn}</Text>,
          },
          {
            key: "ctx",
            header: "ctx tokens",
            width: 100,
            cell: (a) => <Text style={s.cell}>{a.context_tokens ?? "—"}</Text>,
          },
          {
            key: "temp",
            header: "temp / effort",
            width: 120,
            cell: (a) => (
              <Text style={s.cell}>
                {a.temperature ?? "—"} / {a.reasoning_effort ?? "—"}
              </Text>
            ),
          },
          {
            key: "msg",
            header: "messages",
            width: 90,
            cell: (a) => <Text style={s.cell}>{a.msg_count}</Text>,
          },
          {
            key: "mem",
            header: "memory",
            width: 80,
            cell: (a) => <Text style={s.cell}>{a.mem_count}</Text>,
          },
          {
            key: "wf",
            header: "workflows",
            width: 90,
            cell: (a) => <Text style={s.cell}>{a.wf_count}</Text>,
          },
          {
            key: "updated",
            header: "updated",
            width: 90,
            cell: (a) => <Text style={s.cell}>{timeAgo(a.updated_at)}</Text>,
          },
        ]}
      />
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  slug: { color: colors.accent, fontWeight: "700", fontSize: 13 },
  ok: { color: colors.ok, fontSize: 13 },
  dead: { color: colors.err, fontSize: 13 },
  cell: { color: colors.text, fontSize: 13 },
  muted: { color: colors.muted, fontSize: 11 },
});
