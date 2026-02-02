# Proflame WiFi Fireplace Control4 Driver Specification

## Document Version
- **Version**: 2.0
- **Date**: February 2026
- **Driver Version**: 2025013124 (2026-01-31)

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
| Ping Interval | INTEGER | 5 | Keep-alive interval (seconds) |
| Reconnect Delay | INTEGER | 10 | Delay before reconnect (seconds) |
| Default On Mode | LIST | Smart (Thermostat) | Mode when turning on: Manual, Smart (Thermostat), Eco |
| Default Flame Level | INTEGER | 6 | Initial flame level (1-6) |
| Default Timer | INTEGER | 180 | Auto-off timer in minutes (0=disabled) |
| Debug Mode | LIST | On | Enable/disable debug logging |
| Debug Level | LIST | Debug | Error, Warning, Info, Debug, Trace |

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

### 2.3 WebSocket Frame Format

Standard WebSocket framing is used:
- **Opcode 0x01**: Text frame (used for JSON messages)
- **Opcode 0x08**: Close

Client-to-server frames MUST be masked. Server-to-client frames are NOT masked.

### 2.4 Message Format

**CRITICAL**: All JSON messages must have NO SPACES. The device parser is sensitive to formatting.

#### Command Format (Client -> Device)
```json
{"control0":"<parameter>","value0":"<value>"}
```

Multiple parameters in one message:
```json
{"control0":"<param1>","value0":"<val1>","control1":"<param2>","value1":"<val2>"}
```

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

Send `PROFLAMEPING` text message every 5 seconds (configurable). The device responds with `PROFLAMEPONG`.

**Note**: This is NOT standard WebSocket ping/pong frames, but text messages.

### 2.7 Operating Modes

| Mode Value | Name | Description |
|------------|------|-------------|
| 0 | Off | Fireplace off |
| 1 | Standby | Pilot may be lit, burner off |
| 5 | Manual | Direct flame control |
| 6 | Smart | Temperature-controlled operation |
| 7 | Eco | Energy-saving thermostat mode |

**Note**: Modes 2, 3, 4 are reserved/unused in current firmware.

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

#### Controllable Parameters (control0)

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
| `room_temperature` | Current temp (Fx10) |
| `temperature_read` | Alias for room_temperature |
| `timer_count` | Remaining time in ms |
| `timer_read` | Alias for timer_count |
| `burner_status` | Burner state bitmap |
| `wifi_signal_str` | WiFi RSSI (positive value, actual is negative) |
| `rssi` | Alias for wifi_signal_str |
| `fw_revision` | Firmware version string |
| `dongle_name` | Device name |

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
driver.lua      - Lua implementation code
www/            - Optional web content
  documentation.html
  icons/        - Device icons
    device_sm.png
    device_lg.png
```

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

**Important**: When the Lua file loads/reloads, cleanup code runs immediately (before callbacks):

```lua
-- Force cleanup of any existing timers from previous driver instance
if gPingTimerId then
    pcall(function() gPingTimerId:Cancel() end)
    gPingTimerId = nil
end

-- Force disconnect if we were connected
if gConnected then
    pcall(function()
        C4:NetDisconnect(NETWORK_BINDING_ID, port)
    end)
end

-- Reset global state to ensure clean state on driver reload
gState = { ... }
```

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

```lua
-- Create connection (binding ID is arbitrary unique number)
C4:CreateNetworkConnection(6001, ipAddress)

-- Connect
C4:NetConnect(6001, port)

-- Disconnect
C4:NetDisconnect(6001, port)

-- Send data
C4:SendToNetwork(6001, port, data)
```

Network callbacks:
```lua
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    -- strStatus: "ONLINE" or "OFFLINE"
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    -- Called when data arrives
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
  <can_preset>True</can_preset>
  <preset_modes>Manual,Smart,Eco</preset_modes>
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

### 4.5 Preset Modes (Operating Modes)

