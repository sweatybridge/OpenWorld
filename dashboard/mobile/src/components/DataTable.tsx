import { Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import type { ReactNode } from "react";
import { colors } from "../lib/theme";

export interface Column<T> {
  key: string;
  header: ReactNode;
  cell: (row: T) => ReactNode;
  width?: number;
}

interface DataTableProps<T> {
  columns: Column<T>[];
  rows: T[];
  onRow?: (row: T) => void;
  emptyText?: string;
}

// Wide tables (Agents, Workflows) scroll horizontally as a block, exactly like
// the web. Rows render as a flat list (admin views are small enough that
// virtualisation isn't worth the nested-scroll complexity).
export function DataTable<T>({
  columns,
  rows,
  onRow,
  emptyText = "No rows.",
}: DataTableProps<T>) {
  const header = (
    <View style={[s.row, s.headerRow]}>
      {columns.map((c) => (
        <View key={c.key} style={[s.cell, c.width ? { width: c.width } : null]}>
          <Text style={s.headerText} numberOfLines={1}>
            {c.header as ReactNode}
          </Text>
        </View>
      ))}
    </View>
  );

  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false}>
      <View>
        {header}
        {rows.length === 0 ? (
          <Text style={s.empty}>{emptyText}</Text>
        ) : (
          rows.map((row, i) => (
            <Pressable
              key={i}
              onPress={onRow ? () => onRow(row) : undefined}
              style={({ pressed }) => [s.row, pressed && s.rowPressed]}
            >
              {columns.map((c) => (
                <View
                  key={c.key}
                  style={[s.cell, c.width ? { width: c.width } : null]}
                >
                  {c.cell(row)}
                </View>
              ))}
            </Pressable>
          ))
        )}
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  row: { flexDirection: "row", borderBottomWidth: 1, borderBottomColor: colors.border },
  headerRow: { borderBottomWidth: 1, borderBottomColor: colors.border, backgroundColor: colors.panel2 },
  cell: { paddingHorizontal: 10, paddingVertical: 8, justifyContent: "center" },
  headerText: { color: colors.muted, fontSize: 12, fontWeight: "500" },
  empty: { color: colors.muted, textAlign: "center", paddingVertical: 24, fontSize: 13 },
  rowPressed: { backgroundColor: colors.panel2 },
});
