import type {
  CompositeNavigationProp,
  CompositeScreenProps,
} from "@react-navigation/native";
import type { DrawerNavigationProp, DrawerScreenProps } from "@react-navigation/drawer";
import type {
  NativeStackNavigationProp,
  NativeStackScreenProps,
} from "@react-navigation/native-stack";

// The 10 top-level screens (mirrors the web top-nav), each optionally carrying
// a cross-link filter (e.g. Overview -> Workflows?status=failed).
export type DrawerParamList = {
  Overview: undefined;
  Workflows: { status?: string; type?: string; agent?: string } | undefined;
  Agents: undefined;
  Messages: { agentId?: string } | undefined;
  Memory: { agentId?: string } | undefined;
  Users: undefined;
  Lifecycle: { agentId?: string } | undefined;
  Config: { agentId?: string } | undefined;
  Blobs: { agentId?: string } | undefined;
};

// Root stack wraps the Drawer and holds the pushed detail + modal screens.
export type RootStackParamList = {
  Main: undefined;
  WorkflowDetail: { id: string };
  Trace: { messageId: number };
  Settings: undefined;
};

// A drawer screen's props, composed so it can also navigate parent-stack
// screens (WorkflowDetail) — React Navigation bubbles the call at runtime.
export type AppDrawerScreenProps<K extends keyof DrawerParamList> =
  CompositeScreenProps<
    DrawerScreenProps<DrawerParamList, K>,
    NativeStackScreenProps<RootStackParamList>
  >;

// Composite navigation type usable anywhere via useNavigation().
export type AppNav = CompositeNavigationProp<
  DrawerNavigationProp<DrawerParamList>,
  NativeStackNavigationProp<RootStackParamList>
>;

export type WorkflowDetailScreenProps = NativeStackScreenProps<
  RootStackParamList,
  "WorkflowDetail"
>;

export type TraceScreenProps = NativeStackScreenProps<
  RootStackParamList,
  "Trace"
>;

export type SettingsScreenProps = NativeStackScreenProps<
  RootStackParamList,
  "Settings"
>;
