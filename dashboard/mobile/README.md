# attobot dashboard — mobile client (iOS & Android)

A React Native (Expo) port of the `dashboard/web` admin console. One TypeScript
codebase that ships to both platforms, talking to the **same read-only `/api/*`**
endpoints as the web app and gated by the **same optional bearer token**.

Full parity with the web console: Overview, Workflows (+ detail / node graph),
Agents, Messages, Memory, Users, Lifecycle, Config, Blobs.

## Stack

- **Expo SDK 52** (managed workflow — no native `ios/`/`android/` dirs committed)
- **React Navigation v6** — a Drawer (the 10 screens) wrapped by a Stack
  (WorkflowDetail push + Settings modal) plus an auth gate
- **TanStack Query v5** — same data library as the web app, including the 5 s
  polling + pull-to-refresh
- **expo-secure-store** — the bearer token lives in the device keychain
- **@react-native-async-storage/async-storage** — the server base URL

## Layout

```
dashboard/mobile/
  App.tsx                     providers (QueryClient + NavigationContainer) + RootNav
  app.json                    Expo config (cleartext HTTP allowed for LAN hosts)
  src/
    lib/    api.ts format.ts label.ts store.ts theme.ts
    nav/    RootNav.tsx AppDrawer.tsx DrawerContent.tsx types.ts gate.ts
    components/  Scroll States Badge Card KeyValue JsonView NodeTree Pager DataTable Pills
    screens/     Overview Workflows WorkflowDetail Agents Messages Memory Users
                 Lifecycle Config Blobs Setup Settings (+ Splash / BackendDown)
    hooks.ts        REFRESH_MS, STATUS/TYPE options, useAgents
```

## Reuse vs. the web app

Portable logic is copied verbatim from `dashboard/web/src`:

- `lib/format.ts` ← `web/src/format.ts`
- `lib/label.ts` ← `web/src/label.ts`
- `lib/api.ts` ← `web/src/api.ts` (all response types intact; only the token
  store and the configurable base URL differ)

Components and screens are RN rewrites that preserve query keys, endpoints,
filters and layout 1:1. The dark palette mirrors `web/src/styles.css`. These
copies could later be hoisted into a shared `dashboard/shared/` package if drift
becomes a concern — intentionally not done here to keep the change additive and
the verified web app untouched.

## Prerequisites

- Node 18+ (developed on Node 24)
- The Expo CLI comes bundled — `npx expo` works after `npm install`
- To run on device: **Expo Go** (App Store / Play Store). To run on simulators:
  Xcode (iOS) and/or Android Studio (Android).

## Run (dev)

```bash
cd dashboard/mobile
npm install
npx expo start
```

Then either scan the QR code with **Expo Go** (same Wi-Fi as this machine) or
press `i` / `a` to open a simulator. The bundler (Metro) hot-reloads on save.

**First launch:** the app shows a Setup screen. Enter:

- **Server URL** — a host reachable *from the phone*. `http://127.0.0.1:8088`
  will **not** work (that's the dev box's loopback). Use the host's LAN IP
  (e.g. `http://192.168.1.10:8088`) or a Tailscale address.
- **Bearer token** — only if the dashboard has `ATTOBOT_DASHBOARD_TOKEN` set;
  leave blank otherwise.

Change either later from the **Settings** screen (drawer → Settings, or
"Clear token" in the drawer footer).

## Reaching the dashboard from a phone

The compose service publishes the dashboard on **all interfaces** at port 8088
(`0.0.0.0:8088:8088` in `docker-compose.yml`), so a device reaches it at
`http://<host-lan-ip>:8088` over the LAN, or at the host's Tailscale address over
Tailscale.

Because this exposes the dashboard beyond loopback, set `ATTOBOT_DASHBOARD_TOKEN`
and enter it in the app's Setup screen so access is gated by the bearer token.
(The dashboard stays read-only regardless — the DB role has only SELECT/EXECUTE.)

The app allows cleartext HTTP to arbitrary hosts (`NSAppTransportSecurity` on iOS
and `usesCleartextTraffic` on Android via the `expo-build-properties` plugin) so
HTTP-on-LAN works. For anything beyond a trusted LAN, put the dashboard behind
HTTPS instead.

## Build for distribution

```bash
npm install -g eas-cli
eas login
eas build --platform ios
eas build --platform android
```

`eas build` runs in the cloud and produces installable artifacts. For a local
native build instead, `npx expo prebuild` then open the generated `ios/` /
`android/` projects in Xcode / Android Studio. (Set `extra.eas.projectId` in
`app.json` after creating the EAS project.)

## Typecheck

```bash
npm run typecheck
```
