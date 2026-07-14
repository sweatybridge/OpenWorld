import { createDrawerNavigator } from "@react-navigation/drawer";
import { DrawerContent } from "./DrawerContent";
import { colors } from "../lib/theme";
import type { DrawerParamList } from "./types";
import { OverviewScreen } from "../screens/OverviewScreen";
import { WorkflowsScreen } from "../screens/WorkflowsScreen";
import { AgentsScreen } from "../screens/AgentsScreen";
import { MessagesScreen } from "../screens/MessagesScreen";
import { MemoryScreen } from "../screens/MemoryScreen";
import { UsersScreen } from "../screens/UsersScreen";
import { ConfigScreen } from "../screens/ConfigScreen";
import { BlobsScreen } from "../screens/BlobsScreen";

const Drawer = createDrawerNavigator<DrawerParamList>();

const drawerScreenOptions = {
  headerTintColor: colors.text,
  headerTitleStyle: { color: colors.text },
  headerStyle: { backgroundColor: colors.panel },
  headerShadowVisible: false,
  drawerStyle: { backgroundColor: colors.panel, width: 280 },
  drawerActiveBackgroundColor: colors.panel2,
  drawerActiveTintColor: colors.text,
  drawerInactiveTintColor: colors.muted,
};

// The dashboard screens as drawer routes — the mobile analogue of the web
// top-nav bar. WorkflowDetail + Settings live in the parent stack (pushed/modal).
export function AppDrawer() {
  return (
    <Drawer.Navigator
      drawerContent={(props) => <DrawerContent {...props} />}
      screenOptions={drawerScreenOptions}
      initialRouteName="Overview"
    >
      <Drawer.Screen name="Overview" component={OverviewScreen} options={{ title: "Overview" }} />
      <Drawer.Screen name="Workflows" component={WorkflowsScreen} options={{ title: "Workflows" }} />
      <Drawer.Screen name="Agents" component={AgentsScreen} options={{ title: "Agents" }} />
      <Drawer.Screen name="Messages" component={MessagesScreen} options={{ title: "Messages" }} />
      <Drawer.Screen name="Memory" component={MemoryScreen} options={{ title: "Memory" }} />
      <Drawer.Screen name="Users" component={UsersScreen} options={{ title: "Users" }} />
      <Drawer.Screen name="Config" component={ConfigScreen} options={{ title: "Config" }} />
      <Drawer.Screen name="Blobs" component={BlobsScreen} options={{ title: "Blobs" }} />
    </Drawer.Navigator>
  );
}
