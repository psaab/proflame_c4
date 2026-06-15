# Proflame WiFi Control4 Driver Specification

## Document Version
Version 1.0 - December 17, 2025

---

## Driver Updates

This driver is **distributed via GitHub releases** (`psaab/proflame_c4`), not through Control4's online driver database. As a result, Control4's built-in **"Check For Driver Updates" / Update Manager menu will not find updates for it** — that menu only queries Control4's database. `driver.xml` sets `<auto_update>false</auto_update>` to avoid implying otherwise.

Updates are handled by the driver's own GitHub updater, exposed as **clickable buttons in the device's Actions tab** in Composer Pro (select the Proflame device → **Actions**):

| Command | Effect |
|---------|--------|
| **Check for Update** | Report-only — queries the latest GitHub release and reports newer/up-to-date in the `Update Status` property. No download/install. |
| **Install Latest Release** | Downloads `proflame_wifi_connect.c4z` from the latest release (when its tag is newer) and installs it via Composer's local SOAP endpoint. |
| **Force Reinstall Latest Release (Recovery)** | Re-installs the latest release even when versions match (recovery/repair). May reinstall an older build if the latest release is behind the running one — the button is labeled "(Recovery)" to flag this. |

A report-only check also runs automatically ~10 s after the driver loads and then every **`Update Check Interval`** hours (default 24; set `0` to disable). **Installs are always manual.**

> **Maintainer note:** for the updater to detect a new version, you must publish a GitHub release whose tag is newer than the running `DRIVER_VERSION` (e.g. `v2026061401`) with an asset named exactly **`proflame_wifi_connect.c4z`**. If releases aren't cut after merging, update detection silently goes stale even though the code on `main` has advanced.

---

