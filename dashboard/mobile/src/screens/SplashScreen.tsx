import { ActivityIndicator, StyleSheet, View } from "react-native";
import { colors } from "../lib/theme";

export function SplashScreen() {
  return (
    <View style={s.wrap}>
      <ActivityIndicator size="large" color={colors.accent} />
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: colors.bg, alignItems: "center", justifyContent: "center" },
});
