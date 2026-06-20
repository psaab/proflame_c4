# Proflame WiFi Fireplace Control4 Driver Specification

## Document Version
- **Version**: 2.0
- **Date**: May 2026
- **Driver Version**: 2026061604 (2026-06-16)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Proflame Device Protocol](#2-proflame-device-protocol)
3. [Control4 Driver Architecture](#3-control4-driver-architecture)
4. [ThermostatV2 Proxy Integration](#4-thermostatv2-proxy-integration)
5. [Extras UI System](#5-extras-ui-system)
6. [Timer System](#6-timer-system)
7. [State Management](#7-state-management)
8. [Network Connection Management](#8-network-connection-management)
9. [XML Configuration](#9-xml-configuration)
10. [Common Pitfalls and Solutions](#10-common-pitfalls-and-solutions)
11. [Complete Command Reference](#11-complete-command-reference)
12. [Testing Checklist](#12-testing-checklist)

---

## 1. Overview

### 1.1 Purpose
This driver enables Control4 home automation systems to control Proflame WiFi-enabled fireplaces. It presents the fireplace as a thermostat device with additional custom controls via the Extras UI system.

### 1.2 Features
- On/Off control
- Flame level adjustment (1-6)
- Fan speed control (0-6)
- Downlight/lamp control (0-6)
- Auto-off timer (0-360 minutes) with countdown display
- Operating mode selection (Manual, Smart Thermostat, Eco)
- Temperature monitoring and setpoint control
- Real-time status synchronization
- Automatic timer and flame settings when turning on
- Configurable defaults for mode, flame level, and timer

### 1.3 Hardware Requirements
- Proflame WiFi module (Proflame 2 WiFi)
- Control4 controller
- Network connectivity between controller and fireplace

### 1.4 Configurable Properties
| Property | Type | Default | Description |
|----------|------|---------|-------------|
| IP Address | STRING | - | Fireplace WiFi module IP |
| Port | INTEGER | 88 | WebSocket port |
| Reconnect Delay | INTEGER | 10 | Delay before reconnect (seconds) |
| Keepalive Interval (seconds) | INTEGER | 15 | App-level `PROFLAMEPING` cadence (0-25; 0 disables). Holds the connection open — see §2.6 / §8.5 |
| Connect Timeout | INTEGER | 30 | Connect-attempt watchdog (seconds, 5-120). Forces teardown + reschedule if neither Established nor Offline arrives in time (issue #71). Not disablable — a safety mechanism |
| Status Refresh Interval | INTEGER | 5 | Periodic full-status re-request (minutes); 0 disables |
| Default On Mode | LIST | Smart (Thermostat) | Mode when turning on: Manual, Smart (Thermostat), Eco |
| Default Flame Level | INTEGER | 6 | Initial flame level (1-6) |
| Default Timer | INTEGER | 180 | Auto-off timer armed by Turn On and by the timer-required safety policy (incl. when the device is turned on by the physical remote); `0` disables timer arming, so an on-state with no running timer is forced off instead |
| Command Format (non-Turn-Off) | LIST | Legacy Only | Outbound format for non-Turn-Off device commands |
| Update Check Interval | INTEGER | 24 | Report-only GitHub release check (hours, 0-168); 0 disables. Surfaces availability in Update Status; install stays manual |
| Debug Mode | LIST | On | Enable/disable debug logging |
| Debug Level | LIST | Debug | Error, Warn, Info, Debug |

**Read-only status properties** (populated from device status, not user-editable): `Driver Version`, `Firmware Versions`, `Connection Status`, `Last Keepalive Response` (timestamp of the last `PROFLAMEPONG` keepalive reply, default `Never` — round-trip liveness at a glance), `WiFi Signal Strength`, `Update Status`, and live mirrors of device state (`Operating Mode`, `Flame Level`, `Fan Level`, `Light Level`, `Temperature Setpoint`, `Room Temperature`, `Thermostat Enabled`, `Pilot Status`, `Aux Output`, `Front Flame (Split)`, `Timer Active`, `Timer Remaining`, `Burner Status`, `Temperature Unit`).

> Adding/renaming a static property is a static-surface change: after an in-driver self-update it won't appear in Composer until `driver.xml` is re-read (Refresh Navigators / Director reload).

### 1.5 Driver Updates

This driver is **self-distributed via GitHub releases** (`psaab/proflame_c4`), so Control4's native "Check For Driver Updates" / Update Manager menu will **not** detect updates — that menu only queries Control4's online driver database, which does not contain this driver (`<auto_update>` is therefore set `false`). Updates flow through the driver's own GitHub updater.

These are exposed as **clickable buttons in the device's Actions tab** in Composer Pro (select the Proflame device → **Actions**). They are defined by an `<actions>` block in `driver.xml`; each action's `<command>` is routed to `ExecuteCommand`. (Defining only `<commands>` would surface them in Programming as device-specific commands, **not** as buttons — the `<actions>` block is what renders the buttons.)

| Action button | Effect |
|---------------|--------|
| **Check for Update** | Report-only. Queries the latest GitHub release and reports newer/up-to-date in the `Update Status` property. Does not download or install. |
| **Install Latest Release** | If the latest release tag is newer than the running version, downloads `proflame_wifi_connect.c4z` and installs it via Composer's local SOAP endpoint (`127.0.0.1:5020`, `UpdateProjectC4i`). |
| **Force Reinstall Latest Release (Recovery)** | Re-downloads/re-installs the latest release even when versions match (recovery/repair). Can reinstall an older build if the latest release is behind the running one — the button is labeled "(Recovery)" to flag the downgrade risk. (Underlying command string remains `Force Reinstall Latest Release`.) |

Detection also runs automatically: a report-only check fires ~10 s after driver load and then every `Update Check Interval` hours (default 24; set 0 to disable). **Installs are always manual.** A release must exist with a tag newer than the running `DRIVER_VERSION` and an asset named exactly `proflame_wifi_connect.c4z`, or nothing is detected.

**OS 3.3.0+ install mechanism.** `UpdateProjectC4i` installs the `.c4z` from the c4z store **root** (`C4Z_ROOT`) by name. On OS 3.3.0+, `FileSetDir("C4Z_ROOT")` is restricted for unsigned community drivers, so `OnDriverLateInit` first performs the community-standard shared-secret handshake `C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")` to re-unlock root access; the updater then writes there and verifies the on-disk size before triggering the SOAP install (rejecting loudly on a denied/short write rather than silently reinstalling the old build). **Bootstrap:** the release that first *adds* the handshake must be installed manually once (Composer → Driver → Add or Update Driver…); subsequent updates self-install from the buttons. See the changelog (2026061602) for the full root-cause.

---

## 2. Proflame Device Protocol

### 2.1 Connection Details
- **Protocol**: WebSocket over TCP
- **Default Port**: 88
- **WebSocket Path**: `/`
- **No authentication required**

### 2.2 WebSocket Handshake

The device expects a standard HTTP WebSocket upgrade request:

```
GET / HTTP/1.1
Host: <ip>:88
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64-encoded-16-byte-random-key>
Sec-WebSocket-Version: 13
Origin: http://<ip>
```

The device responds with:
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: <calculated-accept-key>
```

**Important**: The Sec-WebSocket-Accept is calculated as:
```
base64(sha1(Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

The driver strictly validates the status line, Upgrade/Connection headers, and Sec-WebSocket-Accept per RFC 6455. The prior `Strict WebSocket Handshake = Off` lenient-101 fallback was removed in 2026060108 after direct device probe (firmware `FW: 625.04.673`) confirmed the Proflame returns a fully compliant 101 — see `tools/probes/FINDINGS.md` §1.

**Compatibility tradeoff (2026060108):** default-Off installs had been silently using the lenient-101 fallback. After the removal, those installs become strict-only — the same behavior an explicitly-set `Strict WebSocket Handshake = On` would have produced. On `FW: 625.04.673` no behavior changes (the probe shows the firmware is RFC-compliant), but a deployment against a different firmware revision that emitted a non-compliant 101 would now refuse to connect. Re-run `tools/probes/handshake_and_ping.py` to verify a new firmware before deploying.

### 2.3 WebSocket Frame Format

Standard WebSocket framing is used:
- **Opcode 0x01**: Text frame (used for JSON messages)
- **Opcode 0x08**: Close

Client-to-server frames MUST be masked. Server-to-client frames are NOT masked.

### 2.4 Message Format

**CRITICAL**: All JSON messages must have NO SPACES. The device parser is sensitive to formatting.

#### Command Format (Client -> Device)
```json
{"command":"set_control","name":"<parameter>","value":"<value>"}
```

The default `Command Format (non-Turn-Off)` property sends the legacy indexed format verified on real hardware:

```json
{"control0":"<parameter>","value0":"<value>"}
```

Other `Command Format (non-Turn-Off)` options support runtime verification: `Documented Only`, `Dual (Documented First)`, and `Dual (Legacy First)`. Runtime verification should test and compare both dual orderings because order may affect which message the firmware accepts. The legacy-only default was verified on firmware `FW: 625.04.673`; other firmware variants may need a different setting. All control writes are routed through `BuildDeviceControlCommandPlan`; Turn Off uses that same wrapper with the verified legacy-only plan.

The driver sends one control per message. Multi-control writes should be sent as separate no-space JSON messages.

#### Status Format (Device -> Client)
```json
{"status0":"<parameter>","value0":"<value>","status1":"<param2>","value1":"<val2>",...}
```

The device may also send direct key-value format:
```json
{"temperature_read":"700","timer_read":"3600000","rssi":"45",...}
```

### 2.5 Initial Connection Sequence

After WebSocket handshake completes:
1. Send connection announcement: `PROFLAMECONNECTION`
2. Device responds: `PROFLAMECONNECTIONOPEN`
3. Device then sends full status dump as JSON messages

### 2.6 Keep-Alive

Send a `PROFLAMEPING` **text** message every `Keepalive Interval (seconds)` (default 15, 0-25, 0 disables). The device replies `PROFLAMEPONG`, and the `Last Keepalive Response` property is timestamped.

**Note**: This is NOT a standard RFC 6455 WebSocket ping/pong control frame — it's an app-level text message. The vendored WebSocket module's RFC 6455 control-frame ping is **disabled** for this device (`ws.ping_interval = 0`): the Proflame dongle closes the connection ~30 s after connect when a control-frame ping is the only client traffic (it enforces an inbound-idle session timeout and doesn't count the control ping as activity). The app-level `PROFLAMEPING` is what keeps the session alive. A half-open-link watchdog forces a reconnect after 3 consecutive intervals with no inbound traffic. See §8.5 and changelog 2026061601.

### 2.7 Operating Modes

| Mode Value | Name | Description |
|------------|------|-------------|
| 0 | Off | Fireplace off |
| 1 | Standby | Pilot may be lit, burner off |
| 2 | App-reported standby/off | Observed runtime status after Proflame app Turn Off; driver treats as off/standby but does not send it as the Turn Off command |
| 5 | Manual | Direct flame control |
| 6 | Smart | Temperature-controlled operation |
| 7 | Eco | Energy-saving thermostat mode |

**Note**: Modes 3 and 4 are reserved/unused in current firmware.

### 2.8 Temperature Encoding

Temperatures are encoded as integers: **Fahrenheit x 10**

Examples:
- 70°F = 700
- 68.5°F = 685
- 32°F = 320

To decode: `temperature_F = value / 10`
To encode: `value = temperature_F * 10`

### 2.9 Timer Encoding

**CRITICAL DISCOVERY**: Timer values are in MILLISECONDS, not seconds or minutes.

- 1 minute = 60,000 ms
- 60 minutes = 3,600,000 ms
- 120 minutes = 7,200,000 ms
- 6 hours (360 min) = 21,600,000 ms

### 2.10 Complete Parameter Reference

#### Controllable Parameters (`name`)

| Parameter | Values | Description |
|-----------|--------|-------------|
| `main_mode` | 0,1,5,6,7 | Operating mode |
| `flame_control` | 1-6 | Flame height level |
| `fan_control` | 0-6 | Fan speed (0=off) |
| `lamp_control` | 0-6 | Downlight brightness |
| `temperature_set` | 600-900 | Setpoint (Fx10) |
| `thermo_control` | 0,1 | Thermostat enable |
| `pilot_control` | 0,1 | Pilot flame control |
| `aux_control` | 0,1 | Auxiliary output |
| `split_control` | 0,1 | Split/front flame |
| `timer_set` | 0-21600000 | Timer value in ms |
| `timer_status` | 0,1 | Timer running state |

#### Status Parameters (status0)

All controllable parameters plus:

| Parameter | Description |
|-----------|-------------|
| `room_temperature` | Current temp (Fx10). Readings that decode outside −40…140°F are treated as a firmware sentinel and dropped (some firmware reports raw `6845` = 684.5°F when no real sensor value is available); the last good reading is retained |
| `temperature_read` | Alias for room_temperature (same plausibility guard) |
| `timer_count` | Remaining time in ms |
| `timer_read` | Alias for timer_count |
| `burner_status` | Burner state bitmap |
| `wifi_signal_str` | WiFi RSSI (positive value, actual is negative) |
| `rssi` | Alias for wifi_signal_str |
| `fw_revision` | Firmware version string |
| `dongle_name` | Device name |
| `temperature_unit` | Device's displayed unit preference: `"1"` = Fahrenheit, `"0"` = Celsius. The driver mirrors this into the read-only "Temperature Unit" Composer property and uses it to flip the display suffix on "Temperature Setpoint" / "Room Temperature". Wire encoding (Fx10 integer) for the temperature values themselves is unchanged. |

### 2.11 Timer Operation Sequence

To start a timer:
1. Send `timer_set` with value in milliseconds
2. Wait ~200ms
3. Send `timer_status` = 1

To stop a timer:
1. Send `timer_status` = 0

**Device Behavior**:
- Device sends `timer_count` updates approximately every second when timer is running
- When timer expires, device sets `main_mode` to 0 (off)
- `timer_count` continues to report the set value even when timer is stopped
- When timer_status becomes 0, the device may send default timer values which should be ignored

---

## 3. Control4 Driver Architecture

### 3.1 File Structure

A Control4 driver (.c4z) is a ZIP file containing:
```
driver.xml      - Driver configuration and metadata
driver.lua      - Lua implementation code (generated by scripts/bundle.sh)
www/            - Optional web content
  documentation.html
  icons/        - Device icons
    device_sm.png
    device_lg.png
```

In this repo, `driver.lua` is the deployment artifact only — never edit it
directly. The source of truth lives in:

```
src/driver.lua                  - Driver source; vendored libs replaced by `-- BUNDLE_INSERT` sentinels
vendor/JSON.lua                 - Jeffrey Friedl's JSON.lua (CC-BY 3.0)
vendor/logging.lua              - Finite Labs structured logging
vendor/persist.lua              - Slim wrapper over C4:PersistGetValue/SetValue
vendor/deferred.lua             - Promise/Deferred library (used by the updater)
vendor/version.lua              - Semver comparator (used by the updater)
vendor/lib_helpers.lua          - Hand-extracted helpers (IsEmpty/Select/FileWrite/XMLTag/...)
vendor/http.lua                 - C4:urlGet wrapper returning Deferred promises
vendor/github_updater.lua       - GitHub Releases self-installer (Snap One template)
scripts/bundle.sh               - Splices vendor libs into src/driver.lua to produce driver.lua
test/                           - Unit tests run by run_tests.sh + CI
```

`bundle.sh` order is **load-bearing**: JSON before logging (logging encodes
tables via `JSON:encode`) and before persist (persist serializes via
JSON); deferred before lib_helpers (`reject`/`resolve` build Deferreds);
http before github_updater (the updater calls `http:get`). The sentinel
order in `src/driver.lua` must match the order in `bundle.sh`.

`scripts/validate.sh` rejects a working tree where `driver.lua` is out of
sync with what `bundle.sh` would produce, so direct edits to `driver.lua`
cannot land.

### 3.2 Driver Lifecycle Callbacks

```lua
function OnDriverInit()
    -- Called when driver first loads
    -- Initialize variables, but DON'T connect yet
end

function OnDriverLateInit()
    -- Called after all proxies are bound
    -- Safe to connect and set up communications
end

function OnDriverUpdated()
    -- Called when driver is updated (new version installed)
    -- Clean up old state and reinitialize
end

function OnDriverDestroyed()
    -- Called when driver is removed
    -- Clean up connections, timers, etc.
end
```

### 3.3 Driver Load Cleanup

**Important**: When the Lua file loads/reloads, cleanup code runs immediately (before callbacks). The current cleanup (post-C1-Phase-2) cancels the keepalive/reconnect timers, tears down the vendored WebSocket (`gWebSocket`) and its dynamically-allocated binding, and resets state. The example below is illustrative of the *pattern*:

```lua
-- Cancel the app-level keepalive timer from a previous instance
-- (and the deferred-reconnect one-shot); reload-safe.
if gKeepaliveTimerId then pcall(function() gKeepaliveTimerId:Cancel() end); gKeepaliveTimerId = nil end
if gKeepaliveReconnectTimerId then pcall(function() gKeepaliveReconnectTimerId:Cancel() end); gKeepaliveReconnectTimerId = nil end

-- Tear down the vendored WebSocket + its binding from the previous instance
if gWebSocket then pcall(function() gWebSocket:Close() end); gWebSocket = nil end

-- Reset global state to ensure clean state on driver reload (see §7.5)
gState = { ... }
```

> **Note:** a legacy `gPingTimerId` cancel is also kept *only* as OTA cleanup for pre-Phase-2 installs (the live keepalive timer is `gKeepaliveTimerId`). There is no `NETWORK_BINDING_ID` / static binding `6001` anymore — the vendored `websocket.lua` allocates the binding dynamically (6100-6199); the legacy disconnect targets the hard-coded old `6001` defensively. See §8 and changelog `2026060302`.

### 3.4 Property System

Properties are defined in XML and accessed via:
```lua
local value = Properties["Property Name"]
```

Property changes trigger:
```lua
function OnPropertyChanged(strProperty)
    if strProperty == "IP Address" then
        -- Handle change
    end
end
```

### 3.5 Timer System

```lua
-- One-shot timer (returns timer object)
local timer = C4:SetTimer(milliseconds, function(timer)
    -- Callback code
end, false)

-- Repeating timer
local timer = C4:SetTimer(milliseconds, function(timer)
    -- Callback code
end, true)

-- Cancel timer
timer:Cancel()
```

**CRITICAL**: Always use inline anonymous functions for timer callbacks. Named function references can cause closure issues where the function captures stale variable values.

### 3.6 Network Connections

> **Superseded by the vendored WebSocket module (C1 Phase 2, `2026060302`).** The driver no longer calls `C4:CreateNetworkConnection`/`NetConnect`/`SendToNetwork` directly. `Connect()` builds a `ws://<ip>:<port>/` URL and calls `WebSocket:new(url)`; the vendored `websocket.lua` owns the binding (allocated dynamically in 6100-6199) and the raw socket calls. Outbound app frames go through `SendWebSocketMessage` → `gWebSocket:Send`. The low-level API below is kept as background reference for how Control4 networking works underneath the module.

```lua
-- (Underlying Control4 network API — now driven by the vendored module, not the driver directly)
C4:CreateNetworkConnection(binding, ipAddress)
C4:NetConnect(binding, port)
C4:NetDisconnect(binding, port)
C4:SendToNetwork(binding, port, data)
```

Network callbacks: the driver's top-level `OnConnectionStatusChanged` / `ReceivedFromNetwork` are thin shims that delegate to the vendored dispatchers (`OCS[idBinding]` / `RFN[idBinding]`) for the WebSocket-owned binding — the driver itself no longer branches on `ONLINE`/`OFFLINE` or parses raw frames:

```lua
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    -- delegates to OCS[idBinding] (vendored); the module then calls back into
    -- OnWebSocketEstablished / OnWebSocketOffline.
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    -- delegates to RFN[idBinding] (vendored); the module strips framing and
    -- surfaces one decoded payload via OnWebSocketMessage → HandleProflameMessage.
end
```

### 3.7 Proxy Communication

```lua
-- Send notification to proxy
C4:SendToProxy(proxyId, "NOTIFICATION_NAME", {param1 = value1})

-- Handle commands from proxy
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "SET_MODE_HVAC" then
        local mode = tParams["MODE"]
        -- Handle command
    end
end
```

---

## 4. ThermostatV2 Proxy Integration

### 4.1 Proxy Declaration (XML)

```xml
<proxies>
  <proxy proxybindingid="5001" name="Proflame Fireplace"
         small_image="icons/device_sm.png" large_image="icons/device_lg.png"
         image_source="c4z">thermostatV2</proxy>
</proxies>
```

### 4.2 Key Capabilities

```xml
<capabilities>
  <has_extras>true</has_extras>
  <can_heat>True</can_heat>
  <can_cool>False</can_cool>
  <can_do_auto>False</can_do_auto>
  <can_change_scale>True</can_change_scale>
  <temperature_scale>FAHRENHEIT</temperature_scale>
  <has_single_setpoint>True</has_single_setpoint>
  <split_setpoints>False</split_setpoints>
  <setpoint_heat_min_f>60</setpoint_heat_min_f>
  <setpoint_heat_max_f>90</setpoint_heat_max_f>
  <hvac_modes>Off,Heat</hvac_modes>
  <hvac_states>Off,Heat</hvac_states>
  <has_fan_mode>True</has_fan_mode>
  <can_change_fan_modes>True</can_change_fan_modes>
  <fan_modes>Off,Low,Medium,High</fan_modes>
  <can_preset>False</can_preset>
  <can_preset_schedule>False</can_preset_schedule>
  <scheduling>False</scheduling>
  <can_schedule>False</can_schedule>
  <hold_modes>Low Flame,Medium Flame,High Flame</hold_modes>
</capabilities>
```

### 4.3 HVAC Modes

| Mode | Description |
|------|-------------|
| `Off` | Fireplace off |
| `Heat` | Fireplace on (Manual, Smart, or Eco mode) |

### 4.4 Fan Modes

Fan speed is mapped to standard thermostat fan modes:

| Fan Level | Mode |
|-----------|------|
| 0 | Off |
| 1-2 | Low |
| 3-4 | Medium |
| 5-6 | High |

### 4.5 Presets Disabled

Thermostat Presets are disabled because Navigator did not expose this menu reliably for tap-based flame/timer controls. Operating modes remain available through the Extras `Mode` list.

The legacy `SET_PRESET` command is retained for existing Composer programming and logs a deprecation message before routing `Manual`, `Smart`, or `Eco` to the matching mode command. New programming should use explicit mode commands or the Extras `Mode` list.

### 4.6 Hold Modes (Flame Presets)

The Hold button remains visible with custom flame hold modes. Runtime testing showed the documented `Permanent` hold value renders under the Hold button but does not provide useful flame selections, so this driver keeps custom Low/Medium/High values and refreshes them dynamically. Navigator may still leave the under-button label blank because the SDK documents only standard thermostat hold values.

| Hold Mode | Flame Level |
|-----------|-------------|
| Low Flame | 1 |
| Medium Flame | 3 |
| High Flame | 6 |

### 4.7 Flame Level Command Side Effect

`Set Flame Level` is a Manual-mode flame command. If confirmed state is Smart, Eco, Off, or Standby, the driver first sends `main_mode=5` (Manual), then sends `flame_control` after the mode-ready delay. This intentionally gives direct flame control but exits thermostat operation. Mode-only commands such as Set Mode Manual, Smart, and Eco do not adjust flame or timer values.

The driver does not advertise thermostat scheduling capabilities because it does not implement schedule storage or execution.

### 4.8 Key Proxy Notifications

```lua
-- Temperature update (MUST be in Celsius for proxy)
local tempC = FahrenheitToCelsius(tempF)
C4:SendToProxy(5001, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})

-- HVAC mode change
C4:SendToProxy(5001, "HVAC_MODE_CHANGED", {MODE = "Heat"})
C4:SendToProxy(5001, "HVAC_STATE_CHANGED", {STATE = "Heat"})

-- Heat setpoint change (MUST be in Celsius)
C4:SendToProxy(5001, "HEAT_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
C4:SendToProxy(5001, "SINGLE_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})

-- Fan mode change
C4:SendToProxy(5001, "FAN_MODE_CHANGED", {MODE = "Low"})

-- Preset/operating mode change
C4:SendToProxy(5001, "HOLD_MODE_CHANGED", {MODE = "Low Flame"})

-- Allowed modes (send on connect)
C4:SendToProxy(5001, "ALLOWED_FAN_MODES_CHANGED", {MODES = "Off,Low,Medium,High"})
C4:SendToProxy(5001, "ALLOWED_HVAC_MODES_CHANGED", {MODES = "Off,Heat"})
```

**CRITICAL**: The proxy expects temperatures in Celsius, even if the display scale is Fahrenheit. Always convert before sending.

### 4.9 Key Proxy Commands (ReceivedFromProxy)

| Command | Parameters | Description |
|---------|------------|-------------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode (Off/Heat) |
| `SET_SETPOINT_HEAT` | SETPOINT, CELSIUS, FAHRENHEIT | Set heat setpoint |
| `SET_SETPOINT_SINGLE` | SETPOINT | Set single setpoint |
| `SET_MODE_FAN` | MODE | Set fan mode (Off/Low/Medium/High) |
| `SET_SCALE` | SCALE | Change temperature scale |
| `SET_MODE_HOLD` | MODE | Set flame preset hold mode (Low/Medium/High Flame) |
| `GET_EXTRAS_SETUP` | - | Request extras XML |
| `GET_EXTRAS_STATE` | - | Request extras state |

### 4.10 Static XML vs Runtime UI Capabilities

Treat `driver.xml` as the stable install-time contract. Static proxy, connection, property, command, and capability edits can cause heavier Control4 reload behavior than Lua-only/runtime UI refreshes, including possible Director restart/reload. Prefer runtime proxy notifications for Navigator experiments whenever the ThermostatV2 SDK provides an equivalent.

| UI Surface | Preferred Update Path | Static XML Guidance |
|------------|-----------------------|---------------------|
| Hold modes | `DYNAMIC_CAPABILITIES_CHANGED` + `HOLD_MODE_CHANGED` | Keep XML stable; custom labels may still render blank because the SDK documents standard thermostat hold labels. |
| Fan modes | `DYNAMIC_CAPABILITIES_CHANGED` + `ALLOWED_FAN_MODES_CHANGED` | Keep broad static fan support; refine runtime state in Lua. |
| HVAC modes | `DYNAMIC_CAPABILITIES_CHANGED` + `ALLOWED_HVAC_MODES_CHANGED` | Mode-only changes should not require XML capability churn. |
| Extras controls | `DataToUI` / Extras setup refresh | Keep `has_extras=true` static, then publish control layout at runtime. |
| Presets | Runtime-disabled unless proven otherwise | Stable baseline is `can_preset=false`; do not reintroduce preset XML for experiments without Director restart notes. |

PRs that edit static `driver.xml` capability/proxy/connection/property metadata must include Director restart/reload notes and explain why runtime proxy updates were not sufficient. The current XML restart-risk matrix is tracked in issue #39 and should be filled from real Controller/Navigator testing.

Runtime refreshes send the full ThermostatV2 capability snapshot, not only the field that triggered the refresh. For example, a Hold-mode refresh also republishes preset, fan, HVAC, and Extras capability state so Navigator does not retain stale mixed capability data.

Use `scripts/build_restart_matrix_variants.py --start-version <future-version>` to generate isolated A/B `.c4z` packages for issue #39/#41 testing. The generated packages are not release artifacts; they are used to fill the restart matrix before simplifying static XML. Each variant removes or minimizes one candidate capability group while the runtime refresh continues to publish the corresponding capability state.

Each run must use versions above any prior restart-matrix package installed on a controller. Generated packages intentionally differ from the working tree and should not be validated with `scripts/validate.sh`.

---

## 5. Extras UI System

### 5.1 Overview

The Extras UI allows custom controls to appear in the Control4 app. For thermostats, this appears as an additional panel with custom sliders, buttons, and lists.

### 5.2 Enabling Extras

In capabilities:
```xml
<has_extras>true</has_extras>
```

### 5.3 Extras XML Structure

```xml
<extras_setup>
  <extra>
    <section label="Section Name">
      <!-- Controls go here -->
    </section>
  </extra>
</extras_setup>
```

### 5.4 Control Types

#### Slider
```xml
<object type="slider"
        id="unique_id"
        label="Display Label"
        command="COMMAND_NAME"
        min="0"
        max="100"
        value="50"/>
```

#### List (Single Selection)
```xml
<object type="list"
        id="unique_id"
        label="Display Label"
        command="COMMAND_NAME">
  <list maxselections="1" minselections="1">
    <item text="Option 1" value="opt1"/>
    <item text="Option 2" value="opt2"/>
  </list>
</object>
```

### 5.5 Current Extras Layout

```xml
<extras_setup>
  <extra>
    <section label="Operating Mode">
      <object type="list" id="pf_mode" label="Mode" command="SELECT_MODE">
        <list maxselections="1" minselections="1">
          <!-- Items reordered with current mode first (Ecobee-style) -->
          <item text="Off" value="off"/>
          <item text="Manual" value="manual"/>
          <item text="Smart Thermostat" value="smart"/>
          <item text="Eco" value="eco"/>
        </list>
      </object>
    </section>
    <section label="Fireplace Controls">
      <object type="slider" id="pf_flame" label="Flame Level"
              command="SET_FLAME_LEVEL" min="1" max="6" value="3"/>
      <object type="slider" id="pf_fan" label="Fan Speed"
              command="SET_FAN_LEVEL" min="0" max="6" value="0"/>
      <object type="slider" id="pf_light" label="Downlight"
              command="SET_LIGHT_LEVEL" min="0" max="6" value="0"/>
    </section>
    <section label="Auto-Off Timer">
      <object type="slider" id="pf_timer" label="Timer (1h30m)"
              command="SET_TIMER_MINUTES" min="0" max="360" value="90"/>
    </section>
  </extra>
</extras_setup>
```

### 5.6 Sending Extras to UI

```lua
function SetupExtras()
    local xml = GetExtrasXML()
    -- Primary method - DataToUI
    C4:SendDataToUI(xml)
    -- Also send via proxy notification
    C4:SendToProxy(5001, "EXTRAS_SETUP_CHANGED", {XML = xml})
end
```

### 5.7 Handling Extras Requests

```lua
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "GET_EXTRAS_SETUP" then
        return GetExtrasXML()  -- Return XML directly
    elseif strCommand == "GET_EXTRAS_STATE" then
        return GetExtrasXML()  -- Contains current values
    end
end
```

### 5.8 Receiving Extras Commands

```lua
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "SET_FLAME_LEVEL" then
        local level = tParams["VALUE"] or tParams["value"]
        -- Handle slider change
    elseif strCommand == "SELECT_MODE" then
        local mode = tParams["VALUE"] or tParams["value"]
        -- Handle list selection (manual/smart/eco)
    end
end
```

**Note**: Parameter names may be uppercase or lowercase depending on the control type. Always check both.

### 5.9 Updating Extras Values

Since slider values are embedded in the XML, resend the entire extras XML to update displayed values:

```lua
function UpdateExtrasState()
    -- Throttle to avoid spamming during initialization
    if gExtrasThrottle then return end
    gExtrasThrottle = true
    C4:SetTimer(500, function()
        gExtrasThrottle = false
        SetupExtras()
    end, false)
end

-- For critical updates that must be immediate (e.g., timer countdown):
function UpdateTimerExtras()
    SetupExtras()  -- No throttle
end
```

---

## 6. Timer System

### 6.1 Timer Behavior Overview

The fireplace timer is an auto-off feature:
1. User sets a duration (e.g., 60 minutes)
2. Timer counts down
3. When timer reaches 0, fireplace turns off

### 6.2 Device Timer Quirks

**CRITICAL**: The device has several non-intuitive behaviors:

1. **Timer values persist**: Even when timer is stopped, `timer_set` retains the last value
2. **timer_count reports set value when stopped**: If timer is not running, `timer_count` equals `timer_set`
3. **Rapid updates**: Device sends `timer_count` every ~1 second when timer is running
4. **Delayed response**: Commands may take 200-750ms to take effect
5. **Default values on standby**: Device sends default timer values when entering standby which should be ignored

### 6.3 Timer State Management

Use separate tracking for:
- **timer_set**: What the user/driver has requested (driver-controlled)
- **timer_count**: What the device reports (device-controlled)
- **timer_status**: Whether timer is active (0 or 1)

**Key Principle**: Only update `timer_set` from user commands, never from device responses.

### 6.4 Suppression Flag Pattern

When changing timer values, suppress device updates to prevent race conditions:

```lua
gSuppressTimerUpdates = false
gTimerExpired = false

-- In SET_TIMER_MINUTES handler:
gSuppressTimerUpdates = true
gTimerExpired = false  -- Clear expired flag
gState.timer_set = tostring(msValue)
gState.timer_count = tostring(msValue)
gState.timer_status = "1"
-- Send commands...
UpdateTimerExtras()  -- Immediate update
C4:SetTimer(2000, function()
    gSuppressTimerUpdates = false
end, false)

-- In timer_count status handler:
if gSuppressTimerUpdates then
    return  -- Ignore device updates while suppressed
end
if gTimerExpired then
    return  -- Ignore stale updates after timer expired
end
```

### 6.5 Timer Expiry Detection

```lua
-- Detect timer expiry: count reaches 0
if newCount == 0 and oldCount > 0 then
    gTimerExpired = true
    gState.timer_count = "0"
    gState.timer_set = "0"
    UpdateTimerExtras()
    return
end
```

### 6.6 Slider Countdown Display

To make the slider count down with the timer, the `timer_count` status handler detects a whole-minute change and refreshes the Extras immediately. The handler uses **`floor`** for this minute-change detection (it does not consult `timer_status`):

```lua
local newCount = tonumber(value) or 0
local newMinutes = math.floor(newCount / 60000)

local oldCount = tonumber(gState.timer_count) or 0
local oldMinutes = math.floor(oldCount / 60000)

gState.timer_count = value

if oldMinutes ~= newMinutes then
    gState.timer_set = tostring(newMinutes * 60000)
    UpdateTimerExtras()  -- Immediate, not throttled
end
```

> The `ceil`-when-active rounding (so an active timer shows at least 1 m until it truly expires) lives in **`GetExtrasXML()`** for the slider's rendered `value`/label — not in this minute-change detector.

### 6.7 Timer Display Format

Show remaining time in human-readable format:

```lua
local function FormatTimerLabel(minutes)
    if minutes <= 0 then
        return "Off"
    elseif minutes >= 60 then
        local hours = math.floor(minutes / 60)
        local mins = minutes % 60
        if mins > 0 then
            return string.format("%dh%dm", hours, mins)
        else
            return string.format("%dh", hours)
        end
    else
        return string.format("%dm", minutes)
    end
end
```

### 6.8 Auto-Timer on Turn-On

When explicitly turning on the fireplace, automatically set timer and flame. `Default Timer (minutes)` is used by Turn On and is also re-used by the timer-required safety policy (§6.9) when the device is turned on by other means, such as the physical remote. Mode-only changes such as selecting Manual, Smart, or Eco send only the mode command; the driver does not adjust flame or timer values. Set Timer uses the requested `Minutes` value, including when it first turns on an off fireplace. Because on states require a running timer, Default Timer `0` means Turn On (and any other on-state without a timer) will be forced back off after confirmed status shows no running timer.

```lua
-- In SET_MODE_HVAC handler when mode == "Heat":
SendProflameCommand("main_mode", GetDefaultOnMode())
local defaultFlame = tonumber(Properties["Default Flame Level"]) or 6
local defaultTimer = tonumber(Properties["Default Timer (minutes)"]) or 180
C4:SetTimer(750, function()
    SendProflameCommand("flame_control", tostring(defaultFlame))
    if defaultTimer > 0 then
        local msValue = defaultTimer * 60000
        SendProflameCommand("timer_set", tostring(msValue))
        gState.timer_set = tostring(msValue)
        C4:SetTimer(200, function()
            SendProflameCommand("timer_status", "1")
        end, false)
    end
end, false)
```

### 6.9 Timer-Required Safety Policy

Manual, Smart, and Eco are treated as on states that require an active auto-off timer. Confirmed status processing enforces this policy after `main_mode`, `timer_status`, or timer-expiry updates. When the fireplace is on and `timer_status` is not `1`, the response depends on *why* no timer is running:

- **No timer was ever armed** (e.g. the physical remote turned the fireplace on): the driver arms the configured `Default Timer (minutes)` and lets the device keep running, then mirrors the resulting state. It does **not** force the fireplace off. Forcing off here produced an on/off war with the remote — the device re-asserts the on mode, the driver slams it off, and the two fight every ~1 s. Arming sets `gSuppressTimerUpdates`, so on-mode echoes that arrive while the timer is being armed are skipped until `timer_status` settles to `1`; this prevents both the war and any arm spam.
- **The auto-off timer counted down to zero** (`gTimerCountExpired`): the driver logs the safety action and sends the existing Turn Off sequence. Auto-off still works exactly as before — a genuine expiry turns the fireplace off rather than re-arming forever. This case is keyed on `gTimerCountExpired`, set **only** when `timer_count` transitions from `>0` to `0`, **not** on `gTimerExpired` — the latter is also set on every `timer_status=0` (remote turn-on, Cancel Timer, device standby defaults), so using it would force-off a remote turn-on and re-create the war. `gTimerCountExpired` is cleared when a timer starts (`timer_status=1` / arm) or the fireplace goes to an off mode, so the next on-state arms normally.
- **`Default Timer (minutes)` is `0`** (timer arming disabled): there is no timer to arm, so the driver falls back to forcing the fireplace off after confirmed status shows no running timer. This is the documented escape hatch for users who do not want automatic timer arming.
- If `main_mode` is on but `timer_status` has not arrived yet, the driver defers briefly. If `timer_status` remains unknown after that status-sync grace period, it is treated as not running.
- Enforcement is skipped while `gSuppressTimerUpdates` is true so normal Turn On and Set Timer flows are not interrupted while the timer is being armed.
- A pending safety force-off is tracked (for the expired / Default-Timer-0 force-off paths) so stale on-state echoes do not repeatedly spam off commands.
- This intentionally changes earlier behavior: Cancel Timer while the fireplace is on no longer forces Turn Off when a Default Timer is configured — it re-arms the Default Timer instead.
- The unknown-`timer_status` grace period is 1500 ms, long enough for the normal initial status burst to deliver adjacent timer fields before enforcement treats the timer state as missing.

---

## 7. State Management

### 7.1 Global State Table

```lua
gState = {
    main_mode = "0",
    flame_control = "0",
    fan_control = "0",
    lamp_control = "0",
    temperature_set = "700",
    room_temperature = "700",
    thermo_control = "0",
    pilot_control = "0",
    aux_control = "0",
    split_control = "0",
    burner_status = "0",
    wifi_signal_str = "0",
    timer_status = "0",
    timer_set = "0",
    timer_count = "0"
}
```

### 7.2 Connection State

```lua
gConnected = false
gConnecting = false
gHandshakeComplete = false
gMissedKeepalives = 0   -- keepalive watchdog (§8.5)
```

(The old `gReceiveBuffer` hand-rolled-framing buffer was removed in C1 Phase 2 — the vendored WebSocket module owns buffering now.)

### 7.3 UI State

```lua
gExtrasThrottle = false      -- Prevent extras spam
gSuppressTimerUpdates = false -- Suppress device timer updates during changes
gTimerExpired = false         -- Set when timer reaches 0
```

### 7.4 Pending State (Anti-Jump)

```lua
gPendingSetpointF = nil  -- Locked setpoint to prevent UI jumping
gPendingTimer = nil      -- Timer for pending setpoint expiry
```

When user changes setpoint:
```lua
function SetPendingSetpoint(tempF)
    gPendingSetpointF = tempF
    if gPendingTimer then gPendingTimer:Cancel() end
    gPendingTimer = C4:SetTimer(5000, function()
        gPendingSetpointF = nil
    end, false)
end

-- In ProcessStatusUpdate for temperature_set:
if gPendingSetpointF ~= nil then
    if math.abs(incomingF - gPendingSetpointF) < 1 then
        gPendingSetpointF = nil  -- Confirmed
    else
        return  -- Ignore stale value
    end
end
```

### 7.5 State Reset on Reconnect

```lua
function ResetDriverState()
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gExtrasThrottle = false
    SetTimerSuppression(false, "driver state reset")  -- not a bare gSuppressTimerUpdates = false
    gTimerExpired = false
    gState = { ... }  -- Reset to defaults
    -- Also resets gLastMainMode / gLastConnectionOnline / gStatusSeen /
    -- gTurnOffInProgress / gTimerSafetyOffPending / gFirmwareVersions, and cancels
    -- every timer (reconnect, connect-timeout, status-refresh, keepalive,
    -- pending-command, turn-off confirm/retry, timer-safety).
end
```

(The real `ResetDriverState()` is more thorough than this sketch; it no longer touches the removed `gReceiveBuffer`.)

---

## 8. Network Connection Management

### 8.1 Connection Lifecycle

```
[Disconnected] -> Connect() -> [Connecting] -> OnConnectionStatusChanged("ONLINE")
    -> Send WebSocket Handshake -> Receive Handshake Response
    -> [Connected/Handshake Complete] -> Send PROFLAMECONNECTION -> Receive status
```

### 8.2 WebSocket Implementation

> **Historical / superseded.** As of C1 Phase 2 (driver `2026060302`) the driver no longer hand-rolls WebSocket framing. The vendored Snap One module `vendor/drivers-common-public/module/websocket.lua` owns the RFC 6455 handshake, framing, masking, and fragmentation; `Connect()` builds a `ws://<ip>:<port>/` URL and calls `WebSocket:new(url)`. The hand-rolled helpers below (`GenerateWebSocketKey`/`BuildWebSocketHandshake`/`CreateWebSocketFrame`/…) were deleted then and are kept here only as a wire-format reference. Note the driver sets `ws.ping_interval = 0` to disable the module's RFC 6455 control-frame ping (see §2.6 / §8.5).

Since Control4 doesn't provide a WebSocket library, the original driver implemented it manually (now vendored — see note above):

```lua
function GenerateWebSocketKey()
    local bytes = GenerateRandomBytes(16)
    return Base64Encode(bytes)
end

function BuildWebSocketHandshake(host, port)
    gWebSocketKey = GenerateWebSocketKey()
    return "GET / HTTP/1.1\r\n" ..
           "Host: " .. host .. ":" .. tostring(port) .. "\r\n" ..
           "Upgrade: websocket\r\n" ..
           "Connection: Upgrade\r\n" ..
           "Sec-WebSocket-Key: " .. gWebSocketKey .. "\r\n" ..
           "Sec-WebSocket-Version: 13\r\n" ..
           "Origin: http://" .. host .. "\r\n" ..
           "\r\n"
end

function CreateWebSocketFrame(data, opcode)
    opcode = opcode or 0x01  -- Text frame
    local frame = ""
    frame = frame .. string.char(bit.bor(0x80, opcode))  -- FIN + opcode
    local mask = GenerateRandomBytes(4)
    local len = #data

    -- Length encoding
    if len <= 125 then
        frame = frame .. string.char(bit.bor(0x80, len))  -- Masked + length
    elseif len <= 65535 then
        frame = frame .. string.char(bit.bor(0x80, 126))
        frame = frame .. string.char(math.floor(len / 256))
        frame = frame .. string.char(len % 256)
    else
        frame = frame .. string.char(bit.bor(0x80, 127))
        for i = 7, 0, -1 do
            frame = frame .. string.char(math.floor(len / (256 ^ i)) % 256)
        end
    end

    frame = frame .. mask

    -- Masked payload
    for i = 1, #data do
        local byte = data:byte(i)
        local maskByte = mask:byte(((i - 1) % 4) + 1)
        frame = frame .. string.char(bit.bxor(byte, maskByte))
    end

    return frame
end
```

### 8.3 Bit Operations Fallback

Control4 may not have the `bit` library, so provide fallback:

```lua
do
    local _bit = rawget(_G, "bit") or rawget(_G, "bit32")
    if not _bit then
        _bit = {}
        function _bit.bxor(a, b)
            local result = 0
            local bitval = 1
            a = a or 0
            b = b or 0
            for i = 0, 31 do
                local abit = a % 2
                local bbit = b % 2
                if abit ~= bbit then
                    result = result + bitval
                end
                a = math.floor(a / 2)
                b = math.floor(b / 2)
                bitval = bitval * 2
            end
            return result
        end
        -- Similarly for band, bor
    end
    bit = _bit
end
```

### 8.4 Reconnection Strategy

```lua
gReconnectDelay = 10000  -- 10 seconds (configurable)

function ScheduleReconnect()
    StopReconnectTimer()
    local delay = (tonumber(Properties["Reconnect Delay (seconds)"]) or 10) * 1000
    gReconnectTimerId = C4:SetTimer(delay, function()
        gReconnectTimerId = nil
        if not gConnected and not gConnecting then
            Connect()
        end
    end, false)
end

-- The offline → reconnect transition now flows through the vendored module's
-- callback into OnWebSocketOffline (not the driver branching on strStatus here):
function OnWebSocketOffline(ws)
    gConnected = false
    gHandshakeComplete = false
    StopStatusRefreshTimer()
    StopKeepaliveTimer()       -- (was StopPingTimer, pre-#86)
    ScheduleReconnect()
end
```

### 8.5 Ping Keep-Alive

The app-level `PROFLAMEPING` keepalive (the RFC 6455 control-frame ping is disabled for this device — see §2.6). Sent every `Keepalive Interval (seconds)` (default 15, 0-25, 0 disables); `gMissedKeepalives` is a half-open-link watchdog that forces a reconnect after 3 silent intervals, deferred to a 1 ms one-shot so the firing timer is never self-cancelled. Any inbound frame resets the miss counter.

```lua
function StartKeepaliveTimer()
    StopKeepaliveTimer()
    local seconds = tonumber(Properties["Keepalive Interval (seconds)"]) or 15
    if seconds <= 0 then return end          -- 0 disables
    gMissedKeepalives = 0
    gKeepaliveTimerId = C4:SetTimer(seconds * 1000, function() OnKeepaliveTimer() end, true)
end

function OnKeepaliveTimer()
    if not (gConnected and gHandshakeComplete) then return end
    gMissedKeepalives = (gMissedKeepalives or 0) + 1
    if gMissedKeepalives >= 3 then            -- no device traffic for 3 intervals
        gMissedKeepalives = 0
        gKeepaliveReconnectTimerId = C4:SetTimer(1, function() Reconnect() end, false)
        return
    end
    SendWebSocketMessage("PROFLAMEPING")      -- device replies PROFLAMEPONG
end
```

> Historical: pre-C1-Phase-2 this read the now-removed `Ping Interval (seconds)` property; C1 Phase 2 replaced it with the vendored 30 s RFC 6455 ping, which the device closed on — B4/#86 restored the app-level keepalive above on the `Keepalive Interval (seconds)` property. See changelog 2026061601.

---

## 9. XML Configuration

### 9.1 Complete driver.xml Structure

```xml
<?xml version="1.0"?>
<devicedata>
  <small image_source="c4z">icons/device_sm.png</small>
  <large image_source="c4z">icons/device_lg.png</large>
  <agent>false</agent>
  <copyright>Copyright notice</copyright>
  <name>Driver Name</name>
  <model>Model Name</model>
  <manufacturer>Manufacturer</manufacturer>
  <driver>DriverWorks</driver>
  <control>lua_gen</control>
  <version>2026061604</version>
  <auto_update>false</auto_update>  <!-- GitHub-release self-updater, not Control4's native menu (§1.5) -->

  <proxies>
    <proxy proxybindingid="5001" name="Display Name"
           small_image="icons/device_sm.png" large_image="icons/device_lg.png"
           image_source="c4z">thermostatV2</proxy>
  </proxies>

  <states/>

  <config>
    <documentation file="www/documentation.html"/>
    <properties>...</properties>
    <commands>...</commands>
    <script file="driver.lua" encryption="0" jit="1"/>
  </config>

  <events>...</events>
  <connections>...</connections>
  <capabilities>...</capabilities>
</devicedata>
```

### 9.2 Property Definition

**CRITICAL**: Use `<name>` tag, NOT `<n>`. Control4 does not support abbreviated tags.

```xml
<property>
  <name>Property Name</name>
  <type>STRING</type>
  <default>default value</default>
  <readonly>false</readonly>
</property>

<property>
  <name>Numeric Property</name>
  <type>RANGED_INTEGER</type>
  <minimum>1</minimum>
  <maximum>100</maximum>
  <default>50</default>
  <readonly>false</readonly>
</property>

<property>
  <name>List Property</name>
  <type>LIST</type>
  <items>
    <item>Option 1</item>
    <item>Option 2</item>
  </items>
  <default>Option 1</default>
  <readonly>false</readonly>
</property>
```

### 9.3 Connection Definitions

> **No static network/TCP binding.** C1 Phase 2 (`2026060302`) removed the static `<connection id="6001">` TCP binding; the vendored `websocket.lua` now allocates a network binding dynamically (scanning 6100-6199). The current `driver.xml` declares only the two proxy/UI connections below (`5001` thermostat and `7000` room selection).

```xml
<connections>
  <!-- Thermostat proxy connection -->
  <connection>
    <id>5001</id>
    <facing>6</facing>
    <connectionname>Thermostat</connectionname>
    <type>2</type>
    <consumer>False</consumer>
    <classes>
      <class>
        <classname>THERMOSTAT</classname>
      </class>
    </classes>
  </connection>

  <!-- Room selection -->
  <connection>
    <id>7000</id>
    <facing>6</facing>
    <connectionname>Room Selection</connectionname>
    <type>7</type>
    <consumer>False</consumer>
    <classes>
      <class>
        <autobind>True</autobind>
        <classname>TEMPERATURE</classname>
      </class>
      <class>
        <autobind>True</autobind>
        <classname>TEMPERATURE_CONTROL</classname>
      </class>
    </classes>
  </connection>
</connections>
```

### 9.4 Event Definition

```xml
<events>
  <event>
    <id>1</id>
    <name>Fireplace Turned On</name>
    <description>Fireplace has been turned on</description>
  </event>
  <event>
    <id>2</id>
    <name>Fireplace Turned Off</name>
    <description>Fireplace has been turned off</description>
  </event>
  <event>
    <id>3</id>
    <name>Mode Changed</name>
    <description>Operating mode has changed</description>
  </event>
  <event>
    <id>4</id>
    <name>Connection Lost</name>
    <description>Connection to fireplace lost</description>
  </event>
  <event>
    <id>5</id>
    <name>Connection Restored</name>
    <description>Connection to fireplace restored</description>
  </event>
</events>
```

Runtime event behavior:

- `Fireplace Turned On` fires when confirmed `main_mode` changes from Off/Standby to Manual, Smart, or Eco.
- `Fireplace Turned Off` fires when confirmed `main_mode` changes from Manual, Smart, or Eco to Off/Standby.
- `Mode Changed` fires on confirmed `main_mode` changes after the first status value establishes a baseline.
- `Connection Restored` fires after the WebSocket handshake completes.
- `Connection Lost` fires when a previously handshaken connection is lost.

---

## 10. Common Pitfalls and Solutions

### 10.1 XML Tag Names

**Problem**: Using `<n>` instead of `<name>`
**Solution**: Always use full tag names: `<name>`, `<description>`, etc.

### 10.2 Timer Callback Closures

**Problem**: Named function callbacks capture stale variable values
**Solution**: Always use inline anonymous functions

```lua
-- WRONG
local function callback()
    print(someVariable)  -- May be stale
end
C4:SetTimer(1000, callback, false)

-- CORRECT
C4:SetTimer(1000, function(timer)
    print(someVariable)  -- Current value
end, false)
```

### 10.3 JSON Formatting

**Problem**: Proflame device rejects JSON with spaces
**Solution**: Build JSON strings directly without formatting

```lua
-- WRONG: spaces
local cmd = '{ "command": "set_control", "name": "main_mode", "value": "5" }'

-- CORRECT
local cmd = '{"command":"set_control","name":"main_mode","value":"5"}'
```

### 10.4 Throttle Race Conditions

**Problem**: Throttled updates read stale state values
**Solution**: Use immediate updates for critical state changes

```lua
-- Throttled function (for normal updates)
function UpdateExtrasState()
    if gExtrasThrottle then return end
    gExtrasThrottle = true
    C4:SetTimer(500, function()
        gExtrasThrottle = false
        SetupExtras()
    end, false)
end

-- Immediate function (for critical updates like timer)
function UpdateTimerExtras()
    SetupExtras()  -- No throttle
end
```

### 10.5 Device Timer Value Persistence

**Problem**: Device keeps sending old timer values after timer is changed
**Solution**: Use suppression flag to ignore device updates during transitions

### 10.6 Proxy Parameter Case Sensitivity

**Problem**: tParams keys may be uppercase or lowercase
**Solution**: Check both cases

```lua
local value = tParams["VALUE"] or tParams["value"]
```

### 10.7 Temperature Scale Mismatch

**Problem**: Proxy expects Celsius, display shows Fahrenheit
**Solution**: Always convert to Celsius before sending to proxy

```lua
local tempC = FahrenheitToCelsius(tempF)
C4:SendToProxy(5001, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})
```

### 10.8 Driver Update Not Taking Effect

**Problem**: Control4 caches old driver state
**Solution**: Implement `OnDriverUpdated()` callback AND cleanup on script load

```lua
-- At script load time (before functions):
if gPingTimerId then pcall(function() gPingTimerId:Cancel() end) end
if gConnected then pcall(function() C4:NetDisconnect(...) end) end
gState = { ... }  -- Reset

-- In OnDriverUpdated:
function OnDriverUpdated()
    StopReconnectTimer()
    Disconnect()                 -- internally runs StopKeepaliveTimer (the old StopPingTimer is gone)
    ResetDriverState()
    C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ")")
    C4:SetTimer(1000, function()
        SetupExtras()
        Connect()
    end, false)
end
```

### 10.9 WebSocket Frame Parsing

> **Superseded by the vendored WebSocket module (C1 Phase 2).** Partial/coalesced-frame buffering and reassembly are now handled inside `vendor/drivers-common-public/module/websocket.lua`; the driver no longer keeps a `gReceiveBuffer` or runs `ParseWebSocketFrame`/`HandleWebSocketMessage` (all removed). The current top-level `ReceivedFromNetwork` just forwards to the vendored `RFN[idBinding]` dispatcher, and the module surfaces one already-decoded payload at a time via `OnWebSocketMessage` → `HandleProflameMessage`. The historical hand-rolled approach was:

```lua
-- HISTORICAL (pre-C1-Phase-2) — buffer + parse complete frames manually:
gReceiveBuffer = ""

function ReceivedFromNetwork(idBinding, nPort, strData)
    gReceiveBuffer = gReceiveBuffer .. strData

    while #gReceiveBuffer > 0 do
        local opcode, payload, remaining = ParseWebSocketFrame(gReceiveBuffer)
        if not opcode then break end
        gReceiveBuffer = remaining
        HandleWebSocketMessage(opcode, payload)
    end
end
```

### 10.10 Mode Change Timing

**Problem**: Sending flame_control right after main_mode fails
**Solution**: Add delay between mode change and subsequent commands

```lua
SendProflameCommand("main_mode", MODE_MANUAL)
C4:SetTimer(750, function()
    SendProflameCommand("flame_control", "3")
end, false)
```

---

## 11. Complete Command Reference

### 11.1 Proflame Commands (Send)

| Command | Value | Description |
|---------|-------|-------------|
| `{"command":"set_control","name":"main_mode","value":"0"}` | 0,1,5,6,7 | Set operating mode |
| `{"command":"set_control","name":"flame_control","value":"3"}` | 1-6 | Set flame level |
| `{"command":"set_control","name":"fan_control","value":"2"}` | 0-6 | Set fan speed |
| `{"command":"set_control","name":"lamp_control","value":"4"}` | 0-6 | Set lamp level |
| `{"command":"set_control","name":"temperature_set","value":"700"}` | 600-900 | Set temp (Fx10) |
| `{"command":"set_control","name":"timer_set","value":"3600000"}` | ms | Set timer duration |
| `{"command":"set_control","name":"timer_status","value":"1"}` | 0,1 | Start/stop timer |
| `PROFLAMECONNECTION` | - | Initial connection announcement |
| `PROFLAMEPING` | - | Keep-alive ping |

Manual command-format verification should exercise `main_mode`, `flame_control`, `fan_control`, `lamp_control`, `temperature_set`, `timer_set`, and `timer_status` under the selected `Command Format (non-Turn-Off)` setting and record the status echo that confirms device acceptance. Turn Off verification should separately confirm the legacy-only plan still turns the fireplace off.

### 11.2 Control4 Proxy Commands (Receive)

| Command | Parameters | Action |
|---------|------------|--------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode (Off/Heat) |
| `SET_SETPOINT_HEAT` | SETPOINT, CELSIUS, FAHRENHEIT | Set temperature setpoint |
| `SET_SETPOINT_SINGLE` | SETPOINT | Set single setpoint |
| `SET_MODE_FAN` | MODE | Set fan mode (Off/Low/Medium/High) |
| `SET_SCALE` | SCALE | Change temperature scale |
| `GET_EXTRAS_SETUP` | - | Request extras XML |
| `GET_EXTRAS_STATE` | - | Request extras state |
| `SELECT_MODE` | VALUE | Select mode from extras (`off`/`manual`/`smart`/`eco`; `off` calls `CommandTurnOff()`) |
| `SET_FLAME_LEVEL` | VALUE | Set flame from extras (1-6); switches to Manual first if needed |
| `SET_FAN_LEVEL` | VALUE | Set fan from extras (0-6) |
| `SET_LIGHT_LEVEL` | VALUE | Set lamp from extras (0-6) |
| `SET_TIMER_MINUTES` | VALUE | Set timer from extras (0-360) |

### 11.3 Control4 Proxy Notifications (Send)

| Notification | Parameters | Purpose |
|--------------|------------|---------|
| `TEMPERATURE_CHANGED` | TEMPERATURE, SCALE | Update current temp (Celsius) |
| `HVAC_MODE_CHANGED` | MODE | Update HVAC mode |
| `HVAC_STATE_CHANGED` | STATE | Update HVAC state |
| `HEAT_SETPOINT_CHANGED` | SETPOINT, SCALE | Update setpoint (Celsius) |
| `SINGLE_SETPOINT_CHANGED` | SETPOINT, SCALE | Update single setpoint |
| `FAN_MODE_CHANGED` | MODE | Update fan mode |
| `ALLOWED_FAN_MODES_CHANGED` | MODES | Set available fan modes |
| `ALLOWED_HVAC_MODES_CHANGED` | MODES | Set available HVAC modes |
| `EXTRAS_SETUP_CHANGED` | XML | Update extras UI |

---

## 12. Testing Checklist

For PRs that change command behavior, run the shorter Composer Command Smoke Test in `README.md` or the pull request template and paste the results into the PR. Use the broader checklist below for release validation and larger driver changes.

### 12.1 Connection Tests

- [ ] Driver connects on IP address entry
- [ ] Driver reconnects after network loss
- [ ] Driver reconnects after device power cycle
- [ ] Driver handles invalid IP gracefully
- [ ] Ping/pong keeps connection alive
- [ ] Connection status property updates correctly
- [ ] PROFLAMECONNECTION/PROFLAMECONNECTIONOPEN sequence works

### 12.2 Basic Control Tests

- [ ] Turn fireplace on via Control4 (HVAC mode = Heat)
- [ ] Turn fireplace off via Control4 (HVAC mode = Off)
- [ ] Adjust flame level via extras slider
- [ ] Adjust fan speed via extras slider
- [ ] Adjust lamp level via extras slider
- [ ] Change operating mode via extras list

### 12.3 Timer Tests

- [ ] Set timer when fireplace is off (should turn on)
- [ ] Set timer when fireplace is on
- [ ] Timer slider counts down each minute
- [ ] Timer label updates (e.g., "1h30m" -> "1h29m")
- [ ] Set timer to 0 turns off fireplace
- [ ] Timer slider stays at 0 after turning off
- [ ] Changing timer value mid-countdown works
- [ ] Timer reaching 0 turns off fireplace
- [ ] Timer suppression prevents UI jumping

### 12.4 Temperature Tests

- [ ] Room temperature displays correctly
- [ ] Setpoint changes work
- [ ] Temperature displays in correct scale (F/C)
- [ ] Proxy receives temperatures in Celsius

### 12.5 State Synchronization Tests

- [ ] Fireplace changed via wall switch updates Control4
- [ ] Fireplace changed via mobile app updates Control4
- [ ] Multiple Control4 interfaces stay in sync
- [ ] Driver restart restores correct state

### 12.6 Auto-Settings Tests

- [ ] Default On Mode is applied when turning on
- [ ] Default Flame Level is applied when turning on
- [ ] Default Timer is started by Turn On only
- [ ] Set Timer while off uses the requested timer value, not Default Timer
- [ ] Cancel Timer while on triggers the timer-required safety policy, which re-arms the Default Timer (or, with Default Timer 0, turns the fireplace off)
- [ ] Turning the fireplace on with the physical remote arms the Default Timer instead of fighting it off; the driver mirrors the running state
- [ ] An expired auto-off timer still turns the fireplace off (does not re-arm)
- [ ] An implausible device room-temperature reading (e.g. raw `6845` = 684.5°F) is dropped; the property keeps the last good value
- [ ] Command Format testing records selected format and status echo for main_mode, flame_control, fan_control, lamp_control, temperature_set, timer_set, and timer_status
- [ ] Mode changes from extras do not change flame or timer
- [ ] Set Flame Level changes operating mode to Manual when invoked from Smart, Eco, or Off

### 12.7 Driver Update Tests

- [ ] Driver update applies without controller reboot
- [ ] Version number updates after driver update
- [ ] Connection re-establishes after update
- [ ] State is reset correctly across updates

### 12.8 Edge Cases

- [ ] Very long timer values (6 hours)
- [ ] Rapid slider movements
- [ ] Network disconnect during command
- [ ] Multiple simultaneous commands
- [ ] Timer expiry detection
- [ ] Setpoint anti-jump behavior

---

## Appendix A: Sample Lua Code Structure

> **Illustrative skeleton from the original design — not the current API.** Several names below predate later refactors: C1 Phase 2 (`2026060302`) deleted the hand-rolled WebSocket helpers (`GenerateWebSocketKey`/`BuildWebSocketHandshake`/`CreateWebSocketFrame`/`ParseWebSocketFrame`) and the static `NETWORK_BINDING_ID = 6001` in favor of the vendored `websocket.lua`; B4/#86 replaced `StartPingTimer`/`StopPingTimer`/`gPingTimerId`/`Ping Interval` with `StartKeepaliveTimer`/`StopKeepaliveTimer`/`OnKeepaliveTimer`/`gKeepaliveTimerId` on the `Keepalive Interval (seconds)` property (§8.5). Treat this as a shape-of-the-driver overview; see `src/driver.lua` for the authoritative current API.

```lua
-- Constants
DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2026051731"
DRIVER_DATE = "2026-05-17"
NETWORK_BINDING_ID = 6001
THERMOSTAT_PROXY_ID = 5001

MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_MANUAL = "5"
MODE_SMART = "6"
MODE_ECO = "7"

-- Driver load cleanup (runs immediately)
-- Cancel timers, disconnect, reset state

-- Bit operations fallback
do ... end

-- Global State
gConnected = false
gConnecting = false
gHandshakeComplete = false
gReceiveBuffer = ""
gPingTimerId = nil
gReconnectTimerId = nil
gSuppressTimerUpdates = false
gExtrasThrottle = false
gTimerExpired = false

gState = {
    main_mode = "0",
    flame_control = "0",
    -- ... etc
}

-- Logging
function Log(msg, level) ... end

-- Crypto / Encoding
-- SHA-1 and Base64 come from the Control4 runtime (C4:Hash, C4:Base64Encode).
-- JSON is provided by an inlined vendored copy of Jeffrey Friedl's JSON.lua
-- (version 20211016.28, Creative Commons CC-BY 3.0), exposed as the `JSON`
-- global. The functions below are thin wrappers around it.
function JsonEncode(tbl) ... end    -- -> JSON:encode(tbl)
function JsonDecode(str) ... end    -- -> JSON:decode(str) with string-coercion shim

-- Helper Functions
function BuildSetControlCommand(control, value) ... end
function BuildLegacyIndexedCommand(control, value) ... end
function DecodeTemperature(encoded) ... end
function FahrenheitToCelsius(f) ... end

-- Extras UI
function GetExtrasXML() ... end
function SetupExtras() ... end
function UpdateExtrasState() ... end
function UpdateTimerExtras() ... end

-- WebSocket Functions
function GenerateWebSocketKey() ... end
function BuildWebSocketHandshake(host, port) ... end
function CreateWebSocketFrame(data, opcode) ... end
function ParseWebSocketFrame(data) ... end

-- Network Functions
function Connect() ... end
function Disconnect() ... end
function SendWebSocketMessage(msg) ... end
function SendProflameCommand(control, value) ... end
function RequestAllStatus() ... end

-- Timer Functions
function StartPingTimer() ... end
function StopPingTimer() ... end
function ScheduleReconnect() ... end

-- Status Processing
function ParseStatusMessage(data) ... end
function ProcessStatusUpdate(status, value) ... end

-- Proxy Updates
function UpdateThermostatProxy(mode) ... end
function UpdateThermostatSetpoint() ... end
function UpdateRoomTemperature() ... end
function UpdateFanMode() ... end
function UpdateFlameLevel() ... end

-- Callbacks
function OnDriverInit() ... end
function OnDriverLateInit() ... end
function OnDriverUpdated() ... end
function OnDriverDestroyed() ... end
function OnPropertyChanged(strProperty) ... end
function OnConnectionStatusChanged(idBinding, nPort, strStatus) ... end
function ReceivedFromNetwork(idBinding, nPort, strData) ... end
function ReceivedFromProxy(idBinding, strCommand, tParams) ... end
function HandleThermostatCommand(strCommand, tParams) ... end
```

---

## Appendix B: Version History

| Version | Date | Changes |
|---------|------|---------|
| 2026061901 | 2026-06-19 | **Fix: the timer-required safety policy fought the physical remote, and an implausible room-temperature reading displayed as 684.5°F.** (1) **Timer policy (§6.9).** When the fireplace was turned on by the physical remote (on-mode with `timer_status=0`), the driver force-turned-it-off; the remote re-asserted on, the driver slammed it off again — an on/off war that the on-device log shows repeating every ~1 s for tens of seconds (`Timer safety policy forcing fireplace off: mode=6, timer_status=0`). `EnforceTimerRequiredForOnState` now **arms the configured Default Timer** for an on-state that never had a timer (via `SetTimerValueAndArm`), letting the device keep running and just mirroring its state. The two original force-off cases are preserved: a **genuine count-down expiry** (`gTimerCountExpired`, set only on a `timer_count` `>0→0` transition — distinct from `gTimerExpired`, which is also set on every `timer_status=0` such as a remote turn-on, so keying off it would re-create the war) still turns the fireplace off (auto-off works), and `Default Timer 0` still forces off (documented escape hatch). New `test/test_timer_safety.lua` covers arm-on-remote-turn-on, force-off-on-expiry, and the off-state no-op. (2) **Room temperature.** This firmware (FW 625.04.673) steadily reports raw `room_temperature":"6845"` (684.5°F after the Fx10 decode) alongside `temperature_set":"320"` / `burner_status":"32672"` sentinels when no real sensor value is available. `ApplyDeviceStatus` now drops any room-temperature reading that decodes outside −40…140°F so the bogus value never reaches the property or the thermostat proxy; the last good reading is retained. New `test/test_room_temperature_guard.lua`. No `driver.xml` capability/property/command/proxy change (only `<version>`), so no Director reload required. |
| 2026061604 | 2026-06-16 | **Add "Last Keepalive Response" Composer property (#89).** A read-only STRING (default `Never`) timestamped each time the device replies `PROFLAMEPONG` to the app-level keepalive — so Composer shows round-trip liveness at a glance. This is the property #70 removed as dead UI back when C1 Phase 2 had dropped the keepalive (nothing solicited a pong then); the B4/#86 keepalive makes it live again, now under the clearer name. `ParseStatusMessage` stamps it via `os.date` (pcall-guarded); `test_websocket_integration` Test 4 updated to assert the stamp. **Static surface:** adds one read-only property — Director reload / driver re-add picks it up; existing installs default to `Never` until the first pong. |
| 2026061603 | 2026-06-16 | **Test/verification release — no functional change.** Version bump only, to confirm the self-updater fixed in 2026061602 (#87 shared-secret `FileSetDir` handshake + `C4Z_ROOT` write) now installs end-to-end from the **Install Latest Release** button. With 2026061602 installed, the updater should detect `v2026061603 > 2026061602`, write the new `.c4z` to `C4Z_ROOT`, and Director should reload to `Driver loading - Version 2026061603` (no manual install needed this time). If it still reloads the old version, the size-verify/`FileSetDir`-denial guards added in 2026061602 will surface a real error in `Update Status` instead of a false success. |
| 2026061602 | 2026-06-16 | **Fix: in-driver "Install Latest Release" silently reinstalled the OLD version** (downloaded the new `.c4z`, logged "triggered Composer install", then reloaded the same version — confirmed on-device 2026-06-16). Root cause: `UpdateProjectC4i` installs the `.c4z` from the c4z store **root** (`C4Z_ROOT`) by name, but the #83/#85 workarounds — chasing the OS 3.3.0 "Restricted path specified" error — redirected the *write* to the per-driver `C4Z` subfolder / `GetC4zDir()` root, locations `UpdateProjectC4i` never reads. The correct fix is not a different write path: OS 3.3.0+ exposes a **shared-secret `FileSetDir` handshake** (`C4:FileSetDir("c29tZXNwZWNpYWxrZXk=++11")`, the community-standard unlock string used verbatim by finitelabs/black-ops-drivers/etc.) that re-unlocks root `FileSetDir` access for unsigned community drivers. Added that handshake to `OnDriverLateInit` and reverted the updater write target to `C4Z_ROOT` (matching the upstream template + every working self-updater). `test_github_updater` §18 now asserts the `C4Z_ROOT` write, §19 asserts the late-init handshake. **Bootstrap:** this fix can't install itself via the (still-broken) button — install 2026061602 manually once; subsequent updates then work from the Actions buttons. (Carries the 2026061601 keepalive fix forward.) |
| 2026061601 | 2026-06-16 | **Fix: connection dropped by the device every ~30s** (continuous `WebSocket close frame received from device` → `Connection Lost (4)` → reconnect loop). C1 Phase 2 (#68) replaced the hand-rolled 5s `PROFLAMEPING` text-frame keepalive with the vendored 30s RFC 6455 WS-level ping; on-device the Proflame dongle (FW 625.04.673) closes the socket in lock-step with that ping firing (~30s after each connect) — it enforces an inbound-idle session timeout and does not treat the WS control-frame ping as activity. Fix (B4/#86): disable the WS-level ping (`Connect` sets `ws.ping_interval = 0`; `vendor/.../websocket.lua` now guards `ping_interval > 0` before arming the Ping timer) and restore the app-level `PROFLAMEPING` keepalive on a new **`Keepalive Interval (seconds)`** property (default 15, range 0–25 — capped under the device's ~30s idle timeout; 0 disables). `gMissedKeepalives` is a half-open-link watchdog: any inbound app frame resets it, three silent intervals force a reconnect (deferred to a 1ms one-shot so the firing keepalive timer is never self-cancelled). **Static surface change:** adds the `Keepalive Interval (seconds)` property — Director reload / re-add picks it up; existing installs get the 15s default. |
| 2026061511 | 2026-06-16 | **Fix: install wrote to the wrong (restricted) c4z path.** v2026061509 replaced the dead `C4Z_ROOT` with `C4:GetC4zDir()`, but on-device `GetC4zDir()` returns the c4z **root** (`/opt/control4/var/drivers/c4z/.`) which a sandboxed driver also can't write to ("Restricted path specified: /opt/control4/var/drivers/c4z/."). Per the DriverWorks `FileSetDir` docs the **allowed** aliases are `SANDBOX`/`LOGGING`/`MEDIA`/`C4Z`, where `C4Z` → the per-driver writable folder. Fix: `vendor/github_updater.lua` now uses the literal `"C4Z"` alias, not `GetC4zDir()`'s root. `test_github_updater.lua` §18 asserts `FileSetDir` receives `"C4Z"` and never `C4Z_ROOT` or the c4z-root path. **The final `UpdateProjectC4i` install from the per-driver folder is still unverified on-device** — OS 3.3.0+ may not support in-driver self-install at all (drivers can't write the c4z store root); the graceful-degradation manual-install message remains the fallback. |
| 2026061510 | 2026-06-16 | **Fix: the "Force Reinstall Latest Release (Recovery)" button did nothing** (`Unhandled LUA_ACTION (action=Force Reinstall Latest Release)`). The `LUA_ACTION` handler (added in 2026061505) matched `tParams.ACTION` against the action's `<name>`, per the DriverWorks docs — but **on-device `tParams.ACTION` is actually the action's `<command>` value, not the `<name>`** (the diagnostic `tParams` dump from #78 surfaced this). For Check/Install the name==command so they worked; the Force Reinstall button's `<name>` ("…(Recovery)") ≠ its `<command>` ("Force Reinstall Latest Release"), so it fell through. Fix: the handler now **re-dispatches** `tParams.ACTION` through `ExecuteCommand` (those `<command>` values are exactly the programming-command strings), normalizing the one `<name>`→`<command>` case for firmware that might send the name. No parallel action list to drift. `test_github_updater.lua` §13 now covers the command-value and name-variant Force Reinstall cases. |
| 2026061509 | 2026-06-16 | **Fix: Install Latest Release failed with "Restricted path specified: C4Z_ROOT".** The vendored updater (copied verbatim from `finitelabs/control4-driver-template`) wrote the downloaded `.c4z` via `C4:FileSetDir("C4Z_ROOT")`. Per the DriverWorks API docs, **OS 3.3.0 restricted `FileSetDir` to allowed locations** (`SANDBOX`/`LOGGING`/`MEDIA`/`C4Z` + explicit allowed full paths) and **removed the old `C4Z_ROOT` root access** — so the template's self-updater is broken on 3.3.0+. Fix: `vendor/github_updater.lua` now resolves the target via the sanctioned `C4:GetC4zDir()` (≥2.10.0, returns the real directory where `.c4z` files reside), falling back to the `"C4Z"` alias. Also added graceful degradation: `InstallLatestReleaseNow` now appends manual-install guidance to any failure status (the in-driver auto-INSTALL step may still be limited by 3.3.0+ security; the write/download are fixed). Tests: `test_github_updater.lua` §18 drives the download path and asserts `FileSetDir` receives `GetC4zDir()`'s path, never `C4Z_ROOT`. **On-device validation still recommended for the final install step.** |
| 2026061508 | 2026-06-15 | **Fix #81: vendored direct `log:*` calls double-logged** (`[DEBUG]: …[WARN ]: …`). The #77 print-shadow re-entrancy guard (`_c4_in_logger`) was set only in `_guarded_log` (the driver's `dbg_*` chokepoint), so vendored modules that call `log:warn`/`log:info` directly on the shared object (`vendor/github_updater.lua`) bypassed it and their logger console-mirror got re-routed through `dbg_debug`. Fix (Option A, via `/research` → `/engineer` quad-review): wrap the `log` object's emit methods (`fatal/error/warn/info/debug/trace/ultra/log/print`) to also set the guard, restore-previous-value for correct nesting, placed after the load-time `log` setup. `log` is a fresh `Log:new()` per chunk load so it's reload-safe by construction (marker guards intra-load re-wrap); `_guarded_log`/`dbg_*` unchanged (retain nil/pcall safety). `test_print_redirect.lua` §8 asserts a direct `log:warn` logs exactly once and a subsequent bare vendor `print()` still routes to `dbg_debug`. Plan + reviews: `docs/research/81-log-guard/`. |
| 2026061507 | 2026-06-15 | **Bug fix: Install Latest Release failed with "unknown error".** Two causes: (1) GitHub release-asset URLs (`browser_download_url`) 302-redirect to storage (`objects.githubusercontent.com`), but `C4:urlGet` does not follow redirects, so the asset download failed with "status 302". `vendor/http.lua` now follows 3xx redirects (case-insensitive `Location`, bounded by a 5-hop budget). (2) That failure surfaced as "unknown error" because `deferred.all` rejects with a NUMERIC-indexed table of per-item errors, which the install/check error handlers didn't recognize. New `DescribeUpdaterError` flattens every rejection shape (string / `{error=...}` / numeric-indexed table) so the real reason reaches the Update Status property and log. Tests: `test_github_updater.lua` §16 (redirect follow incl. lowercase header + no-Location reject) and §17 (`DescribeUpdaterError` shapes). |
| 2026061506 | 2026-06-15 | **Bug fix: logging wedged after a driver reload** (symptom: debug logging stops and toggling Debug Level won't bring it back). The #69 print shadow captured the real builtin with `_c4_print = print`, but `_c4_print`/`print` are file-level globals that survive Control4's hot reload (driver update / controller restart re-runs the whole chunk). On the 2nd load `print` is already the shadow, so `_c4_print` captured the shadow itself and the shadow's pass-through (`return _c4_print(...)`) tail-called into itself forever — an infinite loop (no stack growth, so a true hang, not a catchable error) that wedged all logging until a power cycle, and which no Debug Level toggle could clear. Fixed with the idempotent `_c4_print = _c4_print or print` so the real builtin is captured once and never overwritten by the shadow across reloads. New `test/test_print_redirect.lua` section 7 asserts the reload-safety invariant. |
| 2026061505 | 2026-06-15 | **Bug fix: the Actions-tab update buttons did nothing** (logged `Unhandled ExecuteCommand: LUA_ACTION`). The `<actions>` added in 2026061402 do fire, but Control4 dispatches an action as `ExecuteCommand("LUA_ACTION", tParams)` with the action's `<name>` in `tParams.ACTION` — NOT as the command name (an incorrect assumption in the original actions PR). Added a `LUA_ACTION` branch to `ExecuteCommand` that dispatches on `tParams.ACTION` (`Check for Update` / `Install Latest Release` / `Force Reinstall Latest Release (Recovery)`) to the existing handlers and returns true; unrecognized actions log a `tParams` dump and return false. driver.xml unchanged except `<version>`. |
| 2026061504 | 2026-06-15 | Logging hygiene (issue #69). The vendored `drivers-common-public/module/websocket.lua` calls the bare global `print(...)` in several spots (`:Start()`, the keepalive PONG-timeout path, `ConnectionChanged`, etc.). Those bypass the driver's Debug Mode / Debug Level Composer gating and the module's own `DEBUG_WEBSOCKET` flag, producing log noise during reconnect loops. Rather than edit the vendored file (kept byte-identical to upstream for re-sync), `src/driver.lua` now installs a global `print` shadow that forwards its varargs (tostring-ed, nil-safe, space-joined) through `dbg_debug`, so vendored prints are gated by the configured log level. The re-entrancy guard (`_c4_in_logger`) is set in the `_guarded_log` chokepoint every `dbg_*` call funnels through, so the logger's own console-mirror `print` (Debug Mode = On) passes straight through to the real `print` instead of being re-routed (Codex review of #77). The driver's own intentional `print(...)` calls (load-time "Driver loading"/"Updated Driver Version property" lines, OnDriverInit/OnDriverLateInit error prints) were converted to `dbg_info`/`dbg_err`; the two load-time lines buffer and flush unconditionally once the logger is up. No `driver.xml` capability/property/command/proxy/connection change (only `<version>`), so no Director reload required. |
| 2026061503 | 2026-06-15 | Stopped emitting `HVAC_MODES`/`HVAC_STATES` in the `DYNAMIC_CAPABILITIES_CHANGED` notification built by `BuildThermostatDynamicCapabilities` (issue #64). Those values are constant for this heat-only device, are already declared statically in `driver.xml` (`<hvac_modes>`/`<hvac_states>`), and the allowed-mode subset is emitted separately and correctly via `ALLOWED_HVAC_MODES_CHANGED` in `SendThermostatAllowedModes` — so the two keys were redundant in the dynamic-capabilities payload. The static `<hvac_modes>`/`<hvac_states>` declarations and `<can_change_hvac_modes>` are unchanged (Navigator needs them at install time); only the runtime notification table was trimmed. No command/property surface change. |
| 2026061502 | 2026-06-15 | Removed the dead read-only **Last Ping Response** Composer property (#70). After C1 Phase 2 dropped the hand-rolled `PROFLAMEPING` keepalive nothing solicited a `PROFLAMEPONG`, and the device does not emit `PROFLAMEPONG` spontaneously (the 2026-06-02 probe saw 0 frames in a 10s silent window), so the property never updated — accept-and-retire. Removed the `<property>Last Ping Response</property>` block from `driver.xml` and the `C4:UpdateProperty("Last Ping Response", …)` call in `ParseStatusMessage`. The `PROFLAMEPONG`-echo branch is kept but now only `dbg_debug`-logs and `return`s, so a stray echo is still swallowed rather than logged as an unknown frame. Static driver.xml property removal — existing installs need a Director reload / driver re-add to drop the property. |
| 2026061402 | 2026-06-14 | Added an `<actions>` block to `driver.xml` so the three GitHub-updater commands (`Check for Update`, `Install Latest Release`, `Force Reinstall Latest Release`) render as **clickable buttons in the device's Actions tab** in Composer Pro. Previously they existed only as `<commands>`, which surface in Programming (device-specific commands) but never as buttons — so there was no one-click way to update the driver. No Lua change: each action's `<command>` is an existing `ExecuteCommand` branch. Existing installs need a Director reload / driver re-add to show the new buttons. |
| 2026061401 | 2026-06-14 | Update-detection UX. Updates are GitHub-release based (the driver's own updater), not Control4's native menu — but no release had been cut since `v2026051731` so the existing `Install Latest Release` command correctly found nothing newer. Cut release `v2026061301`, then added: a **Check for Update** command (report-only — queries the latest release and reports newer/up-to-date in `Update Status` without installing); a **Force Reinstall Latest Release** command (`forceUpdate=true`, reinstalls even when versions match, for recovery); a periodic report-only auto-check (`StartUpdateCheckTimer`/`StopUpdateCheckTimer` + `gUpdateCheckTimerId`, new `Update Check Interval (hours)` property, default 24, 0 disables) plus a one-shot check ~10 s after load; and flipped the misleading `<auto_update>true</auto_update>` to `false` (the native Control4 update menu cannot see a GitHub-distributed driver). `InstallLatestReleaseNow` gained a `force` parameter. New `Update Check Interval (hours)` is cancelled in reload cleanup and `OnDriverDestroyed`; the update timer is independent of the device connection so `Disconnect` does not stop it. |
| 2026061301 | 2026-06-13 | Connect-attempt watchdog (issue #71). After the C1 Phase 2 cutover, the gap between `ws:Start()` and the first vendored callback had no liveness timer: the vendored ping/pong watchdog only arms after the binding goes `ONLINE`, and the one-shot reconnect timer refuses to fire while `gConnecting` is true. So a `Connect()` against an unreachable device whose `C4:NetConnect` never produced an `OFFLINE` `ConnectionChanged` left `gConnecting` stuck true forever — UI pinned at "Connecting…" with no retry. Added `StartConnectTimeoutTimer`/`StopConnectTimeoutTimer`/`OnConnectTimeout` plus a `gConnectTimeoutTimerId` global: armed in `Connect()` before `Start()`, cancelled in `OnWebSocketEstablished` (success) / `OnWebSocketOffline` (clean failure) / `Disconnect`; on expiry it forces `TeardownWebSocket(false)`, clears `gConnecting`, sets Connection Status `Disconnected`, and `ScheduleReconnect()`. New `Connect Timeout (seconds)` `RANGED_INTEGER` Composer property (min 5, max 120, default 30) mirroring `Reconnect Delay (seconds)`. Not disablable from the UI — a 0-disable would reopen the exact stuck-in-Connecting bug this fixes (Codex review of #72). Reload cleanup and `ResetDriverState` cancel the new timer. |
| 2026060302 | 2026-06-03 | Tier C1 Phase 2: cutover to the vendored Snap One WebSocket. Deleted the 9 hand-rolled WS helpers (`GenerateWebSocketKey`, `BuildWebSocketHandshake`, `ParseHttpHeaders`, `ExpectedWebSocketAccept`, `ValidateHandshakeResponse`, `CreateWebSocketFrame`, `ParseWebSocketFrame`, `SendWebSocketMessage`, `SendPing`, `SendPong`) plus the Tier-A PROFLAMEPING infrastructure (`StartPingTimer`, `StopPingTimer`, `OnPingTimer`, `gPingTimerId`, the `Ping Interval (seconds)` Composer property). Removed the static `<connection id="6001">` TCP binding from `driver.xml` and the `NETWORK_BINDING_ID = 6001` Lua constant — the vendored `websocket.lua` now allocates the network binding dynamically (scanning 6100-6199 via `C4:GetBindingAddress`). `Connect()` builds a `ws://<ip>:<port>/` URL and calls `WebSocket:new(url)`; four new callbacks (`OnWebSocketEstablished`, `OnWebSocketMessage`, `OnWebSocketOffline`, `OnWebSocketClosedByRemote`) take over the lifecycle. Our top-level `OnConnectionStatusChanged` and `ReceivedFromNetwork` now delegate to `OCS[idBinding]` / `RFN[idBinding]` when the binding matches `gWebSocket.netBinding` so the vendored handshake and frame parsers actually run. WS-level ping/pong (opcode 0x09/0x0A, 30s interval, 10s pong response timeout) supersedes the 5s PROFLAMEPING app-protocol keepalive — the 2026-06-03 probe confirmed the device replies to RFC 6455 control frames (`tools/probes/evidence/characterize-20260603T024355Z.json` `ws_ping.ws_pong_received=true`). New `test/test_websocket_integration.lua` replays the captured 5-frame probe transcript through `OnWebSocketMessage` to assert all 79 status keys dispatch correctly. **Structural surface change** — `driver.xml` connection binding removed. |
| 2026060301 | 2026-06-03 | Tier C1 Phase 1: vendored Snap One `drivers-common-public` `{global/lib, global/timer, global/handlers, module/metrics, module/websocket}` into `vendor/drivers-common-public/` preserving upstream subdirectory layout. Files are byte-identical to upstream master `64663d5deacaec25327418d207dc4b0e5e0f27ab`. Bundle script extended with `bundle_one_noreturn` for vendor files that register their API via top-level globals (no trailing `return`); a small `require` shim in `src/driver.lua` maps the upstream `require('drivers-common-public.…')` calls to the bundled globals so the side-effect top-level executable code in each vendor file works under the bundled single-file deployment. Phase 1 is INERT: the 9 hand-rolled WebSocket helpers in `src/driver.lua` (lines 928-1148) and the static `<connection><binding id="6001">` in `driver.xml` are unchanged; nothing in this driver calls `WebSocket:new()` yet. Phase 2 will replace the hand-rolled helpers and drop the static binding so `websocket.lua` can allocate it dynamically via `C4:CreateNetworkConnection`. |
| 2026060204 | 2026-06-03 | Tier B3: periodic PROFLAMECONNECTION refresh every N minutes (default 5, 0 disables) to catch local-panel state changes the device does not push spontaneously (tools/probes/FINDINGS.md §8). New Composer property "Status Refresh Interval (minutes)"; timer started after handshake-complete and stopped in Disconnect alongside the ping timer. |
| 2026060203 | 2026-06-03 | Tier A3: read device `temperature_unit` and flip Composer temperature suffix to F or C; added read-only "Temperature Unit" property; added SanitizeDeviceString defense-in-depth wrapper applied to firmware + temperature_unit values and the unknown-key WARN log (#58); InitializePropertiesFromState now re-stamps Firmware Versions and Temperature Unit after state resets (#57) |
| 2026060202 | 2026-06-03 | Tier B1: added read-only "Firmware Versions" Composer property composed from the 5 fw_* sub-fields the device pushes |
| 2026060201 | 2026-06-03 | Tier A2: HANDLED/KNOWN_IGNORED status-key allowlists silence ~67 debug-log lines per reconnect; unknown firmware keys now surface at WARN |
| 2026060108 | 2026-06-03 | Tier A1: dropped Strict WebSocket Handshake property + lenient 101 fallback. **Default-Off installs become strict-only** — this is a deliberate compatibility tradeoff based on FW 625.04.673 probe evidence (tools/probes/FINDINGS.md §1). Older or non-standard firmware variants that returned a non-RFC-compliant 101 would have been silently accepted before this version and will now fail to connect. |
| 2026060107 | 2026-06-01 | Logging discipline: classified 101 dbg_err calls by intent into dbg_err/warn/info/debug; added dbg_trace helper |
| 2026060106 | 2026-06-01 | Review-cleanup: restored http_client watchdog (T2d+ regression), removed dead dbg() function, clarified empty-asset install message, Update Status default Idle |
| 2026060105 | 2026-06-01 | Replaced slim updater with full template github-updater (auto-install via Composer SOAP); manual-trigger only via "Install Latest Release" command |
| 2026060104 | 2026-06-01 | Added log-only GitHub Releases update notifier (rate-limited to 24h, no auto-install) |
| 2026060103 | 2026-06-01 | Added test/ scaffolding + CI test job; fixed DecodeTemperature half-degree precision loss |
| 2026060101 | 2026-06-01 | Vendored slim persist wrapper; log driver-version transitions on driver load |
| 2026053106 | 2026-05-31 | Vendored lib/logging.lua; dbg/dbg_err/dbg_all retained as legacy delegates |
| 2026053105 | 2026-05-31 | Extracted vendored JSON.lua to vendor/JSON.lua; bundle.sh now generates driver.lua from src/ + vendor/ |
| 2026053104 | 2026-05-31 | Synced README/spec samples with the vendored JSON.lua wrappers and documented the alphabetical-sort wire-format contract |
| 2026053103 | 2026-05-31 | Updated spec appendix sample code to reflect C4:Hash / C4:Base64Encode |
| 2026053102 | 2026-05-31 | Vendored Jeffrey Friedl's JSON.lua and routed all JSON encode/decode through it |
| 2026053101 | 2026-05-31 | Replaced hand-rolled SHA-1 and Base64 with C4:Hash and C4:Base64Encode |
| 2026051731 | 2026-05-17 | Broadened static XML guardrails and documented runtime capability snapshot behavior |
| 2026051730 | 2026-05-17 | Centralized runtime ThermostatV2 capability refreshes and added static XML restart-risk guardrails |
| 2026051729 | 2026-05-17 | Added deprecated SET_PRESET compatibility path and documented runtime capability probe behavior |
| 2026051728 | 2026-05-17 | Restored custom Low/Medium/High Hold actions after documented Permanent display test |
| 2026051727 | 2026-05-17 | Tested documented Hold display behavior while keeping Hold tap actions for flame height |
| 2026051725 | 2026-05-17 | Disabled thermostat Presets menu and restored Hold menu as flame height control |
| 2026051721 | 2026-05-17 | Refresh custom flame hold-mode capability list before sending current hold-mode value |
| 2026051720 | 2026-05-17 | Initialize flame preset hold-mode display so the app control is labeled before status echoes |
| 2026051719 | 2026-05-17 | Documented firmware scope for the Legacy Only default |
| 2026051718 | 2026-05-17 | Changed default non-Turn-Off command format to Legacy Only based on real-device single-format verification |
| 2026051717 | 2026-05-17 | Centralized outbound command-format planning and documented manual format verification |
| 2026051716 | 2026-05-17 | Added timer-required safety policy that forces off confirmed on states without an active timer |
| 2026051715 | 2026-05-17 | Clarified Set Flame Level Manual-mode side effect |
| 2026051714 | 2026-05-17 | Clarified Default Timer scope without renaming the property |
| 2026051713 | 2026-05-17 | Clarified command-format property scope and runtime order testing guidance |
| 2026051712 | 2026-05-17 | Added configurable command-format compatibility mode for non-Turn-Off commands |
| 2026051711 | 2026-05-17 | Hotfix JsonEscape runtime pattern, restored legacy turn-off command behavior, and documented Composer command smoke testing |
| 2026051701 | 2026-05-17 | Updated documentation to match implemented properties, commands, events, and protocol helpers |
| 2026051628 | 2026-05-16 | Aligned thermostat capabilities and documentation with implemented behavior |
| 2025013124 | 2026-01-31 | Updated mode values (Smart=6, Eco=7), build timestamp for cache busting |
| v64 | 2025-01-24 | Fixed throttle race condition in timer updates |
| v63 | 2025-01-24 | Stop updating timer_set from device responses |
| v62 | 2025-01-24 | Added timer update suppression flag |
| v61 | 2025-01-24 | Removed non-functional actions, kept OnDriverUpdated |
| v57 | 2025-01-23 | Auto-timer on turn-on, timer-to-0 turns off |
| v54 | 2025-01-23 | Fixed timer countdown slider sync |
| v48 | 2025-01-23 | Timer in milliseconds discovery |
| v42 | 2025-01-23 | Fixed XML name tag issues |
| v36 | 2025-01-23 | Initial timer slider implementation |

---

*End of Specification Document*
