import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, TextInput, View } from "react-native";
import { apiGet, type WorkflowList } from "../lib/api";
import { REFRESH_MS, STATUS_OPTIONS, TYPE_OPTIONS } from "../hooks";
import { timeAgo } from "../lib/format";
import {
  AgentPills,
  DataTable,
  ErrorState,
  FilterPills,
  Pager,
  Scroll,
  StatusBadge,
  TypePill,
} from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Workflows">;
const LIMIT = 50;

export function WorkflowsScreen({ navigation, route }: Props) {
  const [status, setStatus] = useState(route.params?.status ?? "");
  const [type, setType] = useState(route.params?.type ?? "");
  const [agent, setAgent] = useState(route.params?.agent ?? "");
  const [q, setQ] = useState("");
  const [debouncedQ, setDebouncedQ] = useState("");
  const [offset, setOffset] = useState(0);

  // Debounce the search box so we don't fire a query per keystroke.
  useEffect(() => {
    const t = setTimeout(() => {
      setDebouncedQ(q);
      setOffset(0);
    }, 300);
    return () => clearTimeout(t);
  }, [q]);

  // Re-seed filters when navigated here with new params (e.g. Overview -> by status).
  useEffect(() => {
    if (route.params?.status != null) setStatus(route.params.status);
    if (route.params?.type != null) setType(route.params.type);
    if (route.params?.agent != null) setAgent(route.params.agent);
  }, [route.params]);

  const query = useQuery({
    queryKey: ["workflows", { status, type, agent, debouncedQ, offset }],
    queryFn: () =>
      apiGet<WorkflowList>(
        `/api/workflows?limit=${LIMIT}&offset=${offset}` +
          (status ? `&status=${encodeURIComponent(status)}` : "") +
          (type ? `&type=${encodeURIComponent(type)}` : "") +
          (agent ? `&agent=${encodeURIComponent(agent)}` : "") +
          (debouncedQ ? `&q=${encodeURIComponent(debouncedQ)}` : ""),
      ),
    refetchInterval: REFRESH_MS,
  });

  const setFilter =
    (fn: (v: string) => void) => (v: string) => {
      fn(v);
      setOffset(0);
    };

  const rows = query.data?.rows ?? [];

  return (
    <Scroll refreshing={query.isFetching} onRefresh={() => query.refetch()}>
      <Text style={s.h1}>Workflows</Text>

      <View style={s.edgeless}>
        <FilterPills
          options={STATUS_OPTIONS}
          value={status}
          onSelect={setFilter(setStatus)}
          allLabel="any status"
        />
        <FilterPills
          options={TYPE_OPTIONS}
          value={type}
          onSelect={setFilter(setType)}
          allLabel="any type"
        />
        <AgentPills value={agent} onSelect={setFilter(setAgent)} />
      </View>

      <TextInput
        style={s.input}
        value={q}
        onChangeText={setQ}
        placeholder="search label / id…"
        placeholderTextColor={colors.muted}
        autoCapitalize="none"
        autoCorrect={false}
      />

      {query.error ? (
        <ErrorState message={(query.error as Error).message} />
      ) : (
        <DataTable
          rows={rows}
          onRow={(r) => navigation.navigate("WorkflowDetail", { id: r.id })}
          columns={[
            {
              key: "id",
              header: "id",
              width: 150,
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
              key: "agent",
              header: "agent",
              cell: (r) => <Text style={s.cell}>{r.agent ?? "—"}</Text>,
            },
            {
              key: "status",
              header: "status",
              cell: (r) => <StatusBadge status={r.status} />,
            },
            {
              key: "by",
              header: "submitted by",
              width: 110,
              cell: (r) => (
                <Text style={s.mono} numberOfLines={1}>
                  {r.submitted_by}
                </Text>
              ),
            },
            {
              key: "updated",
              header: "updated",
              cell: (r) => <Text style={s.cell}>{timeAgo(r.updated_at)}</Text>,
            },
          ]}
        />
      )}

      <Pager
        offset={offset}
        limit={LIMIT}
        total={query.data?.total ?? 0}
        onPage={setOffset}
      />
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  edgeless: { marginHorizontal: -16, marginBottom: 8 },
  input: {
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 6,
    paddingHorizontal: 12,
    paddingVertical: 8,
    color: colors.text,
    fontSize: 13,
    marginBottom: 12,
  },
  mono: { color: colors.accent, fontFamily: "monospace", fontSize: 12 },
  cell: { color: colors.text, fontSize: 13 },
});
