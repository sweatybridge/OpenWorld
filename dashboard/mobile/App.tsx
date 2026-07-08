// Root of the attobot dashboard mobile client.
// Providers: TanStack Query (data fetching/caching, same lib as the web app) +
// React Navigation (Dark theme tuned to match the web dashboard palette).

import "react-native-gesture-handler"; // must be first — required by drawer/stack

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { NavigationContainer, DarkTheme } from "@react-navigation/native";
import type { Theme } from "@react-navigation/native";
import { StatusBar } from "expo-status-bar";
import { RootNav } from "./src/nav/RootNav";
import { AuthError } from "./src/lib/api";
import { colors } from "./src/lib/theme";

// Never silently retry a 401 (it won't get better) — surface it to the auth gate.
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error) =>
        !(error instanceof AuthError) && failureCount < 2,
      refetchOnWindowFocus: false,
    },
  },
});

const navTheme: Theme = {
  ...DarkTheme,
  colors: {
    ...DarkTheme.colors,
    background: colors.bg,
    card: colors.panel,
    text: colors.text,
    border: colors.border,
    primary: colors.accent,
    notification: colors.err,
  },
};

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <NavigationContainer theme={navTheme}>
        <StatusBar style="light" />
        <RootNav />
      </NavigationContainer>
    </QueryClientProvider>
  );
}
