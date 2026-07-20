import { useState } from "react";
import {
  BrowserRouter, Routes, Route, NavLink, Link, Navigate,
} from "react-router-dom";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { apiGet, AuthError, getToken, setToken } from "./api";
import {
  ConfigPage, IndexesPage, MemoryPage, MessagesPage,
  OverviewPage, UsersPage, WorkflowsPage, WorkflowDetailPage, AgentsPage, TracePage,
} from "./pages";
import { ErrorState, Spinner } from "./components";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Never silently retry a 401 (it won't get better) — surface it to the gate.
      retry: (_n, err) => !(err instanceof AuthError) && _n < 2,
      refetchOnWindowFocus: false,
    },
  },
});

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <AuthShell>
          <Shell />
        </AuthShell>
      </BrowserRouter>
    </QueryClientProvider>
  );
}

// Probes the API. A 401 means the server wants a bearer token → show the gate.
// A network error means the backend is down. Otherwise render the app.
function AuthShell({ children }: { children: React.ReactNode }) {
  const check = useQuery({
    queryKey: ["auth-check"],
    queryFn: () => apiGet("/api/overview"),
    staleTime: 0,
  });
  if (check.isLoading) return <div className="centered"><Spinner /></div>;
  if (check.error instanceof AuthError) return <TokenGate onSaved={() => check.refetch()} />;
  if (check.error) {
    return <div className="centered"><ErrorState message={`Cannot reach backend: ${(check.error as Error).message}`} /></div>;
  }
  return <>{children}</>;
}

function TokenGate({ onSaved }: { onSaved: () => void }) {
  const [val, setVal] = useState("");
  return (
    <div className="gate">
      <form onSubmit={(e) => { e.preventDefault(); setToken(val.trim()); onSaved(); }}>
        <h2>Dashboard token required</h2>
        <input
          type="password" value={val} autoFocus
          onChange={(e) => setVal(e.target.value)}
          placeholder="bearer token"
        />
        <button className="btn" type="submit">Unlock</button>
        <p>
          The server has <code>ATTOBOT_DASHBOARD_TOKEN</code> set. The token is stored
          in this browser's localStorage and sent as <code>Authorization: Bearer</code>.
        </p>
      </form>
    </div>
  );
}

const NAV: Array<[string, string]> = [
  ["/", "Overview"],
  ["/workflows", "Workflows"],
  ["/agents", "Agents"],
  ["/messages", "Messages"],
  ["/memory", "Memory"],
  ["/users", "Users"],
  ["/config", "Config"],
  ["/indexes", "Indexes"],
];

function Shell() {
  const hasToken = !!getToken();
  return (
    <div className="layout">
      <nav className="topnav">
        <Link to="/" className="brand">attobot<span> · dashboard</span></Link>
        {NAV.map(([to, label]) => (
          <NavLink key={to} to={to} end={to === "/"}>{label}</NavLink>
        ))}
        {hasToken && (
          <button
            className="link lock-btn"
            title="Clear stored token"
            onClick={() => { setToken(""); window.location.reload(); }}
          >
            🔒
          </button>
        )}
      </nav>
      <main className="content">
        <Routes>
          <Route path="/" element={<OverviewPage />} />
          <Route path="/workflows" element={<WorkflowsPage />} />
          <Route path="/workflows/:id" element={<WorkflowDetailPage />} />
          <Route path="/agents" element={<AgentsPage />} />
          <Route path="/messages" element={<MessagesPage />} />
          <Route path="/trace/:messageId" element={<TracePage />} />
          <Route path="/memory" element={<MemoryPage />} />
          <Route path="/users" element={<UsersPage />} />
          <Route path="/config" element={<ConfigPage />} />
          <Route path="/indexes" element={<IndexesPage />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}