| Preset | Proflame Mode | Description |
|--------|---------------|-------------|
| Manual | 5 | Direct flame control |
| Smart | 6 | Temperature-controlled |
| Eco | 7 | Energy-saving thermostat |

### 4.6 Key Proxy Notifications

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
C4:SendToProxy(5001, "PRESET_CHANGED", {PRESET = "Manual"})
C4:SendToProxy(5001, "PRESET_MODE_CHANGED", {MODE = "Manual"})

-- Allowed modes (send on connect)
C4:SendToProxy(5001, "ALLOWED_FAN_MODES_CHANGED", {MODES = "Off,Low,Medium,High"})
C4:SendToProxy(5001, "ALLOWED_HVAC_MODES_CHANGED", {MODES = "Off,Heat"})
```

**CRITICAL**: The proxy expects temperatures in Celsius, even if the display scale is Fahrenheit. Always convert before sending.

### 4.7 Key Proxy Commands (ReceivedFromProxy)

| Command | Parameters | Description |
|---------|------------|-------------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode (Off/Heat) |
| `SET_SETPOINT_HEAT` | SETPOINT, CELSIUS, FAHRENHEIT | Set heat setpoint |
| `SET_SETPOINT_SINGLE` | SETPOINT | Set single setpoint |
| `SET_MODE_FAN` | MODE | Set fan mode (Off/Low/Medium/High) |
| `SET_SCALE` | SCALE | Change temperature scale |
| `SET_PRESET` | PRESET, MODE, NAME | Set preset mode |
| `GET_EXTRAS_SETUP` | - | Request extras XML |
| `GET_EXTRAS_STATE` | - | Request extras state |

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

To make the slider count down with the timer:

```lua
local newCount = tonumber(value) or 0
-- Use ceil when timer is active so we show at least 1m until it truly expires
local newMinutes
if timerStatus == 1 and newCount > 0 then
    newMinutes = math.ceil(newCount / 60000)
else
    newMinutes = math.floor(newCount / 60000)
end

local oldCount = tonumber(gState.timer_count) or 0
local oldMinutes = math.floor(oldCount / 60000)

gState.timer_count = value

if oldMinutes ~= newMinutes then
    gState.timer_set = tostring(newMinutes * 60000)
    UpdateTimerExtras()  -- Immediate, not throttled
end
```

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

When turning on the fireplace, automatically set timer and flame:

```lua
-- In SET_MODE_HVAC handler when mode == "Heat":
SendProflameCommand("main_mode", GetDefaultOnMode())
local defaultFlame = tonumber(Properties["Default Flame Level"]) or 3
local defaultTimer = tonumber(Properties["Default Timer (minutes)"]) or 120
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
gReceiveBuffer = ""
```

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
    gReceiveBuffer = ""
    gExtrasThrottle = false
    gSuppressTimerUpdates = false
    gTimerExpired = false
    gState = { ... }  -- Reset to defaults
end
```

---

## 8. Network Connection Management

### 8.1 Connection Lifecycle

```
[Disconnected] -> Connect() -> [Connecting] -> OnConnectionStatusChanged("ONLINE")
    -> Send WebSocket Handshake -> Receive Handshake Response
    -> [Connected/Handshake Complete] -> Send PROFLAMECONNECTION -> Receive status
```

### 8.2 WebSocket Implementation

Since Control4 doesn't provide a WebSocket library, implement manually:

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

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if strStatus == "OFFLINE" then
        gConnected = false
        gHandshakeComplete = false
        StopPingTimer()
        ScheduleReconnect()
    end
end
```

### 8.5 Ping Keep-Alive

```lua
function StartPingTimer()
    StopPingTimer()
    local interval = (tonumber(Properties["Ping Interval (seconds)"]) or 5) * 1000
    gPingTimerId = C4:SetTimer(interval, function()
        if gConnected and gHandshakeComplete then
            SendWebSocketMessage("PROFLAMEPING")
        end
    end, true)  -- Repeating