## Table of Contents
1. [Proflame WiFi Protocol](#proflame-wifi-protocol)
2. [Control4 Driver Architecture](#control4-driver-architecture)
3. [Control4 Thermostat Extras Menu](#control4-thermostat-extras-menu)
4. [Control4 Proxy Communication](#control4-proxy-communication)
5. [Complete XML Examples](#complete-xml-examples)

---

## Proflame WiFi Protocol

### Connection Details
- **Transport**: WebSocket over TCP
- **Default Port**: 88
- **Host**: Device IP address (e.g., 172.16.1.81)

### WebSocket Handshake
The Proflame device uses a standard WebSocket handshake:

```
GET / HTTP/1.1
Host: {ip}:{port}
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: {base64-encoded-random-key}
Sec-WebSocket-Version: 13
```

The device responds with:
```
HTTP/1.1 101 Switching Protocols
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Accept: {computed-accept-key}
```

The `Sec-WebSocket-Accept` is computed as:
```
Base64(SHA1(Sec-WebSocket-Key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
```

The driver strictly validates the upgrade response per RFC 6455 §4.2.2 — status line, `Upgrade: websocket`, `Connection: Upgrade`, and `Sec-WebSocket-Accept` matching the computed digest. Direct probe against `FW: 625.04.673` on 2026-06-02 confirmed the Proflame firmware returns a fully compliant 101 (`tools/probes/FINDINGS.md` §1), so the prior `Strict WebSocket Handshake = Off` lenient-fallback property was removed.

**Compatibility note:** the removal in version `2026060108` flipped default-Off installs (the majority) from lenient-101 fallback to strict-only validation. This is a deliberate tradeoff backed by the probe evidence on `FW: 625.04.673` — older or non-standard firmware variants that returned a non-compliant 101 would have been silently accepted before that version and will now refuse to connect. If a deployment regresses against an unverified firmware revision, re-run `tools/probes/handshake_and_ping.py` to confirm strict compliance before deploying the driver to that controller.

### Keep-Alive Protocol
- **WebSocket Ping/Pong**: RFC 6455 control frames (opcode `0x09`/`0x0A`), handled by the vendored Snap One WebSocket module (30s interval). The hand-rolled app-level `PROFLAMEPING`/`PROFLAMEPONG` keepalive was removed in C1 Phase 2.
- **Connection Request**: `PROFLAMECONNECTION` (triggers full status dump)

> Note: the device does not spontaneously emit `PROFLAMEPONG` (the 2026-06-02 probe saw 0 frames in a 10s silent window), so the old read-only "Last Ping Response" Composer property was dead UI and was removed in `2026061502` (#70). Any stray `PROFLAMEPONG` echo is still swallowed so it is not logged as an unknown frame.

### Command Format
**CRITICAL**: JSON commands must have NO SPACES after colons or commas. The device silently ignores malformed commands.

#### Correct Format:
```json
{"command":"set_control","name":"flame_control","value":"6"}
```

#### Incorrect Format (will be ignored):
```json
{"command": "set_control", "name": "flame_control", "value": "6"}
```

### Status Updates
The device sends status updates as JSON with indexed status/value pairs:

```json
{"status0":"flame_control","value0":"6","status1":"fan_control","value1":"0","status2":"main_mode","value2":"5"}
```

### Temperature Encoding
- **Format**: Fahrenheit × 10
- **Example**: 70°F = 700, 68.5°F = 685
- **Decode**: `value / 10` = temperature in Fahrenheit
- **Encode**: `temperature * 10` = encoded value

### Operating Modes (main_mode)
| Value | Mode | Description |
|-------|------|-------------|
| 0 | Off | Fireplace completely off |
| 1 | Standby | Pilot on, burner off |
| 5 | Manual | Manual flame control |
| 6 | Smart | Thermostat mode |
| 7 | Eco | Energy-saving thermostat mode |

### Control Parameters
| Parameter | Range | Description |
|-----------|-------|-------------|
| flame_control | 0-6 | Flame height (0=off, 6=max) |
| fan_control | 0-6 | Fan speed (0=off, 6=max) |
| lamp_control | 0-6 | Downlight brightness |
| temperature_set | 600-900 | Target temp (encoded) |
| pilot_control | 0-1 | Pilot light on/off |
| aux_control | 0-1 | Auxiliary output |
| split_control | 0-1 | Split flame mode |

### Example Commands

**Turn on in Manual mode with flame level 6:**
```json
{"command":"set_control","name":"main_mode","value":"5"}
{"command":"set_control","name":"flame_control","value":"6"}
```

**Set thermostat to 72°F:**
```json
{"command":"set_control","name":"temperature_set","value":"720"}
```

**Set fan to medium:**
```json
{"command":"set_control","name":"fan_control","value":"3"}
```

---

## Control4 Driver Architecture

### Driver XML Structure (driver.xml)

```xml
<?xml version="1.0"?>
<devicedata>
  <copyright>Copyright 2025</copyright>
  <name>Proflame WiFi Fireplace</name>
  <control>lua_gen</control>
  <controlmethod>IP</controlmethod>
  <version>2026051731</version>
  
  <proxies>
    <proxy proxybindingid="5001" name="Proflame Fireplace">thermostatV2</proxy>
  </proxies>
  
  <capabilities>
    <has_extras>true</has_extras>
    <can_heat>True</can_heat>
    <can_cool>False</can_cool>
    <has_single_setpoint>True</has_single_setpoint>
    <has_fan_mode>True</has_fan_mode>
    <!-- ... additional capabilities ... -->
  </capabilities>
  
  <connections>
    <connection>
      <id>6001</id>
      <connectionname>Network</connectionname>
      <type>4</type>
      <classes>
        <class>
          <classname>TCP</classname>
          <ports>
            <port><number>88</number></port>
          </ports>
        </class>
      </classes>
    </connection>
    <connection>
      <id>5001</id>
      <connectionname>Thermostat</connectionname>
      <type>2</type>
      <classes>
        <class>
          <classname>THERMOSTAT</classname>
        </class>
      </classes>
    </connection>
  </connections>
</devicedata>
```

### Key Capability: has_extras
The `<has_extras>true</has_extras>` capability MUST be set to enable the Extras tab in the Control4 UI. Note: Use lowercase `true`, not `True`.

### Static XML vs Runtime UI Capabilities
Treat `driver.xml` as the stable install-time contract. Static proxy, connection, property, command, and capability changes can cause heavier Control4 reload behavior than Lua-only/runtime UI refreshes. Prefer runtime proxy notifications for Navigator experiments whenever the ThermostatV2 SDK provides an equivalent.

| UI surface | Preferred update path | Notes |
|------------|-----------------------|-------|
| Hold modes | `DYNAMIC_CAPABILITIES_CHANGED` + `HOLD_MODE_CHANGED` | Custom labels may still render blank because the SDK documents standard thermostat hold labels. |
| Fan modes | `DYNAMIC_CAPABILITIES_CHANGED` + `ALLOWED_FAN_MODES_CHANGED` | Keep static XML broad and refresh runtime state on init/connect. |
| HVAC modes | `DYNAMIC_CAPABILITIES_CHANGED` + `ALLOWED_HVAC_MODES_CHANGED` | Mode-only commands should not require XML capability churn. |
| Extras controls | `DataToUI` / Extras setup refresh | Keep `has_extras=true` static, then publish control layout at runtime. |
| Presets | Runtime-disabled unless proven otherwise | `can_preset=false` is the stable XML baseline; avoid reintroducing preset XML for experiments. |

PRs that edit static `driver.xml` capability/proxy/connection/property metadata must note whether Director restarted/reloaded and why a runtime capability refresh was not sufficient.

The runtime refresh intentionally sends a full capability snapshot, not only the field that triggered the refresh. This keeps Navigator state internally consistent and avoids piecemeal XML edits while issue #39 collects the real Controller/Navigator restart matrix.

### Restart Matrix Package Builder
Use `scripts/build_restart_matrix_variants.py` to generate isolated `.c4z` variants for issue #39/#41 testing without hand-editing the working tree:

```sh
scripts/build_restart_matrix_variants.py --start-version 2026051801
```

Choose a `--start-version` greater than both the current checked-in driver version and any restart-matrix package version previously installed on a controller. Reusing a version can cause Composer to reject the update or contaminate results by installing different package contents under the same version. The script refuses to overwrite versions already present in the output directory.

The script builds packages under `dist/restart-matrix/` and writes `restart-matrix-results.csv` for recording:

- Controller version
- generated driver version
- whether Director restarted/reloaded
- whether only the driver reloaded
- whether Navigator still exposed the expected UI
- notes/log references

Do not merge generated restart-matrix packages. They are throwaway runtime-verification artifacts used to decide whether specific static XML capabilities can safely move to runtime-only publishing.

Do not run `scripts/validate.sh` against generated restart-matrix packages. They intentionally differ from the working tree by version, build timestamp, and XML capability content, so the normal package-staleness check will reject them.

### Default Timer Scope
`Default Timer (minutes)` is used only when `Turn On` explicitly starts the fireplace. Mode-only commands such as `Set Mode Manual`, `Set Mode Smart`, and `Set Mode Eco` do not apply it, and `Set Timer` uses the requested `Minutes` value instead. Because the driver requires an active timer for on states, setting Default Timer to `0` means Turn On will be forced back off after confirmed status shows no running timer.

### Timer-Required Safety Policy
The driver treats Manual, Smart, and Eco as on states that require an active auto-off timer. If confirmed status shows the fireplace on while `timer_status` is not running, or if `timer_status` remains unknown after status sync, the driver logs the safety action and sends Turn Off. Timer setup and Turn Off transitions are exempt while timer updates are intentionally suppressed. This is a behavior change from earlier versions: Cancel Timer while on and Turn On with Default Timer set to `0` both satisfy the missing-timer condition and turn the fireplace off.

### Flame Level Mode Side Effect
`Set Flame Level` is a manual flame command. If the fireplace is in Smart, Eco, Off, or Standby, the driver switches to Manual mode before sending `flame_control`. Use mode commands when thermostat operation should be preserved.

### Presets Disabled
Thermostat Presets are disabled because Navigator did not expose them reliably for flame/timer controls. Existing Composer programming that sends `SET_PRESET` with `Manual`, `Smart`, or `Eco` still routes to the matching mode command and logs a deprecation message; new programming should use explicit mode commands or the Extras `Mode` list.

### Proxy Binding IDs
- **5001**: Thermostat proxy (thermostatV2)
- **6001**: Network connection (TCP)
- **7000**: Room selection (for temperature binding)

---

## Control4 Thermostat Extras Menu

### Overview
The Extras menu provides custom controls beyond standard thermostat functionality. This is the most complex and underdocumented part of Control4 driver development.

### CRITICAL: XML Format Discovery
The official Control4 documentation shows one format, but **the actual working format is completely different**. The working format was discovered by analyzing Composer Pro logs from working Ecobee thermostat drivers.

### Extras XML Structure (WORKING FORMAT)

```xml
<extras_setup>
  <extra>
    <section label="Section Name">
      <object type="list" id="unique_id" label="Display Label" command="COMMAND_NAME">
        <list maxselections="1" minselections="1">
          <item text="Display Text" value="value1"/>
          <item text="Display Text 2" value="value2"/>
        </list>
      </object>
      <object type="slider" id="slider_id" label="Slider Label" command="SLIDER_COMMAND" min="0" max="100" value="50"/>
      <object type="text" id="text_id" label="Text Label" value="Display Value"/>
      <object type="button" id="btn_id" label="Button Label" buttontext="Click Me" command="BUTTON_COMMAND"/>
    </section>
  </extra>
</extras_setup>
```

### WRONG FORMAT (From Documentation - Does NOT Work)
```xml
<!-- THIS FORMAT DOES NOT WORK -->
<extras_setup>
  <extras>
    <extra>
      <type>LIST</type>
      <id>my_list</id>
      <description>My List</description>
      <items>
        <item><id>1</id><text>Option 1</text></item>
      </items>
    </extra>
  </extras>
</extras_setup>
```

### Object Types

#### 1. List (Dropdown)
```xml
<object type="list" id="unique_id" label="Display Label" command="COMMAND_NAME">
  <list maxselections="1" minselections="1">
    <item text="Option 1" value="opt1"/>
    <item text="Option 2" value="opt2"/>
    <item text="Option 3" value="opt3"/>
  </list>
</object>
```

**Important**: The FIRST item in the list appears as the selected value. To show the current selection, reorder the items so the current value is first.

#### 2. Slider
```xml
<object type="slider" id="slider_id" label="Slider Label" command="CMD" min="0" max="6" value="3"/>
```

Attributes:
- `min`: Minimum value
- `max`: Maximum value  
- `value`: Current value (CRITICAL for initialization)

#### 3. Text (Read-only display)
```xml
<object type="text" id="text_id" label="Label" value="Display Value"/>
```

#### 4. Button
```xml
<object type="button" id="btn_id" label="Label" buttontext="Button Text" command="CMD" hidden="false"/>
```

### Sending Extras to UI

#### Method 1: SendDataToUI (PRIMARY - Required)
```lua
C4:SendDataToUI(xml)
```
This sends the XML directly to the UI and is the method that actually works.

#### Method 2: SendToProxy (Secondary)
```lua
C4:SendToProxy(PROXY_ID, "EXTRAS_SETUP_CHANGED", {XML = xml})
```
Send as backup, but `SendDataToUI` is the primary method.

### Handling Extras Commands

When a user interacts with an extras control, the driver receives commands via `ReceivedFromProxy`:

```lua
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "SELECT_MODE" then
        local value = tParams["VALUE"] or tParams["value"]
        -- Handle mode selection only; do not change flame or timer
    elseif strCommand == "SET_FLAME_LEVEL" then
        local value = tonumber(tParams["VALUE"] or tParams["value"])
        -- Handle slider change; this switches to Manual mode if needed
    end
end
```

### Updating Extras Values

**CRITICAL**: Values are embedded IN the extras_setup XML, not sent separately. To update displayed values:

1. Regenerate the `extras_setup` XML with new values
2. Call `C4:SendDataToUI(xml)` again

```lua
function GetExtrasXML()
    local flame = tonumber(gState.flame_control) or 0
    local fan = tonumber(gState.fan_control) or 0
    
    local xml = 
    '<extras_setup>' ..
      '<extra>' ..
        '<section label="Controls">' ..
          '<object type="slider" id="pf_flame" label="Flame" command="SET_FLAME_LEVEL" min="1" max="6" value="' .. flame .. '"/>' ..
          '<object type="slider" id="pf_fan" label="Fan" command="SET_FAN_LEVEL" min="0" max="6" value="' .. fan .. '"/>' ..
        '</section>' ..
      '</extra>' ..
    '</extras_setup>'
    return xml
end

function UpdateExtrasState()
    C4:SendDataToUI(GetExtrasXML())
end
```

### Throttling Updates

During initialization, many status updates arrive rapidly. Throttle extras updates to avoid UI flickering:

```lua
gExtrasThrottle = false

function UpdateExtrasState()
    if gExtrasThrottle then return end
    gExtrasThrottle = true
    C4:SetTimer(500, function() 
        gExtrasThrottle = false 
        C4:SendDataToUI(GetExtrasXML())
    end, false)
end
```

---

## Control4 Proxy Communication

### Thermostat Proxy Notifications

#### Temperature Updates
```lua
-- Send temperature in Celsius
C4:SendToProxy(PROXY_ID, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})
```

#### Setpoint Updates
```lua
C4:SendToProxy(PROXY_ID, "HEAT_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
C4:SendToProxy(PROXY_ID, "SINGLE_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
```

#### HVAC Mode Updates
```lua
C4:SendToProxy(PROXY_ID, "HVAC_MODE_CHANGED", {MODE = "Heat"})  -- "Off", "Heat", "Cool", "Auto"
C4:SendToProxy(PROXY_ID, "HVAC_STATE_CHANGED", {STATE = "Heat"}) -- Current state
```

#### Fan Mode Updates
```lua
C4:SendToProxy(PROXY_ID, "FAN_MODE_CHANGED", {MODE = "Low"})  -- "Off", "Low", "Medium", "High"
```

#### Allowed Modes
```lua
C4:SendToProxy(PROXY_ID, "ALLOWED_HVAC_MODES_CHANGED", {MODES = "Off,Heat"})
C4:SendToProxy(PROXY_ID, "ALLOWED_FAN_MODES_CHANGED", {MODES = "Off,Low,Medium,High"})
```

#### Preset Mode Updates
```lua
C4:SendToProxy(PROXY_ID, "HOLD_MODE_CHANGED", {MODE = "Low Flame"})
```

### Handling Proxy Commands

```lua
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "GET_EXTRAS_SETUP" then
        return GetExtrasXML()  -- Return XML directly
    end
    
    if strCommand == "SET_MODE_HVAC" then
        local mode = tParams["MODE"]
        -- Handle HVAC mode change
    elseif strCommand == "SET_SETPOINT_HEAT" then
        local tempC = tParams["CELSIUS"]
        local tempF = tParams["FAHRENHEIT"]
        -- Handle setpoint change
    elseif strCommand == "SET_MODE_FAN" then
        local mode = tParams["MODE"]
        -- Handle fan mode change
    end
end
```

---

## Complete XML Examples

### Full Extras Setup Example

```xml
<extras_setup>
  <extra>
    <section label="Operating Mode">
      <object type="list" id="pf_mode" label="Mode" command="SELECT_MODE">
        <list maxselections="1" minselections="1">
          <item text="Smart Thermostat" value="smart"/>
          <item text="Manual" value="manual"/>
          <item text="Eco" value="eco"/>
        </list>
      </object>
    </section>
    <section label="Fireplace Controls">
      <object type="slider" id="pf_flame" label="Flame Level" command="SET_FLAME_LEVEL" min="1" max="6" value="6"/>
      <object type="slider" id="pf_fan" label="Fan Speed" command="SET_FAN_LEVEL" min="0" max="6" value="0"/>
      <object type="slider" id="pf_light" label="Downlight" command="SET_LIGHT_LEVEL" min="0" max="6" value="0"/>
    </section>
  </extra>
</extras_setup>
```

### Ecobee-Style Example (From Working Driver)

```xml
<extras_setup>
  <extra>
    <section label="Comfort Setting Select">
      <object type="list" id="comfortSwitch" label="Comfort Setting" command="EXTRAS_CHANGE_COMFORT">
        <list maxselections="1" minselections="1">
          <item text="Home" value="home"/>
          <item text="Away" value="away"/>
          <item text="Sleep" value="sleep"/>
        </list>
      </object>
    </section>
    <section label="Ecobee Setup">
      <object type="text" id="ECOBEE_ACCOUNT" label="Ecobee Account" value="Linked"/>
      <object type="button" id="GetPINCODE" label="Get PIN Code For Ecobee" buttontext="Get PIN" command="GetPINCODE" hidden="true"/>
      <object type="text" id="PINCODE" label="PIN Code" value="" hidden="true"/>
    </section>
  </extra>
</extras_setup>
```

---

## Key Lessons Learned

### Local Packaging And Validation

Run the local validator before opening a PR:

```sh
scripts/validate.sh [path/to/proflame_wifi_connect.c4z]
```

Rebuild the checked-in Control4 archive from source files with:

```sh
scripts/package.sh [path/to/proflame_wifi_connect.c4z]
```

`scripts/package.sh` first runs `scripts/bundle.sh`, which concatenates `src/driver.lua` and the vendored libraries under `vendor/` into the single `driver.lua` that ships inside the `.c4z`. **Edit `src/driver.lua` and `vendor/*.lua`, not `driver.lua` at the repo root** — that file is generated. `scripts/validate.sh` rejects working trees where `driver.lua` doesn't match what a fresh `bundle.sh` run would produce.

#### Vendored libraries

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
| `vendor/drivers-common-public/global/timer.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `SetTimer`/`CancelTimer`/`ONE_SECOND` etc. (used by `websocket.lua` for WS-level ping/pong) |
| `vendor/drivers-common-public/global/handlers.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | framework handler dispatch tables `OCS`/`RFN`/`OPC`/etc. — driver's top-level `OnConnectionStatusChanged` / `ReceivedFromNetwork` delegate to `OCS[netBinding]` / `RFN[netBinding]` for WebSocket-owned bindings |
| `vendor/drivers-common-public/module/metrics.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `Metrics` factory (counters consumed by `websocket.lua`) |
| `vendor/drivers-common-public/module/websocket.lua` | [snap-one/drivers-common-public@`64663d5`](https://github.com/snap-one/drivers-common-public/tree/64663d5deacaec25327418d207dc4b0e5e0f27ab) | `WebSocket:new()` factory — owns RFC 6455 handshake/framing/masking/ping-pong; replaced 9 hand-rolled helpers in C1 Phase 2 (driver `2026060302`) |

The `vendor/drivers-common-public/` tree mirrors upstream's directory layout exactly and the files are byte-identical to upstream master at the linked commit. They `require()` each other; a small `require` shim in `src/driver.lua` maps those calls to the bundled globals so the side-effect top-level code in each vendor file works under the bundled single-file deployment model.

Both scripts read the package file list from `scripts/manifest.txt`. The packager normalizes ZIP entry timestamps so repeated rebuilds produce byte-identical archives when the source files are unchanged. The validator checks `driver.xml` with `xmllint`, verifies required source/package files, confirms the `.c4z` contains only the expected driver files, and fails if packaged source files are stale relative to the working tree. The same validation and deterministic rebuild check run in GitHub Actions on pushes to `main` and on pull requests.

### Unit Tests

Pure-Lua unit tests live under `test/`. Run them with:

```sh
test/run_tests.sh
```

Each `test/test_*.lua` file is executed in its own `lua5.1` process. The runner regenerates `driver.lua` from `src/` + `vendor/` via `bundle.sh` first so tests always reflect the current source. The C4 API is stubbed via `test/c4_shim.lua` (in-memory persist store, capturable Debug/Error log sinks, no-op fallbacks for everything else). Tests assert against the bundled driver's pure-logic functions: temperature codec, command builders, JSON wrappers, persist round-trip. The same suite runs in GitHub Actions on every push/PR.

To add a test, drop a file matching `test/test_*.lua` that starts with `require("c4_shim"); dofile("driver.lua")` and uses `Test.assertEqual` / `Test.assert` from the shim.

### Updating the driver from inside Composer

The driver exposes three Composer **Actions** commands plus an `Update Status` read-only property. See the [Driver Updates](#driver-updates) section near the top for the operator summary; the mechanics:

1. Query `https://api.github.com/repos/psaab/proflame_c4/releases` and select the **highest-versioned** non-draft, non-prerelease entry via the vendored semver comparator (the array is scanned for max version, not assumed newest-first).
2. Compare that release's tag to the installed `DRIVER_VERSION`.
3. On **Install Latest Release**, if newer: download the matching `proflame_wifi_connect.c4z` asset, write it to `C4Z_ROOT/`, and drive Composer's local SOAP endpoint at `127.0.0.1:5020` to invoke `UpdateProjectC4i` — Composer tears down the running driver instance and loads the new one.

The three commands:

- **Check for Update** — report-only; runs steps 1–2 and writes the result to `Update Status` without downloading or installing.
- **Install Latest Release** — runs steps 1–3; installs only when the latest release is newer.
- **Force Reinstall Latest Release** — runs step 3 unconditionally (`forceUpdate=true`), reinstalling the latest release even when versions match (recovery/repair; may reinstall an older build if the latest release is behind the running one).

`Update Status` reflects progress and surfaces every mode as a human-readable string: `Idle`, `Checking GitHub for the latest release...`, `Force-reinstalling the latest release...`, `Update available: <tag> (current <ver>) …`, `Up to date (<ver>, latest release <tag>)`, `Installed: <files> (controller may reload driver)`, `No install applied (current: <ver>) …`, `Failed: <reason>`, `Update check failed: <reason>`, or `Install already running` for repeat clicks while an install is in flight.

**Installs are always manual.** Update *detection* runs automatically: a report-only check fires ~10 s after driver load and then every **`Update Check Interval`** hours (default 24; `0` disables). If an install click fires but no progress appears within 60 seconds, an internal HTTP watchdog clears the in-flight state and surfaces a timeout error.

### Composer Command Smoke Test

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

### 1. Proflame Protocol
- **No spaces in JSON** - Commands with spaces are silently ignored
- **Temperature encoding** - Always multiply/divide by 10
- **WebSocket on port 88** - Non-standard port
- **PROFLAMEPING/PONG** - Custom keep-alive protocol

### 2. Control4 Extras
- **Documentation is wrong** - The documented XML format does not work
- **Use SendDataToUI()** - This is the primary method that works
- **Embed values in setup XML** - Don't rely on separate state updates
- **First list item = selected** - Reorder to show current selection
- **Throttle updates** - Avoid spamming during initialization

### 3. Control4 Driver Development
- **has_extras must be lowercase** - `true` not `True`
- **Proxy IDs start at 5001** - Convention for thermostat drivers
- **Test with Composer logs** - Debug output shows actual XML being sent
- **Check working drivers** - Analyze successful implementations

---

## Appendix: Lua Helper Functions

### Temperature Conversion
```lua
function FahrenheitToCelsius(f)
    return math.floor((f - 32) * 5 / 9 * 10 + 0.5) / 10
end

function CelsiusToFahrenheit(c)
    return math.floor(c * 9 / 5 + 32 + 0.5)
end

function DecodeTemperature(encoded)
    return tonumber(encoded) / 10
end

function EncodeTemperature(tempF)
    return tostring(math.floor(tempF * 10))
end
```

### JSON Command Builder
```lua
-- Both builders rely on JSON.lua's alphabetical key sort matching the
-- documented wire-format order: `command < name < value` and
-- `control0 < value0`. Any new key added here must respect that ordering or
-- the wire format will silently change.
function BuildSetControlCommand(control, value)
    return JSON:encode({ command = "set_control", name = tostring(control), value = tostring(value) })
end

function BuildLegacyIndexedCommand(control, value)
    return JSON:encode({ control0 = tostring(control), value0 = tostring(value) })
end

function BuildDeviceControlCommandPlan(control, value, format)
    -- Returns documented, legacy, or dual command payloads in the configured order.
end
```

All outbound control writes use `BuildDeviceControlCommandPlan`. The `Command Format (non-Turn-Off)` property controls non-Turn-Off command sends. The default is `Legacy Only`, which sends the legacy indexed format (`{"control0":"...","value0":"..."}`) verified on firmware `FW: 625.04.673`. Use `Documented Only` and both dual orderings for real-device compatibility testing; compare `Dual (Documented First)` against `Dual (Legacy First)` because message order may determine which format the firmware accepts. Other firmware variants may need a different setting. Turn Off uses the same command-plan wrapper with the verified legacy-only format.

Manual command-format verification should record the selected format and status echo for `main_mode`, `flame_control`, `fan_control`, `lamp_control`, `temperature_set`, `timer_set`, and `timer_status`.

### WebSocket Frame Builder
```lua
function CreateWebSocketFrame(payload, opcode)
    -- Client-to-device WebSocket frames are masked per RFC 6455.
    local len = #payload
    local frame = string.char(0x80 + opcode)  -- FIN + opcode
    local mask = GenerateRandomBytes(4)
    if len < 126 then
        frame = frame .. string.char(0x80 + len)
    elseif len < 65536 then
        frame = frame .. string.char(0x80 + 126,
            math.floor(len / 256), len % 256)
    end
    frame = frame .. mask
    for i = 1, #payload do
        local byte = payload:byte(i)
        local maskByte = mask:byte(((i - 1) % 4) + 1)
        frame = frame .. string.char(bit.bxor(byte, maskByte))
    end
    return frame
end
```

---

## Document History
- **v1.0** (2025-12-17): Initial specification based on driver development
