import {
  RefreshControl,
  ScrollView,
  type StyleProp,
  type ViewStyle,
} from "react-native";
import type { ReactNode } from "react";
import { colors } from "../lib/theme";

interface ScrollProps {
  children: ReactNode;
  refreshing?: boolean;
  onRefresh?: () => void;
  contentContainerStyle?: StyleProp<ViewStyle>;
  style?: StyleProp<ViewStyle>;
}

// Screen-level vertical scroller with optional pull-to-refresh, tuned to the
// dashboard palette. Every list page composes its content inside this.
export function Scroll({
  children,
  refreshing,
  onRefresh,
  contentContainerStyle,
  style,
}: ScrollProps) {
  return (
    <ScrollView
      style={[{ flex: 1 }, style]}
      contentContainerStyle={[{ padding: 16, paddingBottom: 48 }, contentContainerStyle]}
      keyboardShouldPersistTaps="handled"
      refreshControl={
        onRefresh ? (
          <RefreshControl
            refreshing={!!refreshing}
            onRefresh={onRefresh}
            tintColor={colors.accent}
            colors={[colors.accent]}
            progressBackgroundColor={colors.panel}
          />
        ) : undefined
      }
    >
      {children}
    </ScrollView>
  );
}
