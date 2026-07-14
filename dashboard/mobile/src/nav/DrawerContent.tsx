import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import type { DrawerContentComponentProps } from "@react-navigation/drawer";
import { useNavigation } from "@react-navigation/native";
import { useGate } from "./gate";
import { clearToken } from "../lib/store";
import { colors } from "../lib/theme";
import type { AppNav, DrawerParamList } from "./types";

const ITEMS: Array<{ name: keyof DrawerParamList; icon: string; label: string }> = [
  { name: "Overview", icon: "🏠", label: "Overview" },
  { name: "Workflows", icon: "🧭", label: "Workflows" },
  { name: "Agents", icon: "🤖", label: "Agents" },
  { name: "Messages", icon: "💬", label: "Messages" },
  { name: "Memory", icon: "🧠", label: "Memory" },
  { name: "Users", icon: "👥", label: "Users" },
  { name: "Config", icon: "⚙️", label: "Config" },
  { name: "Blobs", icon: "📦", label: "Blobs" },
];

export function DrawerContent({ state }: DrawerContentComponentProps) {
  const navigation = useNavigation<AppNav>();
  const gate = useGate();
  const active = state.routes[state.index]?.name;

  return (
    <SafeAreaView style={s.wrap} edges={["top", "bottom"]}>
      <View style={s.brand}>
        <Text style={s.brandMain}>attobot</Text>
        <Text style={s.brandSub}> · dashboard</Text>
      </View>

      <ScrollView style={s.list}>
        {ITEMS.map((it) => {
          const isActive = active === it.name;
          return (
            <Pressable
              key={it.name}
              onPress={() => navigation.navigate(it.name)}
              style={({ pressed }) => [
                s.item,
                isActive && s.itemActive,
                pressed && s.itemPressed,
              ]}
            >
              <Text style={s.icon}>{it.icon}</Text>
              <Text style={[s.label, isActive && s.labelActive]}>{it.label}</Text>
            </Pressable>
          );
        })}
      </ScrollView>

      <View style={s.footer}>
        <Pressable
          style={({ pressed }) => [s.item, pressed && s.itemPressed]}
          onPress={() => navigation.navigate("Settings")}
        >
          <Text style={s.icon}>🛠</Text>
          <Text style={s.label}>Settings</Text>
        </Pressable>
        <Pressable
          style={({ pressed }) => [s.item, pressed && s.itemPressed]}
          onPress={async () => {
            await clearToken();
            gate.reload();
          }}
        >
          <Text style={s.icon}>🔒</Text>
          <Text style={s.label}>Clear token</Text>
        </Pressable>
      </View>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: colors.panel },
  brand: {
    flexDirection: "row",
    alignItems: "baseline",
    paddingHorizontal: 20,
    paddingTop: 16,
    paddingBottom: 20,
    borderBottomWidth: 1,
    borderBottomColor: colors.border,
  },
  brandMain: { color: colors.text, fontWeight: "700", fontSize: 18 },
  brandSub: { color: colors.muted, fontSize: 14 },
  list: { flex: 1, paddingTop: 8 },
  item: {
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
    paddingVertical: 12,
    paddingHorizontal: 20,
    borderRadius: 8,
    marginHorizontal: 8,
  },
  itemActive: { backgroundColor: colors.panel2 },
  itemPressed: { opacity: 0.6 },
  icon: { fontSize: 16, width: 22 },
  label: { color: colors.muted, fontSize: 15 },
  labelActive: { color: colors.text, fontWeight: "600" },
  footer: {
    borderTopWidth: 1,
    borderTopColor: colors.border,
    paddingTop: 8,
    paddingBottom: 8,
  },
});
