import { Pressable, StyleSheet, Text, View } from "react-native";
import { colors } from "../lib/theme";

interface PagerProps {
  offset: number;
  limit: number;
  total: number;
  onPage: (offset: number) => void;
}

export function Pager({ offset, limit, total, onPage }: PagerProps) {
  const page = Math.floor(offset / limit) + 1;
  const pages = Math.max(1, Math.ceil(total / limit));
  return (
    <View style={s.wrap}>
      <Pressable
        style={[s.btn, offset === 0 && s.disabled]}
        disabled={offset === 0}
        onPress={() => onPage(Math.max(0, offset - limit))}
      >
        <Text style={[s.btnText, offset === 0 && s.disabledText]}>‹ prev</Text>
      </Pressable>
      <Text style={s.info}>
        page {page} / {pages} · {total} total
      </Text>
      <Pressable
        style={[s.btn, offset + limit >= total && s.disabled]}
        disabled={offset + limit >= total}
        onPress={() => onPage(offset + limit)}
      >
        <Text style={[s.btnText, offset + limit >= total && s.disabledText]}>
          next ›
        </Text>
      </Pressable>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 14,
    marginTop: 14,
  },
  btn: {
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel,
    borderRadius: 6,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  btnText: { color: colors.accent, fontSize: 13 },
  disabled: { opacity: 0.4 },
  disabledText: { color: colors.muted },
  info: { color: colors.muted, fontSize: 13 },
});
