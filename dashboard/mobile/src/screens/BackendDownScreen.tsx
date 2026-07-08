import { Pressable, StyleSheet, Text, View } from "react-native";
import { colors } from "../lib/theme";

interface Props {
  message: string;
  serverUrl: string;
  onRetry: () => void;
  onEdit: () => void;
}

// Shown when the gate probe fails for a non-auth reason (host unreachable, etc).
export function BackendDownScreen({ message, serverUrl, onRetry, onEdit }: Props) {
  return (
    <View style={s.wrap}>
      <View style={s.card}>
        <Text style={s.title}>⚠️ Cannot reach backend</Text>
        <Text style={s.server}>{serverUrl || "(no server set)"}</Text>
        <Text style={s.msg}>{message}</Text>
        <View style={s.actions}>
          <Pressable style={s.btn} onPress={onRetry}>
            <Text style={s.btnText}>Retry</Text>
          </Pressable>
          <Pressable style={[s.btn, s.btnGhost]} onPress={onEdit}>
            <Text style={s.btnTextGhost}>Edit server</Text>
          </Pressable>
        </View>
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: colors.bg, alignItems: "center", justifyContent: "center", padding: 24 },
  card: {
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
    padding: 20,
    width: "100%",
    maxWidth: 420,
  },
  title: { color: colors.err, fontSize: 16, fontWeight: "700", marginBottom: 8 },
  server: { color: colors.text, fontFamily: "monospace", fontSize: 13, marginBottom: 8 },
  msg: { color: colors.muted, fontSize: 13, marginBottom: 18 },
  actions: { flexDirection: "row", gap: 10 },
  btn: {
    backgroundColor: colors.accent,
    borderRadius: 8,
    paddingVertical: 10,
    paddingHorizontal: 18,
  },
  btnText: { color: "#fff", fontWeight: "600", fontSize: 14 },
  btnGhost: { backgroundColor: "transparent", borderWidth: 1, borderColor: colors.border },
  btnTextGhost: { color: colors.text, fontWeight: "600", fontSize: 14 },
});
