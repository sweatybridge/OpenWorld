import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { colors } from "../lib/theme";

// Pretty-prints a value as JSON. pg results often arrive as a JSON *string*, so
// parse-and-restringify when we can; fall back to the raw text otherwise.
function formatJson(value: unknown): string {
  if (typeof value === "string") {
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return value;
    }
  }
  if (value == null) return "null";
  return JSON.stringify(value, null, 2);
}

// Port of the web JsonView: a single toggle that pretty-prints the value.
export function JsonView({
  value,
  defaultOpen = false,
}: {
  value: unknown;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <View>
      <Pressable onPress={() => setOpen((o) => !o)} hitSlop={8}>
        <Text style={s.toggle}>{open ? "▾ hide" : "▸ show"}</Text>
      </Pressable>
      {open && (
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          style={s.preWrap}
        >
          <Text style={s.pre}>{formatJson(value)}</Text>
        </ScrollView>
      )}
    </View>
  );
}

// JSON shown inline with no toggle — for spots that already provide their own
// disclosure (e.g. the ▸ result toggle around a node result), so the value shows
// the moment that disclosure opens instead of behind a redundant nested show.
export function JsonText({ value }: { value: unknown }) {
  return (
    <ScrollView
      horizontal
      showsHorizontalScrollIndicator={false}
      style={s.preWrap}
    >
      <Text style={s.pre}>{formatJson(value)}</Text>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  toggle: { color: colors.accent, fontSize: 13, paddingVertical: 2 },
  preWrap: {
    backgroundColor: colors.panel2,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 6,
    padding: 10,
    marginVertical: 6,
  },
  pre: {
    fontFamily: "monospace",
    color: colors.text,
    fontSize: 12,
  },
});
