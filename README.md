# Proflame WiFi Control4 Driver Specification

## Document Version
Version 1.0 - December 17, 2025

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

### Keep-Alive Protocol
- **Ping Message**: `PROFLAMEPING` (sent every 5 seconds)
- **Pong Response**: `PROFLAMEPONG` (device responds)
- **Connection Request**: `PROFLAMECONNECTION` (triggers full status dump)

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
| pilot_mode | 0-1 | Pilot light on/off |
| auxiliary_out | 0-1 | Auxiliary output |
| split_flow | 0-1 | Split flame mode |

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
  <n>Proflame WiFi Fireplace</n>
  <control>lua_gen</control>
  <controlmethod>IP</controlmethod>
  <version>2025121721</version>
  
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
        -- Handle mode selection
    elseif strCommand == "SET_FLAME_LEVEL" then
        local value = tonumber(tParams["VALUE"] or tParams["value"])
        -- Handle slider change
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
          '<object type="slider" id="pf_flame" label="Flame" command="SET_FLAME" min="1" max="6" value="' .. flame .. '"/>' ..
          '<object type="slider" id="pf_fan" label="Fan" command="SET_FAN" min="0" max="6" value="' .. fan .. '"/>' ..
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
C4:SendToProxy(PROXY_ID, "PRESET_CHANGED", {PRESET = "Manual"})
C4:SendToProxy(PROXY_ID, "PRESET_MODE_CHANGED", {MODE = "Manual"})
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
function MakeCommand(control, value)
    -- NO SPACES - Critical for Proflame protocol
    return '{"command":"set_control","name":"' .. control .. '","value":"' .. tostring(value) .. '"}'
end
```

### WebSocket Frame Builder
```lua
function CreateWebSocketFrame(payload, opcode)
    local len = #payload
    local frame = string.char(0x80 + opcode)  -- FIN + opcode
    if len < 126 then
        frame = frame .. string.char(len)
    elseif len < 65536 then
        frame = frame .. string.char(126, 
            math.floor(len / 256), len % 256)
    end
    return frame .. payload
end
```

---

## Document History
- **v1.0** (2025-12-17): Initial specification based on driver development
