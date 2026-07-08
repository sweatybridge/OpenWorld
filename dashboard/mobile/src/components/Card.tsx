import { StyleSheet, Text, View } from "react-native";
import type { ReactNode } from "react";
import { colors } from "../lib/theme";

interface CardProps {
  title?: ReactNode;
  right?: ReactNode;
  children: ReactNode;
  noBodyPad?: boolean;
}

export function Card({ title, right, children, noBodyPad }: CardProps) {
  const hasHead = !!title || !!right;
  return (
    <View style={s.card}>
      {hasHead && (
        <View style={s.cardHead}>
          {title != null ? <Text style={s.cardTitle}>{title}</Text> : <View />}
          {right}
        </View>
      )}
      <View style={[s.cardBody, noBodyPad && { padding: 0 }]}>{children}</View>
    </View>
  );
}

const s = StyleSheet.create({
  card: {
    backgroundColor: colors.panel,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 10,
    marginBottom: 16,
    overflow: "hidden",
  },
  cardHead: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 8,
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderBottomWidth: 1,
    borderBottomColor: colors.border,
    backgroundColor: colors.panel2,
  },
  cardTitle: {
    fontSize: 14,
    fontWeight: "500",
    textTransform: "uppercase",
    letterSpacing: 0.4,
    color: colors.muted,
  },
  cardBody: { padding: 14 },
});