end
```

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
  <version>2025013124</version>
  <auto_update>true</auto_update>

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

```xml
<connections>
  <!-- Network connection -->
  <connection>
    <id>6001</id>
    <facing>6</facing>
    <connectionname>Proflame Network</connectionname>
    <type>4</type>
    <consumer>True</consumer>
    <classes>
      <class>
        <classname>TCP</classname>
        <ports>
          <port>
            <number>88</number>
            <auto_connect>False</auto_connect>
            <monitor_connection>False</monitor_connection>
            <keep_connection>False</keep_connection>
          </port>
        </ports>
      </class>
    </classes>
  </connection>

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
-- WRONG
local cmd = '{ "control0": "main_mode", "value0": "5" }'

-- CORRECT
local cmd = '{"control0":"main_mode","value0":"5"}'
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
    StopPingTimer()
    StopReconnectTimer()
    Disconnect()
    ResetDriverState()
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
    C4:SetTimer(1000, function()
        SetupExtras()
        Connect()
    end, false)
end
```

### 10.9 WebSocket Frame Parsing

**Problem**: Partial frames or multiple frames in single receive
**Solution**: Buffer received data and parse complete frames

```lua
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
| `{"control0":"main_mode","value0":"0"}` | 0,1,5,6,7 | Set operating mode |
| `{"control0":"flame_control","value0":"3"}` | 1-6 | Set flame level |
| `{"control0":"fan_control","value0":"2"}` | 0-6 | Set fan speed |
| `{"control0":"lamp_control","value0":"4"}` | 0-6 | Set lamp level |
| `{"control0":"temperature_set","value0":"700"}` | 600-900 | Set temp (Fx10) |
| `{"control0":"timer_set","value0":"3600000"}` | ms | Set timer duration |
| `{"control0":"timer_status","value0":"1"}` | 0,1 | Start/stop timer |
| `PROFLAMECONNECTION` | - | Initial connection announcement |
| `PROFLAMEPING` | - | Keep-alive ping |

### 11.2 Control4 Proxy Commands (Receive)

| Command | Parameters | Action |
|---------|------------|--------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode (Off/Heat) |
| `SET_SETPOINT_HEAT` | SETPOINT, CELSIUS, FAHRENHEIT | Set temperature setpoint |
| `SET_SETPOINT_SINGLE` | SETPOINT | Set single setpoint |
| `SET_MODE_FAN` | MODE | Set fan mode (Off/Low/Medium/High) |
| `SET_SCALE` | SCALE | Change temperature scale |
| `SET_PRESET` | PRESET, MODE, NAME | Set preset mode |
| `GET_EXTRAS_SETUP` | - | Request extras XML |
| `GET_EXTRAS_STATE` | - | Request extras state |
| `SELECT_MODE` | VALUE | Select mode from extras (manual/smart/eco) |
| `SET_FLAME_LEVEL` | VALUE | Set flame from extras (1-6) |
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
| `PRESET_CHANGED` | PRESET | Update preset mode |
| `PRESET_MODE_CHANGED` | MODE | Update preset mode (alternate) |
| `ALLOWED_FAN_MODES_CHANGED` | MODES | Set available fan modes |
| `ALLOWED_HVAC_MODES_CHANGED` | MODES | Set available HVAC modes |
| `EXTRAS_SETUP_CHANGED` | XML | Update extras UI |

---

## 12. Testing Checklist

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
- [ ] Default Timer is started when turning on
- [ ] Mode changes from extras apply default timer

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

```lua
-- Constants
DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2025013124"
DRIVER_DATE = "2026-01-31"
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
function Base64Encode(data) ... end
function SHA1(msg) ... end
function JsonEncode(tbl) ... end
function JsonDecode(str) ... end

-- Helper Functions
function MakeCommand(control, value) ... end
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
function UpdatePresetMode() ... end

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
