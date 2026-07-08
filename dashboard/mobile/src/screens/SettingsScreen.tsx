import { Pressable, StyleSheet, Text, View } from "react-native";
import { Card, KeyValue, Scroll } from "../components";
import { useGate } from "../nav/gate";
import { baseUrl, clearToken, token } from "../lib/store";
import { colors } from "../lib/theme";
import type { SettingsScreenProps } from "../nav/types";

type Props = SettingsScreenProps;

export function SettingsScreen(_: Props) {
  const gate = useGate();

  return (
    <Scroll>
      <Text style={s.h1}>Settings</Text>

      <Card title="Connection">
        <KeyValue
          items={[
            ["server", <Text key="b" style={s.mono}>{baseUrl() || "(not set)"}</Text>],
            [
              "token",
              <Text key="t" style={s.v}>
                {token() ? "set (stored in keychain)" : "not set"}
              </Text>,
            ],
          ]}
        />
      </Card>

      <Pressable style={({ pressed }) => [s.btn, pressed && s.pressed]} onPress={gate.edit}>
        <Text style={s.btnText}>Edit server / token</Text>
      </Pressable>

      <Pressable
        style={({ pressed }) => [s.btn, s.danger, pressed && s.pressed]}
        onPress={async () => {
          await clearToken();
          gate.reload();
        }}
      >
        <Text style={s.btnText}>Clear token</Text>
      </Pressable>

      <View style={s.noteWrap}>
        <Text style={s.note}>
          attobot dashboard · read-only mobile client for iOS &amp; Android.
          Same GET /api/* endpoints as the web console; secrets stay masked
          server-side.
        </Text>
      </View>
    </Scroll>
  );
}

const s = StyleSheet.create({
  h1: { fontSize: 20, fontWeight: "700", color: colors.text, marginBottom: 12 },
  mono: { color: colors.text, fontFamily: "monospace", fontSize: 12, flexShrink: 1 },
  v: { color: colors.text, fontSize: 13 },
  btn: {
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel,
    borderRadius: 8,
    paddingVertical: 12,
    alignItems: "center",
    marginBottom: 10,
  },
  btnText: { color: colors.text, fontWeight: "600", fontSize: 14 },
  danger: { borderColor: colors.err },
  pressed: { opacity: 0.6 },
  noteWrap: { marginTop: 8 },
  note: { color: colors.muted, fontSize: 11, lineHeight: 16 },
});
