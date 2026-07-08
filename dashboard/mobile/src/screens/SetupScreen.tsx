import { useState } from "react";
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { saveCredentials } from "../lib/store";
import { colors } from "../lib/theme";

interface Props {
  reason: "first-run" | "token" | "edit";
  initialBase: string;
  initialToken: string;
  onCancel?: () => void;
  onSaved: () => void;
}

// First-run / token / edit-server gate. The web app hits a relative /api path;
// a phone can't reach the dev box's loopback, so the user points this at a
// reachable host (LAN IP / Tailscale) and optionally supplies the bearer token.
export function SetupScreen({
  reason,
  initialBase,
  initialToken,
  onCancel,
  onSaved,
}: Props) {
  const [base, setBase] = useState(initialBase);
  const [tok, setTok] = useState(initialToken);
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const title =
    reason === "first-run"
      ? "Connect to dashboard"
      : reason === "token"
        ? "Token required"
        : "Edit server";
  const sub =
    reason === "token"
      ? "The server requires a bearer token (got 401)."
      : "Point the app at a reachable dashboard host.";

  const save = async () => {
    const b = base.trim();
    if (!b) {
      setErr("Server URL is required.");
      return;
    }
    if (!/^https?:\/\//i.test(b)) {
      setErr("Server URL must start with http:// or https://");
      return;
    }
    setSaving(true);
    setErr(null);
    try {
      await saveCredentials(b, tok.trim());
      onSaved();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <SafeAreaView style={s.wrap} edges={["top", "bottom"]}>
      <KeyboardAvoidingView
        style={{ flex: 1 }}
        behavior={Platform.OS === "ios" ? "padding" : undefined}
      >
        <ScrollView
          contentContainerStyle={{ flexGrow: 1, justifyContent: "center", padding: 24 }}
          keyboardShouldPersistTaps="handled"
        >
          <View style={s.card}>
            <Text style={s.brand}>attobot · dashboard</Text>
            <Text style={s.title}>{title}</Text>
            <Text style={s.sub}>{sub}</Text>

            <Text style={s.label}>Server URL</Text>
            <TextInput
              style={s.input}
              value={base}
              onChangeText={setBase}
              placeholder="http://192.168.1.10:8088"
              placeholderTextColor={colors.muted}
              autoCapitalize="none"
              autoCorrect={false}
              keyboardType="url"
            />

            <Text style={s.label}>Bearer token (optional)</Text>
            <TextInput
              style={s.input}
              value={tok}
              onChangeText={setTok}
              placeholder="leave blank if the server has no token"
              placeholderTextColor={colors.muted}
              autoCapitalize="none"
              autoCorrect={false}
              secureTextEntry
            />

            {err ? <Text style={s.err}>{err}</Text> : null}

            <View style={s.actions}>
              {onCancel ? (
                <Pressable
                  style={[s.btn, s.ghost]}
                  onPress={onCancel}
                  disabled={saving}
                >
                  <Text style={s.ghostText}>Cancel</Text>
                </Pressable>
              ) : null}
              <Pressable
                style={[s.btn, saving && s.disabled]}
                onPress={save}
                disabled={saving}
              >
                <Text style={s.btnText}>{saving ? "Saving…" : "Save"}</Text>
              </Pressable>
            </View>

            <Text style={s.note}>
              The dashboard runs on the host's loopback by default
              (127.0.0.1:8088), so reach it via the host's LAN IP or a Tailscale
              address. The token is stored in the device keychain and sent as
              Authorization: Bearer.
            </Text>
          </View>
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: colors.bg },
  card: {
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
    padding: 20,
  },
  brand: { color: colors.muted, fontSize: 12, marginBottom: 6, textTransform: "uppercase", letterSpacing: 0.5 },
  title: { color: colors.text, fontSize: 18, fontWeight: "700", marginBottom: 4 },
  sub: { color: colors.muted, fontSize: 13, marginBottom: 16 },
  label: { color: colors.muted, fontSize: 12, marginTop: 12, marginBottom: 6 },
  input: {
    backgroundColor: colors.bg,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: colors.text,
    fontSize: 14,
  },
  err: { color: colors.err, fontSize: 12, marginTop: 10 },
  actions: { flexDirection: "row", justifyContent: "flex-end", gap: 10, marginTop: 18 },
  btn: { backgroundColor: colors.accent, borderRadius: 8, paddingVertical: 10, paddingHorizontal: 20 },
  btnText: { color: "#fff", fontWeight: "600", fontSize: 14 },
  ghost: { backgroundColor: "transparent", borderWidth: 1, borderColor: colors.border },
  ghostText: { color: colors.text, fontWeight: "600", fontSize: 14 },
  disabled: { opacity: 0.5 },
  note: { color: colors.muted, fontSize: 11, marginTop: 16, lineHeight: 17 },
});
