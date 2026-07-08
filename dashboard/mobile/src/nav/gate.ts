import { createContext, useContext } from "react";

// Lets deep descendants (DrawerContent, SettingsScreen) poke the auth gate in
// RootNav without prop-drilling: reload() re-probes /api/overview, edit() opens
// the server/token Setup screen.
export interface GateApi {
  reload: () => void;
  edit: () => void;
}

export const GateContext = createContext<GateApi>({
  reload: () => {},
  edit: () => {},
});

export const useGate = (): GateApi => useContext(GateContext);
