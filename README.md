# Proflame WiFi — Control4 Driver

A Control4 `thermostatV2` driver for **SIT Proflame** WiFi fireplace modules (verified on `FW: 625.04.673`). It presents the fireplace as a thermostat plus custom **Extras** controls — operating mode, flame level, fan speed, downlight, and an auto-off timer — talking to the device over its WebSocket protocol on port 88.

The driver is **self-distributed via GitHub releases** (not Control4's online driver database) and self-updates from a button in Composer Pro.

> 📘 **Full technical reference:** [`Proflame_Control4_Driver_Specification.md`](Proflame_Control4_Driver_Specification.md) — device protocol, driver architecture, ThermostatV2 proxy integration, the Extras UI system, timer/state management, `driver.xml`, common pitfalls, and the complete change log. **This README is the operator + developer quick start; the spec is the single source of truth for details.**

## Features

- **ThermostatV2 proxy** — room temperature, setpoint, HVAC/fan modes, and hold (flame) modes.
- **Extras controls** — operating mode (Off / Manual / Smart Thermostat / Eco), flame level (1–6), fan speed (0–6), downlight (0–6), and an auto-off timer.
- **Resilient connection** — app-level `PROFLAMEPING` keepalive with a half-open-link watchdog and automatic reconnect (the device's RFC 6455 control-frame ping is deliberately disabled — see spec §2.6).
- **In-driver GitHub self-updater** — Check / Install / Force-Reinstall from the Actions tab, with a periodic report-only availability check.

## Requirements

- Control4 OS 3.x (including 3.3.0+).
- A SIT Proflame WiFi module reachable on the LAN (default WebSocket port **88**).

## Install (first time — manual)

The very first install is manual; after that the driver updates itself.

1. Download `proflame_wifi_connect.c4z` from the [latest release](https://github.com/psaab/proflame_c4/releases/latest).
2. Composer Pro → **Driver → Add or Update Driver…** → select the `.c4z`.
3. Add the driver to the project and set its **IP Address** property to the fireplace module's IP.

## Updates

Updates ship as GitHub releases and are driven from the device's **Actions** tab in Composer Pro:

| Action | Effect |
|--------|--------|
| **Check for Update** | Report-only — writes newer / up-to-date to the `Update Status` property. No download or install. |
| **Install Latest Release** | If the latest release tag is newer than the running version, downloads `proflame_wifi_connect.c4z` and installs it via Composer's local SOAP endpoint (`UpdateProjectC4i`). |
| **Force Reinstall Latest Release (Recovery)** | Reinstalls the latest release even when versions match (repair). May downgrade if the latest release is behind the running build. |

A report-only check also runs ~10 s after the driver loads and every `Update Check Interval` hours (default 24; `0` disables). **Installs are always manual.**

> **Bootstrap:** the release that first added the self-update handshake (`2026061602`) can't install itself via the older running driver — install it manually once, then the buttons work for every release after. On OS 3.3.0+ the updater performs a shared-secret `FileSetDir` handshake to write the `.c4z` to the c4z store root and verifies the write before triggering the install (it rejects loudly rather than silently reinstalling the old build). Details: spec §1.5.

> **Maintainer note:** cut a GitHub release (tag `v<DRIVER_VERSION>`, asset named exactly `proflame_wifi_connect.c4z`, `--target main`) after merging — otherwise update detection silently goes stale even though `main` has advanced.

## Configuration

Set on the device's **Properties** tab in Composer. Most-used:

| Property | Default | Notes |
|----------|---------|-------|
| `IP Address` | — | Fireplace module IP (**required**). |
| `Port` | `88` | WebSocket port. |
| `Keepalive Interval (seconds)` | `15` | App-level keepalive cadence (0–25; `0` disables). Holds the connection open. |
| `Default On Mode` / `Default Flame Level` / `Default Timer (minutes)` | `Smart` / `6` / `180` | Applied by **Turn On**. |
| `Debug Mode` / `Debug Level` | `On` / `Debug` | Logging. |
| `Last Keepalive Response` | _read-only_ | Timestamp of the last keepalive reply — connection liveness at a glance. |

Full property reference (incl. all read-only status fields): spec §1.4.

> A **new** static property added by an update won't appear in Composer until `driver.xml` is re-read: do a **Refresh Navigators** (or reload Director) after a self-update. The value is being written regardless; the field just isn't registered in the UI yet.

## Development

The source of truth is `src/driver.lua` + the vendored `vendor/*.lua` libraries. The repo-root `driver.lua` is a **generated** single-file bundle — **never edit it directly** (validation rejects a hand-edited bundle).

```sh
scripts/bundle.sh      # src/ + vendor/ -> driver.lua (the bundled artifact)
scripts/package.sh     # bundle, then zip the manifest -> proflame_wifi_connect.c4z
scripts/validate.sh    # xmllint, driver.lua/spec version match, deterministic-rebuild + package-staleness checks
test/run_tests.sh      # pure-Lua unit tests under lua5.1 (regenerates the bundle first)
```

Edit `src/driver.lua` / `vendor/*.lua`, then run `package.sh` to refresh the committed `.c4z`. CI (`.github/workflows/validate.yml`) runs validation, the unit tests, and PR-body lints on every push and pull request.

### Vendored libraries

| Path | Upstream | Purpose |
|---|---|---|
| `vendor/JSON.lua` | Jeffrey Friedl's JSON.lua | JSON encode/decode (20211016.28) |
| `vendor/logging.lua` | snap-one DriverWorks template | leveled logger |
| `vendor/persist.lua` | snap-one DriverWorks template | encrypted persistence wrapper |
| `vendor/deferred.lua` | snap-one DriverWorks template | promise/deferred helper |
| `vendor/version.lua` | snap-one DriverWorks template | semver comparator |
| `vendor/lib_helpers.lua` | snap-one DriverWorks template | misc lib helpers |
| `vendor/http.lua` | snap-one DriverWorks template | HTTP client w/ retry+watchdog |
| `vendor/github_updater.lua` | snap-one DriverWorks template | GitHub Releases auto-updater |
| `vendor/drivers-common-public/global/lib.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `Select`/`CopyTable`/persist helpers/etc. (transitive dep of the WebSocket module) |
| `vendor/drivers-common-public/global/timer.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `SetTimer`/`CancelTimer`/`ONE_SECOND` etc. (used by `websocket.lua`; the WS-level ping is disabled by this driver — see spec §2.6) |
| `vendor/drivers-common-public/global/handlers.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | framework handler dispatch tables `OCS`/`RFN`/`OPC`/etc. — top-level `OnConnectionStatusChanged` / `ReceivedFromNetwork` delegate to `OCS[netBinding]` / `RFN[netBinding]` for WebSocket-owned bindings |
| `vendor/drivers-common-public/module/metrics.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `Metrics` factory (counters consumed by `websocket.lua`) |
| `vendor/drivers-common-public/module/websocket.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `WebSocket:new()` factory — owns RFC 6455 handshake/framing/masking; replaced 9 hand-rolled helpers in C1 Phase 2 (driver `2026060302`). Its RFC 6455 control-frame ping is **disabled** by this driver (`ws.ping_interval = 0`) because the Proflame device closes on it; an app-level `PROFLAMEPING` keepalive is used instead. |

The `vendor/drivers-common-public/` tree mirrors upstream's directory layout exactly and the files are byte-identical to upstream master at the linked commit. They `require()` each other; a small `require` shim in `src/driver.lua` maps those calls to the bundled globals so the side-effect top-level code in each vendor file works under the bundled single-file deployment model. Both `bundle.sh` and `package.sh` read the file list from `scripts/manifest.txt`, and the packager normalizes ZIP timestamps so unchanged sources rebuild byte-identically.

## Composer Command Smoke Test

Run this checklist in Composer Pro before merging PRs that change command behavior. Paste the completed checklist, controller version, driver version, and any skipped items into the PR.

- [ ] Turn On applies Default On Mode, Default Flame Level, and Default Timer.
- [ ] Turn Off turns the fireplace off and clears the Extras timer display.
- [ ] Set Mode Manual, Smart, and Eco change only the driver-requested mode; flame and timer are not adjusted by the driver.
- [ ] Set Flame Level switches Smart/Eco/Off to Manual if needed and applies the requested flame level.
- [ ] Set Fan Level applies the requested fan level.
- [ ] Set Light Level applies the requested light level.
- [ ] Set Timer while off turns the fireplace on and starts countdown.
- [ ] Set Timer while off uses the requested timer value, not Default Timer.
- [ ] Set Timer while already on updates the timer without changing mode, flame, fan, or light.
- [ ] Cancel Timer while on triggers the timer-required safety policy and turns the fireplace off.
- [ ] Command Format testing records selected format and status echo for main_mode, flame_control, fan_control, lamp_control, temperature_set, timer_set, and timer_status.
- [ ] Disconnect the fireplace network path; command attempts are refused/logged and do not change confirmed driver state.
- [ ] Programming events fire in Composer when fireplace power/mode state changes.
- [ ] Extras flame, fan, and light sliders do not visibly snap back while waiting for device echoes.
- [ ] Extras controls round-trip: each changed mode/flame/fan/light/timer value is reflected in device state, driver properties/proxy state, and the next Extras render.
- [ ] If a case cannot be tested, note the reason explicitly in the PR.

## License & credits

Vendored Snap One DriverWorks libraries and `drivers-common-public` modules are © Snap One and used under their respective licenses; `JSON.lua` is © Jeffrey Friedl (CC-BY 3.0). See the linked upstreams above.
