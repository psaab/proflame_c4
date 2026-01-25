# Proflame WiFi Fireplace Control4 Driver Specification

## Document Version
- **Version**: 1.0
- **Date**: January 2025
- **Driver Version**: 2025012328 (v64)

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
- Auto-off timer (0-360 minutes)
- Operating mode selection (Manual, Smart Thermostat, Eco)
- Temperature monitoring and setpoint control
- Real-time status synchronization

### 1.3 Hardware Requirements
- Proflame WiFi module (tested with firmware 625.04.673)
- Control4 controller
- Network connectivity between controller and fireplace

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
- **Opcode 0x09**: Ping
- **Opcode 0x0A**: Pong
- **Opcode 0x08**: Close

Client-to-server frames MUST be masked. Server-to-client frames are NOT masked.

### 2.4 Message Format

**CRITICAL**: All JSON messages must have NO SPACES. The device parser is sensitive to formatting.

#### Command Format (Client → Device)
```json
{"control0":"<parameter>","value0":"<value>"}
```

Multiple parameters in one message:
```json
{"control0":"<param1>","value0":"<val1>","control1":"<param2>","value1":"<val2>"}
```

#### Status Format (Device → Client)
```json
{"status0":"<parameter>","value0":"<value>","status1":"<param2>","value1":"<val2>",...}
```

### 2.5 Initial Connection Sequence

After WebSocket handshake completes, send this command to request full device status:
```json
{"control0":"CYCLEDATA","value0":"CYCLEDATA"}
```

The device will respond with multiple JSON messages containing all current status values.

### 2.6 Keep-Alive

Send WebSocket ping frames every 5-10 seconds to maintain connection. The device will respond with pong frames.

### 2.7 Operating Modes

| Mode Value | Name | Description |
|------------|------|-------------|
| 0 | Off | Fireplace off |
| 1 | Standby | Pilot may be lit, burner off |
| 2 | (Reserved) | |
| 3 | Smart Thermostat | Temperature-controlled operation |
| 4 | Eco | Energy-saving thermostat mode |
| 5 | Manual | Direct flame control |

### 2.8 Temperature Encoding

Temperatures are encoded as integers: **Fahrenheit × 10**

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

### 2.10 Complete Parameter Reference

#### Controllable Parameters (control0)

| Parameter | Values | Description |
|-----------|--------|-------------|
| `main_mode` | 0-5 | Operating mode |
| `flame_control` | 1-6 | Flame height level |
| `fan_control` | 0-6 | Fan speed (0=off) |
| `lamp_control` | 0-6 | Downlight brightness |
| `temperature_set` | 320-900 | Setpoint (F×10) |
| `thermo_control` | 0,1 | Thermostat enable |
| `pilot_control` | 0,1 | Pilot flame control |
| `aux_control` | 0,1 | Auxiliary output |
| `split_control` | 0,1 | Split/front flame |
| `timer_set` | 0-21600000 | Timer value in ms |
| `timer_status` | 0,1 | Timer running state |
| `CYCLEDATA` | CYCLEDATA | Request full status |

#### Status Parameters (status0)

All controllable parameters plus:

| Parameter | Description |
|-----------|-------------|
| `room_temperature` | Current temp (F×10) |
| `timer_count` | Remaining time in ms |
| `burner_status` | Burner state bitmap |
| `wifi_signal_str` | WiFi RSSI (positive value, actual is negative) |
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
- Device sends `timer_count` updates approximately every second
- When timer expires, device sets `main_mode` to 0 (off)
- `timer_count` continues to report the set value even when timer is stopped

---

## 3. Control4 Driver Architecture

### 3.1 File Structure

A Control4 driver (.c4z) is a ZIP file containing:
```
driver.xml      - Driver configuration and metadata
driver.lua      - Lua implementation code
www/            - Optional web content
  documentation.html
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

### 3.3 Property System

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

### 3.4 Timer System

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

**Wrong**:
```lua
local function MyCallback()
    -- May have stale values
end
C4:SetTimer(1000, MyCallback, false)
```

**Correct**:
```lua
C4:SetTimer(1000, function(timer)
    -- Code here
end, false)
```

### 3.5 Network Connections

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

function OnNetworkBindingChanged(idBinding, bIsBound)
    -- Called when binding state changes
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    -- Called when data arrives
end
```

### 3.6 Proxy Communication

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
  <proxy proxybindingid="5001" name="Fireplace Name">thermostatV2</proxy>
