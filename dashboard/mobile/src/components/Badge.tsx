import { StyleSheet, Text, View } from "react-native";
import { colors, statusColor } from "../lib/theme";

// Lowercased pill mirroring the web .badge / .pill. Status pills are tinted by
// the status colour (web .st-* classes); type pills are neutral.
export function StatusBadge({ status }: { status: string | null | undefined }) {
  const v = (status ?? "unknown").toString();
  const c = statusColor(v);
  return (
    <View style={[s.pill, { borderColor: c }]}>
      <Text style={[s.pillText, { color: c }]}>{v}</Text>
    </View>
  );
}

export function TypePill({ type }: { type: string }) {
  return (
    <View style={s.pill}>
      <Text style={s.pillText}>{type}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  pill: {
    paddingHorizontal: 8,
    paddingVertical: 1,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel2,
    alignSelf: "flex-start",
  },
  pillText: { fontSize: 12, color: colors.text, textTransform: "lowercase" },
});
