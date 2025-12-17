# Proflame WiFi Control4 Driver - Complete Specification

**Document Version:** 1.0  
**Last Updated:** December 16, 2025  
**Author:** Paul Saab  

---

## Table of Contents

1. [Overview](#overview)
2. [Proflame WiFi Protocol Specification](#proflame-wifi-protocol-specification)
3. [Control4 Driver Architecture](#control4-driver-architecture)
4. [Key Lessons Learned](#key-lessons-learned)
5. [Building the C4Z Package](#building-the-c4z-package)
6. [Current Driver Status](#current-driver-status)

---

## Overview

This document describes a Control4 driver for SIT Group Proflame 2 WiFi fireplace controllers. The driver provides full fireplace control through the Control4 ecosystem including thermostat integration, flame level control, fan control, lighting, and more.

### Features

- **Thermostat Proxy (thermostatV2):** HVAC mode control, temperature setpoint, fan speed
- **Light Proxy (light_v2):** Flame level as dimmer (0-100% → 0-6 levels)
- **Full Control:** Flame, fan, light, pilot, aux output, timer
- **Operating Modes:** Off, Standby, Manual, Smart (Thermostat), Eco
- **Real-time Status:** Push notifications from device via WebSocket
- **Extras Menu:** Flame height slider in iOS/Android app extras tab

---

## Proflame WiFi Protocol Specification

### Connection Details

| Parameter | Value |
|-----------|-------|
| Protocol | WebSocket (RFC 6455) |
| Port | 88 (TCP) |
| Keep-Alive | PROFLAMEPING/PROFLAMEPONG every 5 seconds |

### WebSocket Handshake

The device requires a standard WebSocket handshake:

```
GET / HTTP/1.1
Host: <device_ip>:88
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: <base64-encoded-random-key>
Sec-WebSocket-Version: 13
```

The device responds with HTTP 101 Switching Protocols and the connection upgrades to WebSocket.

### Keep-Alive Mechanism

**CRITICAL:** The device uses a custom keep-alive mechanism, NOT standard WebSocket ping/pong frames.

- Send text message `PROFLAMEPING` every 5 seconds
- Expect text response `PROFLAMEPONG`
- If no pong received, connection may be stale - reconnect

### Command Format

**CRITICAL:** JSON must be compact with NO SPACES after colons or commas. The device silently ignores malformed commands.

```json
{"control0":"<control>","value0":"<value>"}
```

✅ Correct: `{"control0":"main_mode","value0":"5"}`  
❌ Wrong: `{"control0": "main_mode", "value0": "5"}` (has spaces - will be ignored!)

### Operating Modes (main_mode)

| Value | Mode | Description |
|-------|------|-------------|
| 0 | Off | Fireplace completely off |
| 1 | Standby | Pilot on, burner off |
| 5 | Manual | Manual flame control |
| 6 | Smart | Thermostat with modulating flame |
| 7 | Eco | Energy-saving thermostat mode |

**Note:** `main_mode` is the authoritative power state. Do NOT derive power state from `burner_status` or other fields.

### Control Parameters

| Control | Range | Description |
|---------|-------|-------------|
| main_mode | 0,1,5,6,7 | Operating mode |
| flame_control | 0-6 | Flame height level |
| fan_control | 0-6 | Blower fan speed |
| lamp_control | 0-6 | Accent lighting level |
| temperature_set | 600-900 | Target temp (°F × 10) |
| pilot_control | 0, 1 | Continuous pilot on/off |
| aux_control | 0, 1 | Auxiliary relay on/off |
| split_flow | 0, 1 | Front flame (split burner) |
| timer_set | 0-28800000 | Auto-off timer (milliseconds) |

### Temperature Encoding

**CRITICAL:** All temperatures in the Proflame protocol are Fahrenheit × 10.

- **Encode:** `temperature_F × 10` (e.g., 72°F → 720)
- **Decode:** `value / 10` (e.g., 720 → 72°F)
- **Range:** 600-900 (60°F to 90°F)

### Command Examples

```json
Turn On (Manual):     {"control0":"main_mode","value0":"5"}
Turn Off:             {"control0":"main_mode","value0":"0"}
Set to Standby:       {"control0":"main_mode","value0":"1"}
Set Smart Mode:       {"control0":"main_mode","value0":"6"}
Set Eco Mode:         {"control0":"main_mode","value0":"7"}
Set Flame Level 4:    {"control0":"flame_control","value0":"4"}
Set Temp 72°F:        {"control0":"temperature_set","value0":"720"}
Set Fan Level 3:      {"control0":"fan_control","value0":"3"}
Set Light Level 5:    {"control0":"lamp_control","value0":"5"}
Pilot On:             {"control0":"pilot_control","value0":"1"}
Aux On:               {"control0":"aux_control","value0":"1"}
60min Timer:          {"control0":"timer_set","value0":"3600000"}
Cancel Timer:         {"control0":"timer_set","value0":"0"}
```

### Status Response Format

The device sends JSON status updates (push notifications) with all current state:

```json
{
  "main_mode": "5",
  "flame_control": "3",
  "fan_control": "2",
  "lamp_control": "0",
  "temperature_set": "720",
  "temperature_read": "685",
  "pilot_control": "0",
  "aux_control": "0",
  "split_flow": "0",
  "timer_set": "0",
  "timer_read": "0",
  "burner_status": "1",
  "errors": "0",
  "rssi": "-45"
}
```

Key fields:
- `temperature_read`: Current room temperature (°F × 10)
- `timer_read`: Remaining timer in milliseconds
- `rssi`: WiFi signal strength in dBm
- `errors`: Error code (0 = no errors)

---

## Control4 Driver Architecture

### Proxy Configuration

The driver exposes two proxies:

1. **Thermostat Proxy (ID 5001):** `thermostatV2`
   - Main control interface
   - Temperature display and setpoint
   - HVAC mode (Off/Heat)
   - Fan mode control

2. **Light Proxy (ID 5002):** `light_v2`
   - Flame level as dimmer
   - 0-100% maps to 0-6 flame levels

### Network Connection (ID 6001)

- TCP connection on port 88
- Manual connection management (not auto-connect)
- Driver handles WebSocket upgrade internally

### Room Selection Connection (ID 7000)

- TEMPERATURE class for room binding
- TEMPERATURE_CONTROL class for thermostat binding
- Autobind enabled

### XML Capabilities (Critical Settings)

```xml
<capabilities>
    <has_extras>True</has_extras>
    <can_heat>True</can_heat>
    <can_cool>False</can_cool>
    <can_do_auto>False</can_do_auto>
    <temperature_scale>FAHRENHEIT</temperature_scale>
    <can_change_scale>True</can_change_scale>
    
    <!-- Current temperature range -->
    <current_temperature_min_c>-40</current_temperature_min_c>
    <current_temperature_max_c>60</current_temperature_max_c>
    <current_temperature_resolution_c>0.5</current_temperature_resolution_c>
    <current_temperature_min_f>-40</current_temperature_min_f>
    <current_temperature_max_f>140</current_temperature_max_f>
    <current_temperature_resolution_f>1</current_temperature_resolution_f>
    
    <!-- Setpoint range (MUST define both C and F!) -->
    <setpoint_heat_min_c>15.5</setpoint_heat_min_c>
    <setpoint_heat_max_c>32.2</setpoint_heat_max_c>
    <setpoint_heat_resolution_c>0.5</setpoint_heat_resolution_c>
    <setpoint_heat_min_f>60</setpoint_heat_min_f>
    <setpoint_heat_max_f>90</setpoint_heat_max_f>
    <setpoint_heat_resolution_f>1</setpoint_heat_resolution_f>
    
    <!-- Single setpoint mode (NOT split heat/cool) -->
    <has_single_setpoint>True</has_single_setpoint>
    <split_setpoints>False</split_setpoints>
    <can_inc_dec_setpoints>True</can_inc_dec_setpoints>
    
    <!-- Fan modes -->
    <has_fan_mode>True</has_fan_mode>
    <can_change_fan_modes>True</can_change_fan_modes>
    <fan_modes>Off,1,2,3,4,5,6</fan_modes>
    
    <!-- HVAC modes -->
    <hvac_modes>Off,Heat</hvac_modes>
    <hvac_states>Off,Heat</hvac_states>
    <can_change_hvac_modes>True</can_change_hvac_modes>
</capabilities>
```

---

## Key Lessons Learned

### 1. JSON Formatting is Critical

The Proflame device is extremely picky about JSON formatting. Commands with ANY whitespace after colons or commas are silently ignored.

```lua
-- CORRECT
local cmd = '{"control0":"' .. control .. '","value0":"' .. value .. '"}'

-- WRONG - will be silently ignored!
local cmd = '{"control0": "' .. control .. '", "value0": "' .. value .. '"}'
```

### 2. Temperature Scale Handling ("The Golden Rule")

This caused extensive debugging. The solution:

1. **XML Definition:** Set to FAHRENHEIT (native scale of device/user)
2. **Proxy Communication:** ALWAYS send CELSIUS with `SCALE="C"`

This is because Control4's thermostat proxy internally works in Celsius and handles the conversion for display. If you send Fahrenheit values, they get double-converted and produce wrong results (like 120°F display or slider snapping to 90°F max).

```lua
function FahrenheitToCelsius(f)
    local c = (f - 32) * 5 / 9
    return math.floor(c * 10 + 0.5) / 10  -- Round to 1 decimal
end

-- Sending temperature to proxy
local tempF = DecodeTemperature(gState.temperature_set)  -- e.g., 72
local tempC = FahrenheitToCelsius(tempF)                  -- e.g., 22.2
C4:SendToProxy(THERMOSTAT_PROXY_ID, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})
```

### 3. Single Setpoint vs Heat Setpoint

**CRITICAL:** When `<has_single_setpoint>True</has_single_setpoint>` is set in XML, you MUST use:

```lua
-- CORRECT for single setpoint mode
C4:SendToProxy(THERMOSTAT_PROXY_ID, "SINGLE_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})

-- WRONG - will be ignored when has_single_setpoint is True!
C4:SendToProxy(THERMOSTAT_PROXY_ID, "HEAT_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
```

### 4. Proxy Notification Format

**CRITICAL:** Always use table format with SCALE key for temperature notifications:

```lua
-- CORRECT
C4:SendToProxy(5001, "TEMPERATURE_CHANGED", {TEMPERATURE = 22.2, SCALE = "C"})
C4:SendToProxy(5001, "SINGLE_SETPOINT_CHANGED", {SETPOINT = 21.1, SCALE = "C"})

-- WRONG - causes "--" display or wrong values
C4:SendToProxy(5001, "TEMPERATURE_CHANGED", 70)
C4:SendToProxy(5001, "HEAT_SETPOINT_CHANGED", "72")
```

### 5. Extras Menu Implementation

To show controls in the iOS/Android app's "Extras" tab, you must:

1. Set `<has_extras>True</has_extras>` in XML capabilities
2. Handle `GET_EXTRAS_SETUP` in `ReceivedFromProxy`
3. Return properly formatted XML with extras definition

```lua
function ReceivedFromProxy(idBinding, sCommand, tParams)
    if sCommand == "GET_EXTRAS_SETUP" then
        local extrasXml = [[<extras_setup>
<section label="Fireplace Controls">
    <extra id="flame_level" label="Flame Height" type="slider" min="0" max="6" value="]] .. (gState.flame_control or "0") .. [["/>
</section>
</extras_setup>]]
        return extrasXml
    end
    -- ... handle other commands
end
```

### 6. WebSocket Frame Handling

Control4's Lua environment doesn't have built-in WebSocket support. You must implement:

- WebSocket handshake (HTTP upgrade)
- Frame encoding/decoding (masking for client-to-server)
- Text frame handling (opcode 0x81)
- Custom PROFLAMEPING/PROFLAMEPONG keep-alive

```lua
function CreateWebSocketFrame(payload)
    local len = #payload
    local frame = string.char(0x81)  -- Text frame, FIN bit set
    
    if len < 126 then
        frame = frame .. string.char(0x80 + len)  -- Masked + length
    elseif len < 65536 then
        frame = frame .. string.char(0x80 + 126)
        frame = frame .. string.char(math.floor(len / 256))
        frame = frame .. string.char(len % 256)
    end
    
    -- Add masking key and masked payload
    local maskKey = {math.random(0,255), math.random(0,255), math.random(0,255), math.random(0,255)}
    for i, k in ipairs(maskKey) do
        frame = frame .. string.char(k)
    end
    
    for i = 1, len do
        local byte = string.byte(payload, i)
        local masked = bit.bxor(byte, maskKey[((i-1) % 4) + 1])
        frame = frame .. string.char(masked)
    end
    
    return frame
end
```

### 7. Lua Code Organization

**CRITICAL:** Helper functions and utilities MUST be defined BEFORE they are used. Lua is single-pass, so forward references don't work.

Recommended order:
1. Constants
2. Bit operations (if not available natively)
3. Utility functions (dbg, helpers)
4. Crypto functions (for WebSocket key)
5. Global state variables
6. WebSocket functions
7. Command functions
8. Proxy handlers
9. Network handlers
10. Initialization

### 8. XML Element Order

Control4 XML is sensitive to element order in properties:

```xml
<!-- CORRECT order -->
<property>
    <n>Property Name</n>
    <type>STRING</type>
    <default>value</default>
    <readonly>true</readonly>
</property>

<!-- Element order matters! -->
```

### 9. Driver Updates Require Delete/Re-add

When changing XML capabilities (especially thermostat capabilities), you often need to:
1. Delete the driver from the project
2. Re-add the driver

Simply updating the driver won't apply capability changes.

### 10. Debugging Tips

- Use `print()` statements liberally - they appear in Composer Pro's Lua tab
- Set Debug Mode property to "On" and Debug Level to "Trace" during development
- Check Composer Pro's Lua output window for errors
- WebSocket issues often manifest as silent failures - add logging to all network functions

---

## Building the C4Z Package

A `.c4z` file is simply a ZIP archive with a specific structure:

```
proflame_wifi_connect_v4.c4z
├── driver.xml          # Device definition, proxies, capabilities
├── driver.lua          # Main driver logic
└── www/
    └── documentation.html  # In-driver help (optional)
```

### Build Process

```bash
# Create build directory
mkdir -p c4z_build/www

# Copy files
cp driver.lua c4z_build/
cp driver.xml c4z_build/
cp documentation.html c4z_build/www/

# Create c4z (just a zip file)
cd c4z_build
zip -r ../proflame_wifi_connect_v4.c4z driver.xml driver.lua www/
```

### Version Numbering Convention

Format: `YYYYMMDDNN` where NN is build number for that day

Example: `2025121617` = December 16, 2025, build 17

Update in three places:
1. `driver.lua` - `DRIVER_VERSION` constant
2. `driver.lua` - Header comment
3. `driver.xml` - `<version>` element

---

## Current Driver Status

### Latest Version: 2025121617

**Fixes included:**
- Network Connection (Helpers moved to top)
- Extras Menu (Flame Slider)
- Room Temperature Sensor Mapping
- Single Setpoint handling (SINGLE_SETPOINT_CHANGED)
- Temperature scale conversion (Fahrenheit device → Celsius proxy)
- Compact JSON formatting for commands
- WebSocket keep-alive (PROFLAMEPING/PROFLAMEPONG)

### Known Working Features

- ✅ Connect to Proflame WiFi device
- ✅ Turn fireplace on/off
- ✅ Set operating mode (Off, Standby, Manual, Smart, Eco)
- ✅ Control flame level (0-6)
- ✅ Control fan level (0-6)
- ✅ Control light level (0-6)
- ✅ Set temperature setpoint
- ✅ Display current room temperature
- ✅ Thermostat proxy integration
- ✅ Light proxy for flame control
- ✅ Real-time status updates

### Outstanding Items / Future Work

- Extras menu flame slider (implementation attempted, may need refinement)
- Timer control via UI
- Pilot control via UI
- Aux output control via UI
- Error status display
- Connection status events

---

## File Locations

When working with this driver:

- **User Uploads:** `/mnt/user-data/uploads/`
- **Build Directory:** `/home/claude/c4z_build/`
- **Output Directory:** `/mnt/user-data/outputs/`
- **Documentation from ZIP:** `/home/claude/c4z_extract/www/documentation.html`

---

## Quick Reference

### Mode Constants
```lua
MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_MANUAL = "5"
MODE_SMART = "6"
MODE_ECO = "7"
```

### Proxy IDs
```lua
NETWORK_BINDING_ID = 6001
THERMOSTAT_PROXY_ID = 5001
LIGHT_PROXY_ID = 5002
```

### Temperature Conversion
```lua
-- Proflame to Fahrenheit
local tempF = tonumber(encoded) / 10

-- Fahrenheit to Proflame
local encoded = tostring(math.floor(tempF * 10))

-- Fahrenheit to Celsius (for proxy)
local tempC = math.floor((tempF - 32) * 5 / 9 * 10 + 0.5) / 10
```

### Send Command to Device
```lua
local cmd = '{"control0":"' .. control .. '","value0":"' .. value .. '"}'
local frame = CreateWebSocketFrame(cmd)
C4:SendToNetwork(NETWORK_BINDING_ID, frame)
```

### Send to Thermostat Proxy
```lua
-- Temperature
C4:SendToProxy(THERMOSTAT_PROXY_ID, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})

-- Setpoint (single setpoint mode)
C4:SendToProxy(THERMOSTAT_PROXY_ID, "SINGLE_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})

-- HVAC Mode
C4:SendToProxy(THERMOSTAT_PROXY_ID, "HVAC_MODE_CHANGED", "Heat")

-- Fan Mode
C4:SendToProxy(THERMOSTAT_PROXY_ID, "FAN_MODE_CHANGED", tostring(level))
```

---

*End of Specification*