</proxies>
```

### 4.2 Capabilities Declaration

```xml
<capabilities>
  <can_heat>True</can_heat>
  <can_cool>False</can_cool>
  <can_do_auto>False</can_do_auto>
  <has_humidity>False</has_humidity>
  <has_outdoor_temperature>False</has_outdoor_temperature>
  <can_lock_buttons>False</can_lock_buttons>
  <has_connection_status>True</has_connection_status>
  <can_change_scale>True</can_change_scale>
  <has_single_setpoint>True</has_single_setpoint>
  <has_extras>True</has_extras>
  <has_vacation_mode>False</has_vacation_mode>
  <heat_setpoint_min_f>60</heat_setpoint_min_f>
  <heat_setpoint_max_f>90</heat_setpoint_max_f>
  <setpoint_resolution>1</setpoint_resolution>
  <has_remote_sensor>False</has_remote_sensor>
  <can_preset_schedule>False</can_preset_schedule>
</capabilities>
```

### 4.3 HVAC Modes

The thermostat proxy uses these HVAC mode strings:

| Mode | Description |
|------|-------------|
| `Off` | System off |
| `Heat` | Heating active |
| `Cool` | Cooling active (not used for fireplace) |
| `Auto` | Automatic mode |

### 4.4 Hold Modes

Hold modes control flame level:

| Hold Mode | Description |
|-----------|-------------|
| `Off` | No hold (normal operation) |
| `2 Hours` | Temporary hold |
| `Until Next` | Hold until next schedule |
| `Permanent` | Indefinite hold |

### 4.5 Key Proxy Notifications

```lua
-- Temperature update
C4:SendToProxy(5001, "TEMPERATURE_CHANGED", {
    TEMPERATURE = tempF * 10,  -- Note: some proxies want ×10
    SCALE = "FAHRENHEIT"
})

-- HVAC mode change
C4:SendToProxy(5001, "HVAC_MODE_CHANGED", {MODE = "Heat"})

-- Hold mode change  
C4:SendToProxy(5001, "HOLD_MODE_CHANGED", {MODE = "Permanent"})

-- Heat setpoint change
C4:SendToProxy(5001, "HEAT_SETPOINT_CHANGED", {SETPOINT = tempF})

-- Fan mode change
C4:SendToProxy(5001, "FAN_MODE_CHANGED", {MODE = "Low"})

-- Preset/operating mode change
C4:SendToProxy(5001, "PRESET_CHANGED", {PRESET = "Manual"})

-- Connection status
C4:SendToProxy(5001, "CONNECTION_STATUS_CHANGED", {STATUS = "online"})
```

### 4.6 Key Proxy Commands (ReceivedFromProxy)

| Command | Parameters | Description |
|---------|------------|-------------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode |
| `SET_SETPOINT_HEAT` | SETPOINT | Set heat setpoint |
| `SET_MODE_HOLD` | MODE | Set hold mode |
| `SET_MODE_FAN` | MODE | Set fan mode |
| `DEC_SETPOINT_HEAT` | - | Decrease setpoint |
| `INC_SETPOINT_HEAT` | - | Increase setpoint |

---

## 5. Extras UI System

### 5.1 Overview

The Extras UI allows custom controls to appear in the Control4 app. For thermostats, this appears as an additional panel with custom sliders, buttons, and lists.

### 5.2 Enabling Extras

In capabilities:
```xml
<has_extras>True</has_extras>
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

### 5.5 Sending Extras to UI

```lua
function SetupExtras()
    local xml = GetExtrasXML()  -- Build XML string
    
    -- Primary method - DataToUI
    C4:SendDataToUI(xml)
    
    -- Also send via proxy notification
    C4:SendToProxy(5001, "EXTRAS_SETUP_CHANGED", {XML = xml})
end
```

### 5.6 Receiving Extras Commands

Extras commands arrive via `ReceivedFromProxy`:

```lua
function ReceivedFromProxy(idBinding, strCommand, tParams)
    if strCommand == "SET_FLAME_LEVEL" then
        local level = tParams["VALUE"]
        -- Handle slider change
    elseif strCommand == "SELECT_MODE" then
        local mode = tParams["VALUE"] or tParams["value"]
        -- Handle list selection
    end
end
```

**Note**: Parameter names may be uppercase or lowercase depending on the control type and Control4 version. Always check both.

### 5.7 Updating Extras Values

Since slider values are embedded in the XML, you must resend the entire extras XML to update displayed values:

```lua
function UpdateExtrasState()
    -- Regenerate and resend XML
    SetupExtras()
end
```

### 5.8 Throttling Updates

To avoid overwhelming the UI, throttle rapid updates:

