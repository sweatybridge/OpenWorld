# attobot dashboard — iOS client (SwiftUI)

A native iOS port of the `dashboard/web` admin console, sibling to the Expo/RN client in
`dashboard/mobile` and the native Android client in `dashboard/android`. It talks to the
**same read-only `/api/*`** endpoints as the web app and is gated by the **same optional
bearer token**.

Full parity with the web console: Overview, Workflows (+ detail / node graph), Agents,
Messages, Memory, Users, Lifecycle, Config, Blobs, plus the Setup / Settings / auth gate.

## Stack

- **SwiftUI** (iOS 17+) — `@Observable`, `NavigationStack(path:)` with a typed `Route` enum.
- **URLSession + Codable** — the read-only API client; no third-party HTTP libraries.
- **Security / Keychain** — the bearer token lives in the device keychain; the server base
  URL in `UserDefaults`.
- **XcodeGen** — the Xcode project is generated from `project.yml` (the `.xcodeproj` is
  not committed), so the project is fully text-reproducible.
- **Zero third-party / SPM dependencies** — pure Apple frameworks, so there's nothing to
  resolve and the build can't fail on a missing package.

## Layout

```
dashboard/ios/
  project.yml                    # XcodeGen spec → AttobotDashboard.xcodeproj
  README.md
  AttobotDashboard/
    App/        AttobotDashboardApp.swift   (@main entry)
    Core/       APIClient.swift   Models.swift   JSONValue.swift
                Credentials.swift  Format.swift   LabelParser.swift
    Theme/      Theme.swift                 (Color(hex:) palette + statusColor)
    State/      Gate.swift  Resource.swift  AgentsStore.swift
    Views/      RootView.swift  MenuView.swift  SetupView.swift  SettingsView.swift
                SplashView.swift  BackendDownView.swift
    Views/Components/  Card, StatusBadge, TypePill, DataTable, KeyValue, JsonView,
                       NodeTree, FilterPills, AgentPills, Pager, States, ScreenScroll
    Views/Screens/     Overview, Workflows, WorkflowDetail, Agents, Messages, Memory,
                       Users, Lifecycle, Config, Blobs
    Resources/  Info.plist   Assets.xcassets (AppIcon, AccentColor)
```

## Reuse vs. the web / RN app

Portable logic is a 1:1 port of `dashboard/web/src`:

- `Core/Format.swift` ← `web/src/format.ts`
- `Core/LabelParser.swift` ← `web/src/label.ts`
- `Core/Models.swift` ← `web/src/api.ts` response types (all fields intact)

Views are SwiftUI rewrites that preserve endpoints, query keys, filters and layout 1:1. The
dark palette mirrors `web/src/styles.css` (via `mobile/src/lib/theme.ts`). The
drawer-as-`List` menu (the 9 screens + Settings/Clear-token footer) is the idiomatic iOS
translation of the RN drawer.

## Prerequisites

- A Mac with **Xcode 16+** (includes the iOS 17 SDK).
- **XcodeGen**: `brew install xcodegen`.

## Open & run

```bash
cd dashboard/ios
xcodegen generate          # materializes AttobotDashboard.xcodeproj
open AttobotDashboard.xcodeproj
```

Then pick an iOS Simulator and run (⌘R). For a headless build check:

```bash
xcodebuild \
  -project AttobotDashboard.xcodeproj \
  -scheme AttobotDashboard \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Code signing is disabled (`CODE_SIGNING_ALLOWED: NO` in `project.yml`) so it builds for the
simulator without a developer account. Enable signing in Xcode → Signing & Capabilities to
install on a device.

**First launch:** the app shows a Setup screen. Enter:

- **Server URL** — a host reachable *from the phone*. `http://127.0.0.1:8088` will **not**
  work (that's the dev box's loopback). Use the host's LAN IP (e.g.
  `http://192.168.1.10:8088`) or a Tailscale address.
- **Bearer token** — only if the dashboard has `ATTOBOT_DASHBOARD_TOKEN` set; leave blank
  otherwise.

Change either later from the **Settings** screen (drawer → Settings, or "Clear token" in
the menu footer).

## Reaching the dashboard from a phone

The compose service publishes the dashboard on **all interfaces** at port 8088
(`0.0.0.0:8088:8088` in `docker-compose.yml`), so a device reaches it at
`http://<host-lan-ip>:8088` over the LAN, or at the host's Tailscale address over
Tailscale.

Because this exposes the dashboard beyond loopback, set `ATTOBOT_DASHBOARD_TOKEN` and
enter it in the app's Setup screen so access is gated by the bearer token. (The dashboard
stays read-only regardless — the DB role has only SELECT/EXECUTE.)

The app allows cleartext HTTP to arbitrary hosts (`NSAppTransportSecurity →
NSAllowsArbitraryLoads`) so HTTP-on-LAN works. For anything beyond a trusted LAN, put the
dashboard behind HTTPS instead.

## No Docker

Unlike the Expo client (whose `expo` compose service runs the Metro bundler), a native iOS
app has no server-side process to containerize — it builds via Xcode/XcodeGen on a Mac.
There is therefore no compose service for this client.

## CI

`.github/workflows/native-clients.yml` builds this app on every change to
`dashboard/ios/**`: it runs `xcodegen generate` then
`xcodebuild … -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
