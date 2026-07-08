import { Pressable, ScrollView, StyleSheet, Text } from "react-native";
import { colors } from "../lib/theme";
import { useAgents } from "../hooks";

interface Option {
  value: string;
  label: string;
}

// Horizontally-scrolling filter chips — the mobile analogue of the web's
// <select> dropdowns. Pure JS, no native picker dependency.
export function FilterPills({
  options,
  value,
  onSelect,
  allLabel = "all",
}: {
  options: string[];
  value: string;
  onSelect: (v: string) => void;
  allLabel?: string;
}) {
  const all: Option[] = [
    { value: "", label: allLabel },
    ...options.map((o) => ({ value: o, label: o })),
  ];
  return <Pills options={all} value={value} onSelect={onSelect} />;
}

export function AgentPills({
  value,
  onSelect,
}: {
  value: string;
  onSelect: (v: string) => void;
}) {
  const { data } = useAgents();
  const agents = data ?? [];
  const all: Option[] = [
    { value: "", label: "all agents" },
    ...agents.map((a) => ({ value: String(a.id), label: a.slug })),
  ];
  return <Pills options={all} value={value} onSelect={onSelect} />;
}

function Pills({
  options,
  value,
  onSelect,
}: {
  options: Option[];
  value: string;
  onSelect: (v: string) => void;
}) {
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={s.wrap}
    >
      {options.map((o) => {
        const active = o.value === value;
        return (
          <Pressable
            key={o.value}
            onPress={() => onSelect(o.value)}
            style={[s.pill, active && s.pillActive]}
          >
            <Text style={[s.pillText, active && s.pillTextActive]}>{o.label}</Text>
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const s = StyleSheet.create({
  wrap: { paddingHorizontal: 16, paddingVertical: 6, gap: 8, alignItems: "center" },
  pill: {
    paddingHorizontal: 12,
    paddingVertical: 5,
    borderRadius: 14,
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.panel,
  },
  pillActive: { backgroundColor: colors.panel2, borderColor: colors.accent },
  pillText: { color: colors.muted, fontSize: 13 },
  pillTextActive: { color: colors.text },
});