```lua
gExtrasThrottle = false

function UpdateExtrasState()
    if gExtrasThrottle then return end
    gExtrasThrottle = true
    C4:SetTimer(500, function()
        gExtrasThrottle = false
        SetupExtras()
    end, false)
end

-- For critical updates that must be immediate:
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

### 6.3 Timer State Management

Use separate tracking for:
- **timer_set**: What the user/driver has requested (driver-controlled)
- **timer_count**: What the device reports (device-controlled)

**Key Principle**: Only update `timer_set` from user commands, never from device responses.

### 6.4 Suppression Flag Pattern

When changing timer values, suppress device updates to prevent race conditions:

```lua
gSuppressTimerUpdates = false

-- In SET_TIMER_MINUTES handler:
gSuppressTimerUpdates = true
gState.timer_set = "0"
gState.timer_count = "0"
-- Send commands...
UpdateTimerExtras()  -- Immediate update
C4:SetTimer(2000, function()
    gSuppressTimerUpdates = false
end, false)

-- In timer_count status handler:
if gSuppressTimerUpdates then
    return  -- Ignore device updates while suppressed
end
```

### 6.5 Slider Countdown Display

To make the slider count down with the timer:

1. Track minute boundaries in `timer_count` updates
2. When minutes change, update `timer_set` to match
3. Resend extras XML immediately (no throttle)

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

### 6.6 Timer Display Format

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

### 7.3 State Reset on Reconnect

Always reset state when connection is lost or driver is updated:

```lua
function ResetDriverState()
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gReceiveBuffer = ""
    gSuppressTimerUpdates = false
    -- Reset gState to defaults
end
```

---

## 8. Network Connection Management

### 8.1 Connection Lifecycle

```
[Disconnected] → Connect() → [Connecting] → OnConnectionStatusChanged("ONLINE")
    → Send WebSocket Handshake → Receive Handshake Response
    → [Connected/Handshake Complete] → Send CYCLEDATA → Receive Status
```

### 8.2 WebSocket Implementation

Since Control4 doesn't provide a WebSocket library, implement manually:

```lua
function CreateWebSocketHandshake()
    -- Generate random key
    local key = ""
    for i = 1, 16 do
        key = key .. string.char(math.random(0, 255))
    end
    gWebSocketKey = C4:Base64Encode(key)
    
    local request = 
        "GET / HTTP/1.1\r\n" ..
        "Host: " .. Properties["IP Address"] .. ":" .. Properties["Port"] .. "\r\n" ..
        "Upgrade: websocket\r\n" ..
        "Connection: Upgrade\r\n" ..
        "Sec-WebSocket-Key: " .. gWebSocketKey .. "\r\n" ..
        "Sec-WebSocket-Version: 13\r\n" ..
        "\r\n"
    return request
end

function CreateWebSocketFrame(payload, opcode)
    opcode = opcode or 0x01  -- Text frame
    local len = #payload
    local frame = string.char(0x80 + opcode)  -- FIN + opcode
    
    -- Length encoding
    if len < 126 then
        frame = frame .. string.char(0x80 + len)  -- Masked + length
    elseif len < 65536 then
        frame = frame .. string.char(0x80 + 126)
        frame = frame .. string.char(math.floor(len / 256))
        frame = frame .. string.char(len % 256)
    end
    
    -- Masking key (4 random bytes)
    local mask = ""
    for i = 1, 4 do
        mask = mask .. string.char(math.random(0, 255))
    end
    frame = frame .. mask
    
    -- Masked payload
    for i = 1, len do
        local byte = payload:byte(i)
        local maskByte = mask:byte(((i - 1) % 4) + 1)
        frame = frame .. string.char(bit.bxor(byte, maskByte))
    end
    
    return frame
end
```

### 8.3 Reconnection Strategy

```lua
gReconnectDelay = 10000  -- 10 seconds

