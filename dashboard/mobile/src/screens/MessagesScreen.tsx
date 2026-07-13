import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigation } from "@react-navigation/native";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { apiGet, type MessageRow } from "../lib/api";
import { useAgents } from "../hooks";
import { timeAgo } from "../lib/format";
import { AgentPills, EmptyState, ErrorState, JsonView, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps, AppNav } from "../nav/types";

type Props = AppDrawerScreenProps<"Messages">;

const ROLE_BORDER: Record<string, string> = {
  tool: colors.pend,
  user: colors.accent,
  assistant: colors.ok,
  system: colors.warn,
};

export function MessagesScreen({ route }: Props) {
  const [agentId, setAgentId] = useState(route.params?.agentId ?? "");
  const [before, setBefore] = useState<number | null>(null);

  const { data: agents } = useAgents();
  const agent = (agents ?? []).find((a) => String(a.id) === agentId) ?? null;

  // Re-seed when navigated with a new agentId (from Overview / Agents).
  useEffect(() => {
    if (route.params?.agentId != null) setAgentId(route.params.agentId);
  }, [route.params?.agentId]);
  // Reset paging whenever the selected agent changes.
  useEffect(() => {
    setBefore(null);
  }, [agentId]);

  const query = useQuery({
    queryKey: ["messages", agentId, before],
    queryFn: () =>
      apiGet<{ rows: MessageRow[] }>(
        `/api/agents/${agentId}/messages?limit=50` +
          (before ? `&before=${before}` : ""),
      ),
    enabled: !!agentId,
  });

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>
        Messages{agent ? ` · ${agent.slug}` : agentId ? ` · agent ${agentId}` : ""}
      </Text>
      <View style={s.edgeless}>
        <AgentPills value={agentId} onSelect={setAgentId} />
      </View>

      {!agentId ? (
        <EmptyState>Pick an agent above.</EmptyState>
      ) : query.error ? (
        <ErrorState message={(query.error as Error).message} />
      ) : query.isLoading ? (
        <Spinner />
      ) : (
        <MessageStream query={query} before={before} setBefore={setBefore} />
      )}
    </Scroll>
  );
}

function MessageStream({
  query,
  before,
  setBefore,
}: {
  query: ReturnType<typeof useQuery<{ rows: MessageRow[] }>>;
  before: number | null;
  setBefore: (n: number | null) => void;
}) {
  const rows = (query.data?.rows ?? []).slice().reverse(); // oldest on top
  const oldest = rows[0]?.id ?? null;
  return (
    <View style={s.stream}>
      {rows.length === 0 && <EmptyState>No messages.</EmptyState>}
      {rows.map((m) => (
        <MessageBubble key={m.id} m={m} />
      ))}
      {oldest != null && rows.length > 0 && (
        <Pressable style={s.btn} onPress={() => setBefore(oldest)}>
          <Text style={s.btnText}>Load older</Text>
        </Pressable>
      )}
      {before == null && null}
    </View>
  );
}

function MessageBubble({ m }: { m: MessageRow }) {
  const navigation = useNavigation<AppNav>();
  const payload = m.payload as Record<string, unknown> | null;
  const toolCalls = Array.isArray(payload?.tool_calls)
    ? (payload!.tool_calls as Array<Record<string, unknown>>)
    : [];
  const border = ROLE_BORDER[m.role] ?? colors.border;
  return (
    <View style={[s.msg, { borderLeftColor: border }]}>
      <View style={s.meta}>
        <Text style={s.role}>{m.role}</Text>
        <Text style={s.metaText}>#{m.id}</Text>
        {m.channel ? <Text style={s.metaText}>{m.channel}</Text> : null}
        {m.tool_call_id ? (
          <Text style={s.metaText}>tc {m.tool_call_id}</Text>
        ) : null}
        <Pressable onPress={() => navigation.navigate("Trace", { messageId: m.id })}>
          <Text style={s.trace}>trace</Text>
        </Pressable>
        <Text style={s.metaTime}>{timeAgo(m.created_at)}</Text>
      </View>
      {m.content ? <Text style={s.content}>{m.content}</Text> : null}
      {toolCalls.length > 0 && (
        <View style={s.toolCalls}>
          {toolCalls.map((tc, i) => (
            <View key={i} style={s.toolCall}>
              <Text style={s.toolName}>{String(tc.name ?? "")}</Text>
              <JsonView value={tc.arguments ?? tc.args} />
            </View>
          ))}
        </View>
      )}
      {payload && Object.keys(payload).length > 0 && toolCalls.length === 0 && (
        <JsonView value={payload} />
      )}
    </View>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  edgeless: { marginHorizontal: -16, marginBottom: 8 },
  stream: { gap: 10 },
  msg: {
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderLeftWidth: 3,
    borderRadius: 10,
    padding: 10,
  },
  meta: { flexDirection: "row", flexWrap: "wrap", gap: 10, marginBottom: 4 },
  role: { textTransform: "uppercase", fontWeight: "700", color: colors.text, fontSize: 12 },
  metaText: { color: colors.muted, fontSize: 12 },
  trace: { color: colors.accent, fontSize: 12 },
  metaTime: { color: colors.muted, fontSize: 12, marginLeft: "auto" },
  content: { color: colors.text, fontSize: 13 },
  toolCalls: { gap: 6, marginTop: 6 },
  toolCall: { paddingLeft: 4 },
  toolName: { color: colors.accent, fontFamily: "monospace", fontSize: 12, marginBottom: 2 },
  btn: {
    alignSelf: "center",
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel,
    borderRadius: 6,
    paddingHorizontal: 16,
    paddingVertical: 8,
    marginTop: 4,
  },
  btnText: { color: colors.accent, fontSize: 13 },
});
