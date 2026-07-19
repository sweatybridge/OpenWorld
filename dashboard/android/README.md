# attobot dashboard — Android client

A native Kotlin / Jetpack Compose port of the `dashboard/web` admin console. It
talks to the **same read-only `/api/*`** endpoints as the web app and is gated by
the **same optional bearer token**. This is a sibling of the Expo/RN client in
`dashboard/mobile/` — same screens, same data, same palette, native Android.

Full parity with the web console: Overview, Workflows (+ detail / node graph),
Agents, Messages, Memory, Users, Config.

## Stack

- **Kotlin 2.0.21** + **Jetpack Compose (Material3)** (Compose BOM `2024.10.01`)
- **Compose compiler plugin `org.jetbrains.kotlin.plugin.compose` 2.0.21**
  (matches the Kotlin version) + **kotlinx.serialization** for JSON
- **Retrofit 2.11.0** + **OkHttp 4.12.0** (kotlinx-serialization converter +
  an auth interceptor that injects `Authorization: Bearer`)
- **Navigation-Compose** (`ModalNavigationDrawer` + `NavHost`) — the drawer of
  9 screens plus a pushed `WorkflowDetail` and a `Settings` destination
- **Preferences DataStore** for the server base URL, **EncryptedSharedPreferences**
  (Android keystore) for the bearer token — the equivalents of the RN client's
  AsyncStorage + expo-secure-store
- Polling (5 s) + Material3 `PullToRefreshBox`, mirroring TanStack Query's
  `refetchInterval` + `RefreshControl` in the RN client

Pinned toolchain: AGP **8.7.2**, Gradle **8.10.2**, JDK **17**,
`compileSdk`/`targetSdk` **35**, `minSdk` **24`.

## Layout

```
dashboard/android/
  settings.gradle.kts
  build.gradle.kts                  # root: plugins { agp/kotlin/compose/serialization apply false }
  gradle.properties
  gradle/wrapper/gradle-wrapper.properties
  README.md
  app/
    build.gradle.kts                # plugins: agp, kotlin.android, compose, serialization
    proguard-rules.pro
    src/main/AndroidManifest.xml
    src/main/res/...                # values, xml configs, XML launcher icon
    src/main/java/com/attobot/dashboard/
      DashboardApp.kt               # Application: owns the ApiProvider + Credentials singletons
      MainActivity.kt               # setContent { AttobotTheme { Root() } }
      core/    AttobotApi.kt (Retrofit + ApiProvider), Models.kt, Credentials.kt,
               Format.kt, Label.kt
      state/   GateViewModel.kt, ScreenModels.kt (UiState + PollingViewModel + per-screen VMs + AgentsCache)
      ui/nav/  Routes.kt, RootNav.kt (gate + ModalNavigationDrawer + NavHost + drawer)
      ui/theme/ Color.kt, Theme.kt, Type.kt
      ui/components/  AttobotCard, StatusBadge/TypePill, DataTable, KeyValue, JsonView,
                      NodeTree, FilterPills/AgentPills, Pager, StateViews, PullRefreshScreen
      ui/screens/    Overview, Workflows, WorkflowDetail, Agents, Messages, Memory,
                     Users, Config, Settings, Setup, Splash, BackendDown
```

## Prerequisites

- **JDK 17**
- **Android SDK** with platform 35 and the matching Build-Tools
- **Android Studio** (recommended) — it provisions the SDK and the Gradle wrapper
  on first sync

## The Gradle wrapper jar is not committed

The wrapper jar is binary and can't be authored from text, so it is intentionally
**not** in the repo (see `.gitignore`). Pick one:

- run `gradle wrapper` once from `dashboard/android/` with any installed Gradle
  8.x to generate `gradlew`, `gradlew.bat` and `gradle/wrapper/gradle-wrapper.jar`, or
- open the project in **Android Studio**, which generates the wrapper on first
  Gradle sync.

CI doesn't need the jar: the GitHub Actions workflow provisions Gradle via
`gradle/actions/setup-gradle` and builds with a system `gradle`.

## Build

```bash
cd dashboard/android
gradle :app:assembleDebug
```

(or open in Android Studio and run the **app** configuration).

## First run (Setup screen)

On first launch the app shows a Setup screen. Enter:

- **Server URL** — a host reachable *from the phone*. `http://127.0.0.1:8088`
  will **not** work (that's the dev box's loopback). Use the host's LAN IP
  (e.g. `http://192.168.1.10:8088`) or a Tailscale address.
- **Bearer token** — only if the dashboard has `ATTOBOT_DASHBOARD_TOKEN` set;
  leave blank otherwise.

Change either later from **Settings** (drawer → Settings, or "Clear token" in the
drawer footer). The base URL is stored in DataStore; the token in the Android
keystore (EncryptedSharedPreferences).

## Reaching the dashboard from a phone

The compose service publishes the dashboard on **all interfaces** at port 8088
(`0.0.0.0:8088:8088` in `docker-compose.yml`), so a device reaches it at
`http://<host-lan-ip>:8088` over the LAN, or at the host's Tailscale address over
Tailscale.

Because this exposes the dashboard beyond loopback, set `ATTOBOT_DASHBOARD_TOKEN`
and enter it in the app's Setup screen so access is gated by the bearer token.
(The dashboard stays read-only regardless — the DB role has only SELECT/EXECUTE.)

The app allows cleartext HTTP to arbitrary hosts (`usesCleartextTraffic` + the
network security config) so HTTP-on-LAN works. For anything beyond a trusted LAN,
put the dashboard behind HTTPS instead.

## No Docker

Unlike `dashboard/server` / `dashboard/web` / `dashboard/mobile`, the Android
client is **not** a Docker service — it's a native Gradle project built into an
APK. There is no `docker-compose` entry for it; CI builds the debug APK directly.
