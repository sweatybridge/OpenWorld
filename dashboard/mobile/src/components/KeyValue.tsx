import { StyleSheet, Text, View } from "react-native";
import type { ReactNode } from "react";
import { colors } from "../lib/theme";

// Renders a label/value list, the mobile analogue of the web .kv <dl>.
export function KeyValue({ items }: { items: Array<[string, ReactNode]> }) {
  return (
    <View>
      {items.map(([k, v], i) => (
        <View key={k + i} style={s.row}>
          <Text style={s.key}>{k}</Text>
          <View style={s.val}>{v}</View>
        </View>
      ))}
    </View>
  );
}

const s = StyleSheet.create({
  row: {
    flexDirection: "row",
    paddingVertical: 3,
    gap: 12,
  },
  key: { color: colors.muted, fontSize: 13, width: 120 },
  val: { flex: 1 },
});