function ScheduleReconnect()
    if gReconnectTimerId then return end
    gReconnectTimerId = C4:SetTimer(gReconnectDelay, function()
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
        ScheduleReconnect()
    end
end
```

### 8.4 Ping/Pong Keep-Alive

```lua
function StartPingTimer()
    local interval = (tonumber(Properties["Ping Interval (seconds)"]) or 5) * 1000
    gPingTimerId = C4:SetTimer(interval, function()
        if gConnected and gHandshakeComplete then
            SendPing()
        end
    end, true)  -- Repeating
end

function SendPing()
    local frame = CreateWebSocketFrame("", 0x09)  -- Ping opcode
    C4:SendToNetwork(6001, tonumber(Properties["Port"]) or 88, frame)
end
```

---

## 9. XML Configuration

### 9.1 Complete driver.xml Structure

```xml
<?xml version="1.0"?>
<devicedata>
  <copyright>Copyright notice</copyright>
  <name>Driver Name</name>
  <small>devices_sm/icon.gif</small>
  <large>devices_lg/icon.gif</large>
  <control>lua_gen</control>
  <controlmethod>IP</controlmethod>
  <version>2025012328</version>
  
  <proxies>
    <proxy proxybindingid="5001" name="Display Name">thermostatV2</proxy>
  </proxies>
  
  <combo>false</combo>
  <driver>DriverWorks</driver>
  
  <composer_categories>
    <category>HVAC</category>
  </composer_categories>
  
  <states/>
  
  <config>
    <documentation file="www/documentation.html"/>
    
    <properties>
      <!-- Property definitions -->
    </properties>
    
    <commands>
      <!-- Command definitions -->
    </commands>
    
    <script file="driver.lua" encryption="0" jit="1"/>
  </config>
  
  <events>
    <!-- Event definitions -->
  </events>
  
  <connections>
    <connection proxybindingid="5001">
      <id>5001</id>
      <type>2</type>
      <connectionname>Thermostat</connectionname>
      <consumer>False</consumer>
    </connection>
  </connections>
  
  <capabilities>
    <!-- Capability definitions -->
  </capabilities>
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

### 9.3 Command Definition

```xml
<command>
  <name>Command Name</name>
  <description>What this command does</description>
  <params>
    <param>
      <name>Parameter Name</name>
      <type>STRING</type>
    </param>
  </params>
</command>
```

### 9.4 Event Definition

```xml
<event>
  <id>1</id>
  <name>Event Name</name>
  <description>When this event fires</description>
</event>
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

-- Immediate function (for critical updates)
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

### 10.7 Driver Update Not Taking Effect

**Problem**: Control4 caches old driver state
**Solution**: Implement `OnDriverUpdated()` callback

```lua
function OnDriverUpdated()
    -- Clean up
    StopPingTimer()
    StopReconnectTimer()
    Disconnect()
    
    -- Reset state
    ResetDriverState()
    
    -- Reinitialize
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
    
    -- Reconnect
    C4:SetTimer(1000, function()
        Connect()
    end, false)
end
```

### 10.8 WebSocket Frame Parsing

**Problem**: Partial frames or multiple frames in single receive
**Solution**: Buffer received data and parse complete frames

```lua
gReceiveBuffer = ""

function ReceivedFromNetwork(idBinding, nPort, strData)
    gReceiveBuffer = gReceiveBuffer .. strData
    
    while true do
        local opcode, payload, remaining = ParseWebSocketFrame(gReceiveBuffer)
        if not opcode then break end
        gReceiveBuffer = remaining
        HandleWebSocketMessage(opcode, payload)
    end
end
```

---

## 11. Complete Command Reference

### 11.1 Proflame Commands (Send)

| Command | Value | Description |
|---------|-------|-------------|
| `{"control0":"main_mode","value0":"0"}` | 0-5 | Set operating mode |
| `{"control0":"flame_control","value0":"3"}` | 1-6 | Set flame level |
| `{"control0":"fan_control","value0":"2"}` | 0-6 | Set fan speed |
| `{"control0":"lamp_control","value0":"4"}` | 0-6 | Set lamp level |
| `{"control0":"temperature_set","value0":"700"}` | 320-900 | Set temp (F×10) |
| `{"control0":"timer_set","value0":"3600000"}` | ms | Set timer duration |
| `{"control0":"timer_status","value0":"1"}` | 0,1 | Start/stop timer |
| `{"control0":"CYCLEDATA","value0":"CYCLEDATA"}` | - | Request full status |

### 11.2 Control4 Proxy Commands (Receive)

| Command | Parameters | Action |
|---------|------------|--------|
| `SET_MODE_HVAC` | MODE | Set HVAC mode (Off/Heat) |
| `SET_SETPOINT_HEAT` | SETPOINT | Set temperature setpoint |
| `SET_MODE_FAN` | MODE | Set fan mode |
| `SET_MODE_HOLD` | MODE | Set hold mode |
| `INC_SETPOINT_HEAT` | - | Increase setpoint by 1 |
| `DEC_SETPOINT_HEAT` | - | Decrease setpoint by 1 |
| `SET_FLAME_LEVEL` | VALUE | Set flame (from extras) |
| `SET_FAN_LEVEL` | VALUE | Set fan (from extras) |
| `SET_LIGHT_LEVEL` | VALUE | Set lamp (from extras) |
| `SET_TIMER_MINUTES` | VALUE | Set timer (from extras) |
| `SELECT_MODE` | VALUE | Select mode (from extras) |

### 11.3 Control4 Proxy Notifications (Send)

| Notification | Parameters | Purpose |
|--------------|------------|---------|
| `TEMPERATURE_CHANGED` | TEMPERATURE, SCALE | Update current temp |
| `HVAC_MODE_CHANGED` | MODE | Update HVAC mode |
| `HOLD_MODE_CHANGED` | MODE | Update hold mode |
| `HEAT_SETPOINT_CHANGED` | SETPOINT | Update setpoint |
| `FAN_MODE_CHANGED` | MODE | Update fan mode |
| `PRESET_CHANGED` | PRESET | Update preset mode |
| `CONNECTION_STATUS_CHANGED` | STATUS | Update connection |
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

### 12.2 Basic Control Tests

- [ ] Turn fireplace on via Control4
- [ ] Turn fireplace off via Control4
- [ ] Adjust flame level via slider
- [ ] Adjust fan speed via slider
- [ ] Adjust lamp level via slider
- [ ] Change operating mode via list

### 12.3 Timer Tests

- [ ] Set timer when fireplace is off (should turn on)
- [ ] Set timer when fireplace is on
- [ ] Timer slider counts down each minute
- [ ] Timer label updates (e.g., "1h30m" → "1h29m")
- [ ] Set timer to 0 turns off fireplace
- [ ] Timer slider stays at 0 after turning off
- [ ] Changing timer value mid-countdown works
- [ ] Timer reaching 0 turns off fireplace

### 12.4 Temperature Tests

- [ ] Room temperature displays correctly
- [ ] Setpoint changes work
- [ ] Temperature displays in correct scale (F/C)

### 12.5 State Synchronization Tests

- [ ] Fireplace changed via wall switch updates Control4
- [ ] Fireplace changed via mobile app updates Control4
- [ ] Multiple Control4 interfaces stay in sync
- [ ] Driver restart restores correct state

### 12.6 Driver Update Tests

- [ ] Driver update applies without controller reboot
- [ ] Version number updates after driver update
- [ ] Connection re-establishes after update
- [ ] State is preserved across updates

### 12.7 Edge Cases

- [ ] Very long timer values (6 hours)
- [ ] Rapid slider movements
- [ ] Network disconnect during command
- [ ] Multiple simultaneous commands

---

## Appendix A: Sample Lua Code Structure

```lua
-- Constants
DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2025012328"
NETWORK_BINDING_ID = 6001
THERMOSTAT_PROXY_ID = 5001

MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_SMART = "3"
MODE_ECO = "4"
MODE_MANUAL = "5"

-- State
gConnected = false
gConnecting = false
gHandshakeComplete = false
gReceiveBuffer = ""
gPingTimerId = nil
gReconnectTimerId = nil
gSuppressTimerUpdates = false
gExtrasThrottle = false

gState = {
    main_mode = "0",
    flame_control = "0",
    -- ... etc
}

-- Logging
function dbg(msg)
    print("[Proflame] " .. msg)
end

-- WebSocket Functions
function CreateWebSocketHandshake() ... end
function CreateWebSocketFrame(payload, opcode) ... end
function ParseWebSocketFrame(data) ... end

-- Network Functions
function Connect() ... end
function Disconnect() ... end
function Reconnect() ... end
function SendWebSocketMessage(msg) ... end
function SendProflameCommand(param, value) ... end

-- Timer Functions
function StartPingTimer() ... end
function StopPingTimer() ... end
function ScheduleReconnect() ... end
function StopReconnectTimer() ... end

-- Status Processing
function ProcessStatusUpdate(status, value) ... end

-- Proxy Updates
function UpdateThermostatProxy(mode) ... end
function UpdateFlameLevel() ... end
function UpdateFanMode() ... end
function UpdateRoomTemperature() ... end

-- Extras UI
function GetExtrasXML() ... end
function SetupExtras() ... end
function UpdateExtrasState() ... end
function UpdateTimerExtras() ... end

-- Callbacks
function OnDriverInit() ... end
function OnDriverLateInit() ... end
function OnDriverUpdated() ... end
function OnDriverDestroyed() ... end
function OnPropertyChanged(strProperty) ... end
function OnConnectionStatusChanged(idBinding, nPort, strStatus) ... end
function ReceivedFromNetwork(idBinding, nPort, strData) ... end
function ReceivedFromProxy(idBinding, strCommand, tParams) ... end
```

---

## Appendix B: Version History

| Version | Date | Changes |
|---------|------|---------|
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
