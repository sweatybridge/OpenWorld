import { useQuery } from "@tanstack/react-query";
import { apiGet, type AgentRow } from "./lib/api";

// Polling cadence — matches the web app's REFRESH_MS.
export const REFRESH_MS = 5000;

export const STATUS_OPTIONS = [
  "pending",
  "running",
  "completed",
  "failed",
  "cancelled",
];

export const TYPE_OPTIONS = [
  "loop",
  "inbox",
  "cron",
  "send",
  "tool",
  "typing",
  "other",
];

// Shared agent list used by filter chips + the Messages agent picker.
export function useAgents() {
  return useQuery({
    queryKey: ["agents"],
    queryFn: () => apiGet<{ rows: AgentRow[] }>("/api/agents").then((r) => r.rows),
    staleTime: 60_000,
  });
}
