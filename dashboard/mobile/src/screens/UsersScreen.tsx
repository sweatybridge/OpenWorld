import { useQuery } from "@tanstack/react-query";
import { StyleSheet, Text, View } from "react-native";
import { apiGet } from "../lib/api";
import { timeAgo } from "../lib/format";
import { DataTable, ErrorState, Scroll, Spinner } from "../components";
import { colors } from "../lib/theme";
import type { AppDrawerScreenProps } from "../nav/types";

type Props = AppDrawerScreenProps<"Users">;
type Row = Record<string, unknown>;

export function UsersScreen(_: Props) {
  const { data, isLoading, error } = useQuery({
    queryKey: ["users"],
    queryFn: () => apiGet<{ rows: Row[] }>("/api/users"),
  });

  return (
    <Scroll>
      <Text style={s.h1}>Users</Text>
      {error ? (
        <ErrorState message={(error as Error).message} />
      ) : isLoading ? (
        <Spinner />
      ) : (
        <DataTable
          rows={data?.rows ?? []}
          columns={[
            {
              key: "id",
              header: "id",
              width: 70,
              cell: (r) => <Text style={s.mono}>{String(r.id)}</Text>,
            },
            {
              key: "channel",
              header: "channel",
              width: 110,
              cell: (r) => <Text style={s.cell}>{String(r.channel)}</Text>,
            },
            {
              key: "ext",
              header: "external id",
              width: 150,
              cell: (r) => (
                <Text style={s.mono} numberOfLines={1}>
                  {String(r.external_id)}
                </Text>
              ),
            },
            {
              key: "name",
              header: "username",
              cell: (r) => (
                <Text style={s.cell} numberOfLines={1}>
                  {String(r.username ?? r.display_name ?? "—")}
                </Text>
              ),
            },
            {
              key: "tier",
              header: "tier",
              width: 90,
              cell: (r) => (
                <View style={s.tier}>
                  <Text style={s.tierText}>{String(r.tier)}</Text>
                </View>
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
  cell: { color: colors.text, fontSize: 13 },
  mono: { color: colors.text, fontFamily: "monospace", fontSize: 12 },
  tier: {
    paddingHorizontal: 8,
    paddingVertical: 1,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel2,
    alignSelf: "flex-start",
  },
  tierText: { color: colors.text, fontSize: 12, textTransform: "lowercase" },
});
