import { useCallback, useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import type { NativeStackNavigationOptions } from "@react-navigation/native-stack";
import { AppDrawer } from "./AppDrawer";
import { GateContext } from "./gate";
import { WorkflowDetailScreen } from "../screens/WorkflowDetailScreen";
import { TraceScreen } from "../screens/TraceScreen";
import { SettingsScreen } from "../screens/SettingsScreen";
import { SetupScreen } from "../screens/SetupScreen";
import { SplashScreen } from "../screens/SplashScreen";
import { BackendDownScreen } from "../screens/BackendDownScreen";
import { apiGet, AuthError, type Overview } from "../lib/api";
import { baseUrl, hasBaseUrl, loadCredentials, token } from "../lib/store";
import { colors } from "../lib/theme";
import type { RootStackParamList } from "./types";

const Stack = createNativeStackNavigator<RootStackParamList>();

const stackScreenOptions: NativeStackNavigationOptions = {
  headerTintColor: colors.text,
  headerTitleStyle: { color: colors.text },
  headerStyle: { backgroundColor: colors.panel },
  headerShadowVisible: false,
  contentStyle: { backgroundColor: colors.bg },
};

function AppRoot() {
  return (
    <Stack.Navigator screenOptions={stackScreenOptions}>
      <Stack.Screen
        name="Main"
        component={AppDrawer}
        options={{ headerShown: false }}
      />
      <Stack.Screen
        name="WorkflowDetail"
        component={WorkflowDetailScreen}
        options={{ title: "Workflow" }}
      />
      <Stack.Screen
        name="Trace"
        component={TraceScreen}
        options={{ title: "Turn trace" }}
      />
      <Stack.Screen
        name="Settings"
        component={SettingsScreen}
        options={{ presentation: "modal", title: "Settings" }}
      />
    </Stack.Navigator>
  );
}

// Decides what to render based on credential + auth state. Mirrors the web
// AuthShell: probe /api/overview -> 401 shows the token gate, a network error
// shows "backend unreachable", otherwise the app.
export function RootNav() {
  const [credsReady, setCredsReady] = useState(false);
  const [version, setVersion] = useState(0); // bump to re-probe the gate
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    loadCredentials().then(() => setCredsReady(true));
  }, []);

  const hasBase = hasBaseUrl();

  const gate = useQuery({
    queryKey: ["auth-check", version],
    queryFn: () => apiGet<Overview>("/api/overview"),
    enabled: credsReady && hasBase && !editing,
    staleTime: 0,
  });

  const reload = useCallback(() => setVersion((v) => v + 1), []);
  const edit = useCallback(() => setEditing(true), []);

  const needSetup =
    editing || !hasBase || gate.error instanceof AuthError;

  let body;
  if (!credsReady) {
    body = <SplashScreen />;
  } else if (needSetup) {
    const reason = !hasBase ? "first-run" : gate.error instanceof AuthError ? "token" : "edit";
    body = (
      <SetupScreen
        reason={reason}
        initialBase={baseUrl()}
        initialToken={reason === "token" ? "" : token()}
        onCancel={hasBase && reason !== "token" ? () => { setEditing(false); reload(); } : undefined}
        onSaved={() => { setEditing(false); reload(); }}
      />
    );
  } else if (gate.isLoading) {
    body = <SplashScreen />;
  } else if (gate.error) {
    body = (
      <BackendDownScreen
        message={(gate.error as Error).message}
        serverUrl={baseUrl()}
        onRetry={reload}
        onEdit={edit}
      />
    );
  } else {
    body = <AppRoot />;
  }

  return (
    <GateContext.Provider value={{ reload, edit }}>{body}</GateContext.Provider>
  );
}
