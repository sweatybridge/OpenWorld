import { useState } from "react";
import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import { colors } from "../lib/theme";

// Port of the web JsonView: a single toggle that pretty-prints the value. Many
// pg results come back as a JSON *string*, so parse-and-restringify when we can.
export function JsonView({
  value,
  defaultOpen = false,
}: {
  value: unknown;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  let text: string;
  if (typeof value === "string") {
    try {
      text = JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      text = value;
    }
  } else if (value == null) {
    text = "null";
  } else {
    text = JSON.stringify(value, null, 2);
  }
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
          <Text style={s.pre}>{text}</Text>
        </ScrollView>
      )}
    </View>
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
