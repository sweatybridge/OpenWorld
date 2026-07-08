import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import type { ReactNode } from "react";
import { colors } from "../lib/theme";

export function Spinner() {
  return (
    <View style={s.center}>
      <ActivityIndicator color={colors.accent} />
      <Text style={s.muted}>Loading…</Text>
    </View>
  );
}

export function EmptyState({ children }: { children: ReactNode }) {
  return <Text style={s.empty}>{children}</Text>;
}

export function ErrorState({ message }: { message: string }) {
  return (
    <View style={s.errorBox}>
      <Text style={s.errorText}>⚠️ {message}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  center: {
    paddingVertical: 32,
    alignItems: "center",
    justifyContent: "center",
  },
  muted: { color: colors.muted, fontSize: 13, marginTop: 8 },
  empty: {
    color: colors.muted,
    textAlign: "center",
    paddingVertical: 24,
    fontSize: 13,
  },
  errorBox: {
    backgroundColor: "rgba(248,81,73,0.12)",
    borderWidth: 1,
    borderColor: colors.err,
    borderRadius: 8,
    padding: 12,
    marginTop: 8,
  },
  errorText: { color: colors.err, fontSize: 13 },
});
