--[[
    Proflame WiFi Fireplace Controller - Control4 Driver
    Copyright 2025 Paul Saab. All rights reserved.
]]

-- =============================================================================
-- CONSTANTS
-- =============================================================================

DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2026051703"
DRIVER_DATE = "2026-05-17"

NETWORK_BINDING_ID = 6001
THERMOSTAT_PROXY_ID = 5001

EVENT_FIREPLACE_TURNED_ON = 1
EVENT_FIREPLACE_TURNED_OFF = 2
EVENT_MODE_CHANGED = 3
EVENT_CONNECTION_LOST = 4
EVENT_CONNECTION_RESTORED = 5

MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_MANUAL = "5"
MODE_SMART = "6"
MODE_ECO = "7"

DEFAULT_FLAME_LEVEL = 6
DEFAULT_TIMER_MINUTES = 180

-- Debug levels
DEBUG_ERROR = 1
DEBUG_WARN = 2
DEBUG_INFO = 3
DEBUG_DEBUG = 4
DEBUG_TRACE = 5

-- =============================================================================
-- DRIVER LOAD CLEANUP
-- When the Lua file is loaded/reloaded, this code runs immediately
-- =============================================================================

-- Force cleanup of any existing timers from previous driver instance
if gPingTimerId then
    pcall(function() gPingTimerId:Cancel() end)
    gPingTimerId = nil
end
if gReconnectTimerId then
    pcall(function() gReconnectTimerId:Cancel() end)
    gReconnectTimerId = nil
end
if gTimerModeDelayTimer then
    pcall(function() gTimerModeDelayTimer:Cancel() end)
    gTimerModeDelayTimer = nil
end
if gTimerStartDelayTimer then
    pcall(function() gTimerStartDelayTimer:Cancel() end)
    gTimerStartDelayTimer = nil
end
if gTimerSuppressClearTimer then
    pcall(function() gTimerSuppressClearTimer:Cancel() end)
    gTimerSuppressClearTimer = nil
end

-- Force disconnect if we were connected
if gConnected then
    pcall(function()
        local port = 88
        if Properties and Properties["Port"] then
            port = tonumber(Properties["Port"]) or 88
        end
        C4:NetDisconnect(NETWORK_BINDING_ID, port)
    end)
end

-- Log that we're loading
print("[Proflame] Driver loading - Version " .. DRIVER_VERSION .. " (" .. DRIVER_DATE .. ")")

-- Force reset of gState to ensure clean state on driver reload
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
gSuppressTimerUpdates = false
gExtrasThrottle = false

-- Build timestamp for cache busting - this changes every build
BUILD_TIMESTAMP = "20260517-001542"

-- Try to update version property immediately on load
pcall(function()
    if C4 and C4.UpdateProperty then
        C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ") [" .. BUILD_TIMESTAMP .. "]")
        print("[Proflame] Updated Driver Version property at load time")
    end
end)

-- =============================================================================
-- BIT OPERATIONS
-- =============================================================================

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
        function _bit.band(a, b)
            local result = 0
            local bitval = 1
            a = a or 0
            b = b or 0
            for i = 0, 31 do
                if a % 2 == 1 and b % 2 == 1 then
                    result = result + bitval
                end
                a = math.floor(a / 2)
                b = math.floor(b / 2)
                bitval = bitval * 2
            end
            return result
        end
        function _bit.bor(a, b)
            local result = 0
            local bitval = 1
            a = a or 0
            b = b or 0
            for i = 0, 31 do
                if a % 2 == 1 or b % 2 == 1 then
                    result = result + bitval
                end
                a = math.floor(a / 2)
                b = math.floor(b / 2)
                bitval = bitval * 2
            end
            return result
        end
    end
    bit = _bit
end

-- =============================================================================
-- GLOBAL STATE
-- =============================================================================

gConnected = false
gConnecting = false
gHandshakeComplete = false
gReceiveBuffer = ""
gPingTimerId = nil
gReconnectTimerId = nil
gTimerModeDelayTimer = nil
gTimerStartDelayTimer = nil
gTimerSuppressClearTimer = nil
gWebSocketKey = nil
gDebugLevel = DEBUG_DEBUG
gDebugEnabled = true
gExtrasThrottle = false
gSuppressTimerUpdates = false  -- Suppress device timer_count updates while we're setting timer
gTimerExpired = false  -- Set when timer reaches 0, cleared when timer_status goes to 1

gLastMainMode = nil
gLastConnectionOnline = false
gStatusSeen = {}

gPendingSetpointF = nil
gPendingTimer = nil

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

-- =============================================================================
-- LOGGING
-- =============================================================================

function Log(msg, level)
    if not gDebugEnabled then return end
    level = level or DEBUG_INFO
    if level <= gDebugLevel then
        print("[Proflame] " .. tostring(msg))
    end
end

function dbg(msg)
    Log(msg, DEBUG_ERROR)
end

function dbg_err(msg)
    Log(msg, DEBUG_ERROR)
end

function dbg_all(msg)
    Log(msg, DEBUG_DEBUG)
end

-- =============================================================================
-- EVENTS
-- =============================================================================

function IsFireplaceOnMode(mode)
    return mode == MODE_MANUAL or mode == MODE_SMART or mode == MODE_ECO
end

function FireDriverEvent(eventId, eventName)
    dbg_err("Firing event: " .. tostring(eventName) .. " (" .. tostring(eventId) .. ")")
    C4:FireEventByID(eventId)
end

function HandleModeEvents(newMode)
    if gLastMainMode == nil then
        gLastMainMode = newMode
        dbg_err("Mode event baseline set: " .. tostring(newMode))
        return
    end

    if newMode == gLastMainMode then return end

    local wasOn = IsFireplaceOnMode(gLastMainMode)
    local isOn = IsFireplaceOnMode(newMode)

    if not wasOn and isOn then
        FireDriverEvent(EVENT_FIREPLACE_TURNED_ON, "Fireplace Turned On")
    elseif wasOn and not isOn then
        FireDriverEvent(EVENT_FIREPLACE_TURNED_OFF, "Fireplace Turned Off")
    end

    FireDriverEvent(EVENT_MODE_CHANGED, "Mode Changed")
    gLastMainMode = newMode
end

function HandleConnectionEvent(online)
    if online == gLastConnectionOnline then return end

    gLastConnectionOnline = online
    if online then
        FireDriverEvent(EVENT_CONNECTION_RESTORED, "Connection Restored")
    else
        FireDriverEvent(EVENT_CONNECTION_LOST, "Connection Lost")
    end
end

-- =============================================================================
-- CRYPTO / ENCODING
-- =============================================================================

local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function Base64Encode(data)
    if not data or #data == 0 then return "" end
    return ((data:gsub('.', function(x)
        local r, b = '', x:byte()
        for i = 8, 1, -1 do
            r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0')
        end
        return r
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c = 0
        for i = 1, 6 do
            c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0)
        end
        return b64chars:sub(c + 1, c + 1)
    end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

local function bytes_to_w32(a, b, c, d)
    return (a or 0) * 0x1000000 + (b or 0) * 0x10000 + (c or 0) * 0x100 + (d or 0)
end

local function w32_to_bytes(i)
    return math.floor(i / 0x1000000) % 0x100,
           math.floor(i / 0x10000) % 0x100,
           math.floor(i / 0x100) % 0x100,
           i % 0x100
end

local function w32_rot(bits, a)
    local b2 = 2 ^ (32 - bits)
    local a1, b1 = math.modf(a / b2)
    return a1 + b1 * b2 * (2 ^ bits)
end

local function w32_xor_n(...)
    local args = {...}
    local result = 0
    for i = 1, #args do
        result = bit.bxor(result, args[i] or 0)
    end
    return result
end

local function w32_or(a, b)
    return bit.bor(a or 0, b or 0)
end

local function w32_and(a, b)
    return bit.band(a or 0, b or 0)
end

local function w32_not(a)
    return 4294967295 - (a or 0)
end

function SHA1(msg)
    if not msg then return "" end
    local H0, H1, H2, H3, H4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    local msg_len_in_bits = #msg * 8
    msg = msg .. string.char(0x80)
    local extra = 64 - ((#msg + 8) % 64)
    if extra == 64 then extra = 0 end
    msg = msg .. string.rep(string.char(0), extra)
    msg = msg .. string.char(0, 0, 0, 0)
    for i = 1, 4 do
        msg = msg .. string.char(math.floor(msg_len_in_bits / (256 ^ (4 - i))) % 256)
    end
    for chunk_start = 1, #msg, 64 do
        local W = {}
        for i = 0, 15 do
            local offset = chunk_start + i * 4
            W[i] = bytes_to_w32(msg:byte(offset, offset + 3))
        end
        for i = 16, 79 do
            W[i] = w32_rot(1, w32_xor_n(W[i-3] or 0, W[i-8] or 0, W[i-14] or 0, W[i-16] or 0))
        end
        local A, B, C, D, E = H0, H1, H2, H3, H4
        for i = 0, 79 do
            local f, k
            if i <= 19 then
                f = w32_or(w32_and(B, C), w32_and(w32_not(B), D))
                k = 0x5A827999
            elseif i <= 39 then
                f = w32_xor_n(B, C, D)
                k = 0x6ED9EBA1
            elseif i <= 59 then
                f = w32_or(w32_or(w32_and(B, C), w32_and(B, D)), w32_and(C, D))
                k = 0x8F1BBCDC
            else
                f = w32_xor_n(B, C, D)
                k = 0xCA62C1D6
            end
            local temp = (w32_rot(5, A) + f + E + k + (W[i] or 0)) % 4294967296
            E = D
            D = C
            C = w32_rot(30, B)
            B = A
            A = temp
        end
        H0 = (H0 + A) % 4294967296
        H1 = (H1 + B) % 4294967296
        H2 = (H2 + C) % 4294967296
        H3 = (H3 + D) % 4294967296
        H4 = (H4 + E) % 4294967296
    end
    local result = ""
    for _, h in ipairs({H0, H1, H2, H3, H4}) do
        local a, b, c, d = w32_to_bytes(h)
        result = result .. string.char(a, b, c, d)
    end
    return result
end

function JsonEncode(tbl)
    local result = "{"
    local first = true
    for k, v in pairs(tbl) do
        if not first then result = result .. "," end
        first = false
        result = result .. '"' .. JsonEscape(tostring(k)) .. '":'
        if type(v) == "string" then result = result .. '"' .. JsonEscape(v) .. '"'
        elseif type(v) == "number" then result = result .. tostring(v)
        elseif type(v) == "boolean" then result = result .. (v and "true" or "false")
        else result = result .. '"' .. JsonEscape(tostring(v)) .. '"'
        end
    end
    result = result .. "}"
    return result
end

function JsonEscape(value)
    value = tostring(value or "")
    local result = ""
    for i = 1, #value do
        local c = value:sub(i, i)
        local byte = c:byte()
        if c == "\\" then result = result .. "\\\\"
        elseif c == '"' then result = result .. '\\"'
        elseif byte == 8 then result = result .. "\\b"
        elseif byte == 12 then result = result .. "\\f"
        elseif byte == 10 then result = result .. "\\n"
        elseif byte == 13 then result = result .. "\\r"
        elseif byte == 9 then result = result .. "\\t"
        elseif byte and byte < 32 then result = result .. string.format("\\u%04X", byte)
        else result = result .. c
        end
    end
    return result
end

function JsonUnescape(value)
    value = tostring(value or "")
    local result = ""
    local i = 1
    while i <= #value do
        local c = value:sub(i, i)
        if c == "\\" then
            local esc = value:sub(i + 1, i + 1)
            if esc == "u" then
                local hex = value:sub(i + 2, i + 5)
                if hex:match("^%x%x%x%x$") then
                    local code = tonumber(hex, 16) or 0
                    result = result .. (code < 128 and string.char(code) or "?")
                    i = i + 6
                else
                    result = result .. esc
                    i = i + 2
                end
            elseif esc == "\\" then result = result .. "\\"; i = i + 2
            elseif esc == '"' then result = result .. '"'; i = i + 2
            elseif esc == "/" then result = result .. "/"; i = i + 2
            elseif esc == "b" then result = result .. "\b"; i = i + 2
            elseif esc == "f" then result = result .. "\f"; i = i + 2
            elseif esc == "n" then result = result .. "\n"; i = i + 2
            elseif esc == "r" then result = result .. "\r"; i = i + 2
            elseif esc == "t" then result = result .. "\t"; i = i + 2
            else result = result .. esc; i = i + 2
            end
        else
            result = result .. c
            i = i + 1
        end
    end
    return result
end

function ParseJsonString(str, index)
    if str:sub(index, index) ~= '"' then return nil, index end
    local value = ""
    local i = index + 1
    while i <= #str do
        local c = str:sub(i, i)
        if c == '"' then
            return JsonUnescape(value), i + 1
        elseif c == "\\" then
            value = value .. str:sub(i, i + 1)
            i = i + 2
        else
            value = value .. c
            i = i + 1
        end
    end
    return nil, index
end

function JsonDecode(str)
    if not str then return {} end
    -- Minimal flat-object parser for known Proflame payloads. It supports
    -- string keys with string, integer, boolean, and null values. Nested
    -- arrays/objects are intentionally unsupported and ignored safely.
    local result = {}
    local i = 1
    while i <= #str do
        local key
        key, i = ParseJsonString(str, i)
        if key then
            i = str:match("^%s*:%s*()", i) or i
            local value
            if str:sub(i, i) == '"' then
                value, i = ParseJsonString(str, i)
            else
                local raw, nextIndex = str:match("^([^,%}%]]+)%s*()", i)
                if raw then
                    i = nextIndex
                    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    if raw:match("^-?%d+$") then value = raw
                    elseif raw == "true" then value = "true"
                    elseif raw == "false" then value = "false"
                    elseif raw == "null" then value = nil
                    else
                        dbg_all("Ignoring unsupported JSON value for key " .. tostring(key) .. ": " .. tostring(raw))
                    end
                else
                    dbg_all("Ignoring malformed JSON value for key " .. tostring(key))
                    i = i + 1
                end
            end
            if value ~= nil then result[key] = value end
        else
            i = i + 1
        end
    end
    return result
end

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

function BuildSetControlCommand(control, value)
    return '{"command":"set_control","name":"' .. JsonEscape(control) .. '","value":"' .. JsonEscape(value) .. '"}'
end

function BuildLegacyIndexedCommand(control, value)
    return '{"control0":"' .. JsonEscape(control) .. '","value0":"' .. JsonEscape(value) .. '"}'
end

function DecodeTemperature(encoded)
    local temp = tonumber(encoded) or 700
    return math.floor(temp / 10)
end

function EncodeTemperature(tempF)
    return tostring(tempF * 10)
end

function FahrenheitToCelsius(f)
    local c = (f - 32) * 5 / 9
    return math.floor(c * 10 + 0.5) / 10
end

function CelsiusToFahrenheit(c)
    local f = (c * 9 / 5) + 32
    return math.floor(f + 0.5)
end

function GetModeString(mode)
    if mode == MODE_OFF then return "Off"
    elseif mode == MODE_STANDBY then return "Standby"
    elseif mode == MODE_MANUAL then return "Manual"
    elseif mode == MODE_SMART then return "Smart"
    elseif mode == MODE_ECO then return "Eco"
    else return "Unknown (" .. tostring(mode) .. ")"
    end
end

function GetDefaultOnMode()
    local defaultMode = Properties["Default On Mode"] or "Manual"
    if defaultMode == "Smart (Thermostat)" then
        return MODE_SMART
    elseif defaultMode == "Eco" then
        return MODE_ECO
    else
        return MODE_MANUAL
    end
end

function GetDefaultFlameLevel()
    return ClampNumber(Properties["Default Flame Level"], 1, 6, DEFAULT_FLAME_LEVEL)
end

function GetDefaultTimerMinutes()
    return ClampNumber(Properties["Default Timer (minutes)"], 0, 480, DEFAULT_TIMER_MINUTES)
end

function GenerateRandomBytes(count)
    local bytes = ""
    for i = 1, count do
        bytes = bytes .. string.char(math.random(0, 255))
    end
    return bytes
end

-- =============================================================================
-- EXTRAS (FLAME CONTROL IN THERMOSTAT UI)
-- =============================================================================

function GetExtrasXML()
    -- Get current values
    local flame = tonumber(gState.flame_control) or 0
    local fan = tonumber(gState.fan_control) or 0
    local light = tonumber(gState.lamp_control) or 0
    -- Convert timer from milliseconds to minutes for display
    -- Use timer_count (remaining time) not timer_set (original setting)
    -- But if fireplace is off, show timer as 0 regardless of device's timer_count
    local timerMs = tonumber(gState.timer_count) or 0
    local timerStatus = tonumber(gState.timer_status) or 0
    local mode = gState.main_mode or MODE_OFF
    local timerMinutes

    -- Use ceil when timer is active so we show at least 1m until it truly expires
    if timerStatus == 1 and timerMs > 0 then
        timerMinutes = math.ceil(timerMs / 60000)
    else
        timerMinutes = math.floor(timerMs / 60000)
    end

    -- Only force timer to 0 if fireplace is off/standby AND timer is not active
    -- This prevents showing 0 during startup when we're setting a timer
    if (mode == MODE_OFF or mode == MODE_STANDBY) and timerStatus ~= 1 then
        timerMinutes = 0
    end

    -- Format timer label as hours and minutes (e.g., "1h30m" or "45m")
    local timerLabel
    if timerMinutes <= 0 then
        timerLabel = "Off"
    elseif timerMinutes >= 60 then
        local hours = math.floor(timerMinutes / 60)
        local mins = timerMinutes % 60
        if mins > 0 then
            timerLabel = string.format("%dh%dm", hours, mins)
        else
            timerLabel = string.format("%dh", hours)
        end
    else
        timerLabel = string.format("%dm", timerMinutes)
    end
    
    -- Determine current mode
    local mode = gState.main_mode or MODE_OFF
    local modeValue = "off"
    if mode == MODE_MANUAL then
        modeValue = "manual"
    elseif mode == MODE_SMART then
        modeValue = "smart"
    elseif mode == MODE_ECO then
        modeValue = "eco"
    end
    
    -- Build mode items with current mode first (this is how Ecobee does it)
    local modeItems = ""
    if modeValue == "off" then
        modeItems = '<item text="Off" value="off"/><item text="Manual" value="manual"/><item text="Smart Thermostat" value="smart"/><item text="Eco" value="eco"/>'
    elseif modeValue == "manual" then
        modeItems = '<item text="Manual" value="manual"/><item text="Off" value="off"/><item text="Smart Thermostat" value="smart"/><item text="Eco" value="eco"/>'
    elseif modeValue == "smart" then
        modeItems = '<item text="Smart Thermostat" value="smart"/><item text="Off" value="off"/><item text="Manual" value="manual"/><item text="Eco" value="eco"/>'
    else
        modeItems = '<item text="Eco" value="eco"/><item text="Off" value="off"/><item text="Manual" value="manual"/><item text="Smart Thermostat" value="smart"/>'
    end
    
    -- XML structure matching working Ecobee thermostat format - include value attributes for sliders
    local xml = 
    '<extras_setup>' ..
      '<extra>' ..
        '<section label="Operating Mode">' ..
          '<object type="list" id="pf_mode" label="Mode" command="SELECT_MODE">' ..
            '<list maxselections="1" minselections="1">' ..
              modeItems ..
            '</list>' ..
          '</object>' ..
        '</section>' ..
        '<section label="Fireplace Controls">' ..
          '<object type="slider" id="pf_flame" label="Flame Level" command="SET_FLAME_LEVEL" min="1" max="6" value="' .. flame .. '"/>' ..
          '<object type="slider" id="pf_fan" label="Fan Speed" command="SET_FAN_LEVEL" min="0" max="6" value="' .. fan .. '"/>' ..
          '<object type="slider" id="pf_light" label="Downlight" command="SET_LIGHT_LEVEL" min="0" max="6" value="' .. light .. '"/>' ..
        '</section>' ..
        '<section label="Auto-Off Timer">' ..
          '<object type="slider" id="pf_timer" label="Timer (' .. timerLabel .. ')" command="SET_TIMER_MINUTES" min="0" max="360" value="' .. timerMinutes .. '"/>' ..
        '</section>' ..
      '</extra>' ..
    '</extras_setup>'
    return xml
end

function SetupExtras()
    dbg_all("Sending extras setup via DataToUI")
    local xml = GetExtrasXML()
    dbg_all("Extras XML: " .. xml)
    -- Send via DataToUI (this is the primary method that works)
    C4:SendDataToUI(xml)
    -- Also send via proxy notification
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "EXTRAS_SETUP_CHANGED", {XML = xml})
end

function UpdateExtrasState()
    -- Since values are embedded in extras_setup XML, resend the setup
    -- But throttle to avoid spamming during initialization
    if gExtrasThrottle then return end
    gExtrasThrottle = true
    C4:SetTimer(500, function() 
        gExtrasThrottle = false 
        SetupExtras()
    end, false)
end

-- Separate function for timer updates - always sends immediately
function UpdateTimerExtras()
    dbg_err("Updating timer extras (minutes changed)")
    SetupExtras()
end

-- =============================================================================
-- TIMERS
-- =============================================================================

function OnPingTimer()
    if gConnected and gHandshakeComplete then SendPing() end
end

function OnReconnectTimer()
    gReconnectTimerId = nil
    if not gConnected and not gConnecting then
        dbg_err("Reconnect timer fired")
        Connect()
    end
end

function StartPingTimer()
    StopPingTimer()
    local interval = (tonumber(Properties["Ping Interval (seconds)"]) or 5) * 1000
    gPingTimerId = C4:SetTimer(interval, function(timer) OnPingTimer() end, true)
end

function StopPingTimer()
    if gPingTimerId then
        gPingTimerId:Cancel()
        gPingTimerId = nil
    end
end

function ScheduleReconnect()
    StopReconnectTimer()
    local delay = (tonumber(Properties["Reconnect Delay (seconds)"]) or 10) * 1000
    gReconnectTimerId = C4:SetTimer(delay, function(timer) OnReconnectTimer() end, false)
end

function StopReconnectTimer()
    if gReconnectTimerId then
        gReconnectTimerId:Cancel()
        gReconnectTimerId = nil
    end
end

-- =============================================================================
-- WEBSOCKET
-- =============================================================================

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

function ParseHttpHeaders(response)
    local headers = {}
    for line in tostring(response or ""):gmatch("([^\r\n]+)") do
        local name, value = line:match("^%s*([^:%s]+)%s*:%s*(.-)%s*$")
        if name and value then
            headers[name:lower()] = value
        end
    end
    return headers
end

function ExpectedWebSocketAccept(key)
    if not key or key == "" then return nil end
    local guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return Base64Encode(SHA1(key .. guid))
end

function IsStrictWebSocketHandshakeEnabled()
    return Properties["Strict WebSocket Handshake"] == "On"
end

function AllowLenientHandshakeFallback(response, reason)
    if IsStrictWebSocketHandshakeEnabled() then
        return false
    end
    if response and response:find("101", 1, true) then
        dbg_err("Handshake strict validation failed (" .. tostring(reason) .. "); accepting legacy 101 response because Strict WebSocket Handshake is Off")
        return true
    end
    return false
end

function ValidateHandshakeResponse(response)
    if not response then
        dbg_err("Handshake failed: empty response")
        return false
    end

    local statusLine = response:match("^([^\r\n]+)")
    if not statusLine or not statusLine:match("^HTTP/%d+%.%d+%s+101%s") then
        local reason = "invalid status line: " .. tostring(statusLine)
        dbg_err("Handshake failed: " .. reason)
        return AllowLenientHandshakeFallback(response, reason)
    end

    local headers = ParseHttpHeaders(response)
    local upgrade = (headers["upgrade"] or ""):lower()
    local connection = (headers["connection"] or ""):lower()
    if upgrade ~= "websocket" then
        local reason = "missing Upgrade websocket header"
        dbg_err("Handshake failed: " .. reason)
        return AllowLenientHandshakeFallback(response, reason)
    end
    if not connection:find("upgrade", 1, true) then
        local reason = "missing Connection upgrade header"
        dbg_err("Handshake failed: " .. reason)
        return AllowLenientHandshakeFallback(response, reason)
    end

    local expectedAccept = ExpectedWebSocketAccept(gWebSocketKey)
    local actualAccept = headers["sec-websocket-accept"]
    if not expectedAccept or actualAccept ~= expectedAccept then
        local reason = "invalid Sec-WebSocket-Accept"
        dbg_err("Handshake failed: " .. reason)
        return AllowLenientHandshakeFallback(response, reason)
    end

    return true
end

function CreateWebSocketFrame(data, opcode)
    opcode = opcode or 0x01
    local frame = ""
    frame = frame .. string.char(bit.bor(0x80, opcode))
    local mask = GenerateRandomBytes(4)
    local len = #data
    if len <= 125 then
        frame = frame .. string.char(bit.bor(0x80, len))
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
    for i = 1, #data do
        local byte = data:byte(i)
        local maskByte = mask:byte(((i - 1) % 4) + 1)
        frame = frame .. string.char(bit.bxor(byte, maskByte))
    end
    return frame
end

function ParseWebSocketFrame(data)
    if not data or #data < 2 then return nil, nil, data or "" end
    local byte1 = data:byte(1)
    local byte2 = data:byte(2)
    local fin = bit.band(byte1, 0x80) ~= 0
    local rsv = bit.band(byte1, 0x70)
    local opcode = bit.band(byte1, 0x0F)
    if rsv ~= 0 then
        dbg_err("Unsupported WebSocket frame: RSV bits set")
        return false, nil, ""
    end
    if not fin then
        dbg_err("Unsupported fragmented WebSocket frame")
        return false, nil, ""
    end
    local masked = bit.band(byte2, 0x80) ~= 0
    local payloadLen = bit.band(byte2, 0x7F)
    local headerLen = 2
    if payloadLen == 126 then
        if #data < 4 then return nil, nil, data end
        payloadLen = data:byte(3) * 256 + data:byte(4)
        headerLen = 4
    elseif payloadLen == 127 then
        if #data < 10 then return nil, nil, data end
        payloadLen = 0
        for i = 3, 10 do
            payloadLen = payloadLen * 256 + data:byte(i)
        end
        headerLen = 10
    end
    local maskLen = masked and 4 or 0
    local totalLen = headerLen + maskLen + payloadLen
    if #data < totalLen then return nil, nil, data end
    local payload = ""
    if masked then
        local mask = data:sub(headerLen + 1, headerLen + 4)
        local masked_data = data:sub(headerLen + 5, headerLen + 4 + payloadLen)
        for i = 1, #masked_data do
            local byte = masked_data:byte(i)
            local maskByte = mask:byte(((i - 1) % 4) + 1)
            payload = payload .. string.char(bit.bxor(byte, maskByte))
        end
    else
        payload = data:sub(headerLen + 1, headerLen + payloadLen)
    end
    local remaining = data:sub(totalLen + 1)
    return opcode, payload, remaining
end

-- =============================================================================
-- NETWORK
-- =============================================================================

function Connect()
    if gConnected or gConnecting then return end
    local ipAddress = Properties["IP Address"]
    local port = tonumber(Properties["Port"]) or 88
    if not ipAddress or ipAddress == "" then
        C4:UpdateProperty("Connection Status", "Not Configured")
        return
    end
    gConnecting = true
    gHandshakeComplete = false
    gReceiveBuffer = ""
    C4:UpdateProperty("Connection Status", "Connecting...")
    C4:CreateNetworkConnection(NETWORK_BINDING_ID, ipAddress)
    C4:NetConnect(NETWORK_BINDING_ID, port)
end

function Disconnect()
    StopPingTimer()
    CancelPendingTimerCommandTimers()
    if gSuppressTimerUpdates then
        SetTimerSuppression(false, "disconnect")
    end
    local port = tonumber(Properties["Port"]) or 88
    if gConnected then
        pcall(function() C4:NetDisconnect(NETWORK_BINDING_ID, port) end)
    end
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gStatusSeen = {}
    gReceiveBuffer = ""
    HandleConnectionEvent(false)
    C4:UpdateProperty("Connection Status", "Disconnected")
end

function Reconnect()
    Disconnect()
    ScheduleReconnect()
end

function SendWebSocketMessage(message)
    if not gConnected or not gHandshakeComplete then return false end
    local frame = CreateWebSocketFrame(message, 0x01)
    local port = tonumber(Properties["Port"]) or 88
    C4:SendToNetwork(NETWORK_BINDING_ID, port, frame)
    return true
end

function SendPing()
    SendWebSocketMessage("PROFLAMEPING")
end

function SendPong(payload)
    if not gConnected or not gHandshakeComplete then return false end
    local frame = CreateWebSocketFrame(payload or "", 0x0A)
    local port = tonumber(Properties["Port"]) or 88
    C4:SendToNetwork(NETWORK_BINDING_ID, port, frame)
    return true
end

function SendDeviceControl(control, value)
    if not gConnected or not gHandshakeComplete then
        dbg_err("Refusing device command while disconnected or handshaking: " .. tostring(control) .. "=" .. tostring(value))
        return false
    end
    local cmd = BuildSetControlCommand(control, value)
    dbg_err("Sending command: " .. cmd)
    local sentPrimary = SendWebSocketMessage(cmd)
    local legacyCmd = BuildLegacyIndexedCommand(control, value)
    dbg_err("Sending legacy command fallback: " .. legacyCmd)
    local sentLegacy = SendWebSocketMessage(legacyCmd)
    return sentPrimary or sentLegacy
end

function RequestAllStatus()
    -- The Proflame device requires PROFLAMECONNECTION to trigger full status dump
    -- This is similar to PROFLAMEPING/PROFLAMEPONG but for initial connection
    dbg_err("Sending PROFLAMECONNECTION to request full status")
    SendWebSocketMessage("PROFLAMECONNECTION")
end

function UpdateAllProxies()
    -- Send allowed modes first
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "ALLOWED_FAN_MODES_CHANGED", { MODES = "Off,Low,Medium,High" })
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off,Heat" })
    
    UpdateThermostatProxy()
    UpdateThermostatSetpoint()
    UpdateRoomTemperature()
    UpdateFanMode()
    UpdateFlameLevel()
    UpdatePresetMode()
    UpdateExtrasState()
    
    -- Also send extras setup when proxies update
    SetupExtras()
end

function UpdateRoomTemperatureProperty()
    local tempEncoded = gState.room_temperature or "700"
    local tempF = DecodeTemperature(tempEncoded)
    C4:UpdateProperty("Room Temperature", tostring(tempF) .. "F")
end

function UpdateRoomTemperatureProxy()
    local tempEncoded = gState.room_temperature or "700"
    local tempF = DecodeTemperature(tempEncoded)
    local tempC = FahrenheitToCelsius(tempF)
    dbg_err("Sending room temperature to proxy: " .. tempF .. "F (" .. tempC .. "C)")
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})
end

function UpdateRoomTemperature()
    UpdateRoomTemperatureProperty()
    UpdateRoomTemperatureProxy()
end

-- =============================================================================
-- SETPOINT PENDING LOGIC (Anti-Jump)
-- =============================================================================

function SetPendingSetpoint(tempF)
    gPendingSetpointF = tempF
    dbg_err("SetPendingSetpoint locked: " .. tostring(tempF))
    if gPendingTimer then gPendingTimer:Cancel() end
    gPendingTimer = C4:SetTimer(5000, function()
        dbg_err("Pending setpoint timer expired, unlocking")
        gPendingSetpointF = nil
    end, false)
end

-- =============================================================================
-- STATUS PARSING
-- =============================================================================

function ParseStatusMessage(data)
    if not data then return end
    if data == "PROFLAMEPONG" then
        C4:UpdateProperty("Last Ping Response", os.date("%Y-%m-%d %H:%M:%S"))
        return
    end
    if data == "PROFLAMECONNECTIONOPEN" then
        dbg_err("Connection acknowledged by device")
        C4:UpdateProperty("Connection Status", "Connected")
        HandleConnectionEvent(true)
        return
    end
    if data:sub(1, 1) == "{" then
        dbg_err("Received JSON: " .. data:sub(1, 200))
        local json = JsonDecode(data)
        
        -- First try indexed format (status0/value0, status1/value1, etc.)
        local i = 0
        local foundIndexed = false
        while true do
            local status = json["status" .. i]
            local value = json["value" .. i]
            if not status then break end
            foundIndexed = true
            ProcessStatusUpdate(status, value)
            i = i + 1
        end
        
        -- Also handle direct key-value format from device status response
        -- Map device field names to our internal names
        local fieldMap = {
            temperature_read = "room_temperature",
            timer_read = "timer_count"
        }
        
        for key, value in pairs(json) do
            -- Skip indexed fields we already processed
            if not key:match("^status%d+$") and not key:match("^value%d+$") then
                -- Map field name if needed
                local mappedKey = fieldMap[key] or key
                if gState[mappedKey] ~= nil or key == "temperature_read" or key == "rssi" then
                    if key == "rssi" then
                        ProcessStatusUpdate("wifi_signal_str", value)
                    else
                        ProcessStatusUpdate(mappedKey, value)
                    end
                else
                    dbg_all("Ignoring unsupported JSON status key: " .. tostring(key))
                end
            end
        end
    end
end

-- Returns a change table consumed by property/proxy/event/Extras adapters.
-- Required fields: status, value. Optional fields: timerCleared,
-- timerExpired, timerExtras, newCount.
function ApplyDeviceStatus(status, value)
    if status == "temperature_set" then
        local incomingF = DecodeTemperature(value)
        if gPendingSetpointF ~= nil then
            if math.abs(incomingF - gPendingSetpointF) < 1 then
                dbg_err("Pending setpoint confirmed: " .. incomingF)
                gPendingSetpointF = nil
            else
                dbg_err("Ignoring stale setpoint: " .. incomingF)
                return
            end
        end
    end

    if status == "main_mode" then
        gState.main_mode = value
        if (value == MODE_OFF or value == MODE_STANDBY) and not gSuppressTimerUpdates then
            gState.timer_set = "0"
            gState.timer_count = "0"
            return { status = status, value = value, timerCleared = true, timerExtras = true }
        end
        return { status = status, value = value }
    elseif status == "timer_status" then
        -- Skip timer_status updates while we're actively setting the timer
        if gSuppressTimerUpdates then
            dbg_err("Timer status update suppressed: " .. tostring(value))
            return
        end
        gState.timer_status = value
        -- If timer becomes active, clear the expired flag
        if value == "1" then
            gTimerExpired = false
        end
        -- If timer is turned off by device, clear remaining time and reset slider
        if value == "0" then
            gState.timer_set = "0"
            gState.timer_count = "0"
            gTimerExpired = true  -- Also set expired flag to ignore any stale timer_count updates
            return { status = status, value = value, timerCleared = true, timerExtras = true }
        end
        return { status = status, value = value }
    elseif status == "timer_set" then
        -- Don't update gState.timer_set from device responses
        -- We only set timer_set from our own commands to avoid sync issues
        -- Just log the device's reported value for debugging
        local minutes = math.floor(tonumber(value) / 60000)
        dbg_err("Device timer_set: " .. tostring(value) .. " ms (" .. minutes .. " minutes), our timer_set: " .. tostring(gState.timer_set))
        return
    elseif status == "timer_count" then
        -- Skip timer_count updates while we're actively setting the timer
        if gSuppressTimerUpdates then
            dbg_err("Timer count update suppressed: " .. tostring(value))
            return
        end

        -- Ignore timer_count updates when timer has expired (device sends default values)
        if gTimerExpired then
            dbg_err("Timer count ignored (timer expired): " .. tostring(value))
            return
        end

        -- Ignore timer_count updates when fireplace is off/standby or timer is disabled
        -- The device sends default timer values when entering standby which we should ignore
        local mode = gState.main_mode
        if mode == MODE_OFF or mode == MODE_STANDBY then
            dbg_err("Timer count ignored (mode=" .. tostring(mode) .. "): " .. tostring(value))
            return
        end
        if gState.timer_status == "0" then
            dbg_err("Timer count ignored (timer_status=0): " .. tostring(value))
            return
        end

        local newCount = tonumber(value) or 0
        local newMinutes = math.floor(newCount / 60000)

        -- Get old minutes from timer_count (for detecting minute changes)
        local oldCount = tonumber(gState.timer_count) or 0
        local oldMinutes = math.floor(oldCount / 60000)

        -- Detect timer expiry: count reaches 0
        if newCount == 0 and oldCount > 0 then
            dbg_err("Timer expired (count reached 0)")
            gTimerExpired = true
            gState.timer_count = "0"
            gState.timer_set = "0"
            return { status = status, value = value, timerExpired = true, timerExtras = true }
        end

        -- Store the raw count
        gState.timer_count = value
        local change = { status = status, value = value, newCount = newCount }
        dbg_err("Timer count: " .. newCount .. "ms (" .. newMinutes .. "m), old count: " .. oldCount .. "ms (" .. oldMinutes .. "m)")
        if oldMinutes ~= newMinutes then
            dbg_err("Timer minute changed: " .. oldMinutes .. " -> " .. newMinutes .. ", updating slider")
            -- Update timer_set to match for slider display
            gState.timer_set = tostring(newMinutes * 60000)
            change.timerExtras = true
        end
        return change
    elseif status == "room_temperature" or status == "temperature_read" then
        gState.room_temperature = value
        dbg_err("Room temperature updated: " .. value .. " (raw) = " .. DecodeTemperature(value) .. "F")
        return { status = "room_temperature", value = value }
    end

    if gState[status] ~= nil then
        gState[status] = value
        return { status = status, value = value }
    end
    return nil
end

function FormatTimerRemaining(timerMs)
    local newCount = tonumber(timerMs) or 0
    local totalSeconds = math.floor(newCount / 1000)
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    local seconds = totalSeconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    elseif newCount > 0 then
        return string.format("%d:%02d", minutes, seconds)
    end
    return "Off"
end

function UpdatePropertiesForStatus(change)
    local status = change.status
    local value = change.value

    if status == "main_mode" then
        C4:UpdateProperty("Operating Mode", GetModeString(value))
        if change.timerCleared then
            C4:UpdateProperty("Timer Remaining", "Off")
        end
    elseif status == "flame_control" then
        C4:UpdateProperty("Flame Level", tostring(value))
    elseif status == "fan_control" then
        C4:UpdateProperty("Fan Level", tostring(value))
    elseif status == "lamp_control" then
        C4:UpdateProperty("Light Level", tostring(value))
    elseif status == "temperature_set" then
        C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(value) .. "F")
    elseif status == "room_temperature" then
        UpdateRoomTemperatureProperty()
    elseif status == "thermo_control" then
        C4:UpdateProperty("Thermostat Enabled", value == "1" and "Yes" or "No")
    elseif status == "pilot_control" then
        C4:UpdateProperty("Pilot Status", value == "1" and "On" or "Off")
    elseif status == "aux_control" then
        C4:UpdateProperty("Aux Output", value == "1" and "On" or "Off")
    elseif status == "split_control" then
        C4:UpdateProperty("Front Flame (Split)", value == "1" and "On" or "Off")
    elseif status == "wifi_signal_str" then
        C4:UpdateProperty("WiFi Signal Strength", "-" .. tostring(value) .. " dBm")
    elseif status == "timer_status" then
        C4:UpdateProperty("Timer Active", value == "1" and "Yes" or "No")
        if change.timerCleared then
            C4:UpdateProperty("Timer Remaining", "Off")
        end
    elseif status == "timer_count" then
        if change.timerExpired then
            C4:UpdateProperty("Timer Remaining", "Off")
        else
            C4:UpdateProperty("Timer Remaining", FormatTimerRemaining(change.newCount))
        end
    elseif status == "burner_status" then
        local num = tonumber(value) or 0
        if num < 0 then num = num + 0x10000 end  -- Convert to unsigned 16-bit
        C4:UpdateProperty("Burner Status", string.format("0x%04X", num))
    end
end

function UpdateProxyForStatus(change)
    local status = change.status
    local value = change.value

    if status == "main_mode" then
        UpdateThermostatProxy(value)
        UpdatePresetMode(value)
    elseif status == "flame_control" then
        UpdateFlameLevel()
        UpdateHoldModeFromFlame()
    elseif status == "fan_control" then
        UpdateFanMode()
    elseif status == "temperature_set" then
        UpdateThermostatSetpoint()
    elseif status == "room_temperature" then
        UpdateRoomTemperatureProxy()
    end
end

function FireEventsForStatus(change)
    if change.status == "main_mode" then
        HandleModeEvents(change.value)
    end
end

function StatusAffectsExtras(status)
    return status == "main_mode" or
        status == "flame_control" or
        status == "fan_control" or
        status == "lamp_control" or
        status == "timer_status"
end

function ScheduleExtrasRefresh(reason, timerOnly)
    dbg_all("Extras refresh requested: " .. tostring(reason))
    if timerOnly then
        UpdateTimerExtras()
    else
        UpdateExtrasState()
    end
end

function ProcessStatusUpdate(status, value)
    if not status or not value then return end

    dbg_err("ProcessStatusUpdate: " .. tostring(status) .. " = " .. tostring(value))
    local change = ApplyDeviceStatus(status, value)
    if not change then return end
    gStatusSeen[change.status] = true

    UpdatePropertiesForStatus(change)
    UpdateProxyForStatus(change)
    FireEventsForStatus(change)
    if change.timerExtras then
        ScheduleExtrasRefresh("status:" .. tostring(change.status), true)
    elseif StatusAffectsExtras(change.status) then
        ScheduleExtrasRefresh("status:" .. tostring(change.status), false)
    end
end

-- =============================================================================
-- PROXY UPDATES
-- =============================================================================

function UpdateThermostatProxy(modeOverride)
    local mode = modeOverride or gState.main_mode
    local hvacMode = "Off"
    local hvacState = "Off"
    if mode == MODE_MANUAL or mode == MODE_SMART or mode == MODE_ECO then
        hvacMode = "Heat"
        hvacState = "Heat"
    end
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "HVAC_MODE_CHANGED", { MODE = hvacMode })
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "HVAC_STATE_CHANGED", { STATE = hvacState })
end

function UpdateThermostatSetpoint()
    local tempEncoded = gState.temperature_set or "700"
    local tempF = DecodeTemperature(tempEncoded)
    local tempC = FahrenheitToCelsius(tempF)
    
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "HEAT_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "SINGLE_SETPOINT_CHANGED", {SETPOINT = tempC, SCALE = "C"})
end

function UpdateFanMode()
    local levelNum = tonumber(gState.fan_control) or 0
    local fanMode = "Off"
    -- Map 0-6 levels to Off/Low/Medium/High
    if levelNum == 0 then
        fanMode = "Off"
    elseif levelNum <= 2 then
        fanMode = "Low"
    elseif levelNum <= 4 then
        fanMode = "Medium"
    else
        fanMode = "High"
    end
    dbg_err("Fan mode updated: level " .. levelNum .. " = " .. fanMode)
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "FAN_MODE_CHANGED", { MODE = fanMode })
end

function UpdateFlameLevel()
    local flameLevel = tonumber(gState.flame_control) or 0
    local percent = math.floor(flameLevel / 6 * 100)
    local isOn = (flameLevel > 0) and (gState.main_mode ~= MODE_OFF and gState.main_mode ~= MODE_STANDBY)
    dbg_err("Flame level updated: " .. flameLevel .. " = " .. percent .. "%, on=" .. tostring(isOn))
end

function UpdateHoldModeFromFlame()
    -- Update hold mode to reflect current flame level
    local flameLevel = tonumber(gState.flame_control) or 0
    local holdMode = "Low Flame"
    if flameLevel <= 2 then
        holdMode = "Low Flame"
    elseif flameLevel <= 4 then
        holdMode = "Medium Flame"
    else
        holdMode = "High Flame"
    end
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = holdMode })
    dbg_err("Hold mode updated to: " .. holdMode .. " (flame level " .. flameLevel .. ")")
end

function UpdatePresetMode(modeOverride)
    local mode = modeOverride or gState.main_mode
    local preset = ""
    if mode == MODE_MANUAL then
        preset = "Manual"
    elseif mode == MODE_SMART then
        preset = "Smart"
    elseif mode == MODE_ECO then
        preset = "Eco"
    end
    if preset ~= "" then
        dbg_err("Updating preset mode to: " .. preset)
        -- Send PRESET_CHANGED for standard preset update
        C4:SendToProxy(THERMOSTAT_PROXY_ID, "PRESET_CHANGED", { PRESET = preset })
        -- Also send PRESET_MODE_CHANGED for newer proxy versions
        C4:SendToProxy(THERMOSTAT_PROXY_ID, "PRESET_MODE_CHANGED", { MODE = preset })
    end
end

-- =============================================================================
-- PROPERTY HANDLER
-- =============================================================================

function OnPropertyChanged(strProperty)
    dbg_err("OnPropertyChanged: " .. tostring(strProperty))
    if strProperty == "IP Address" then 
        dbg_err("IP Address changed, disconnecting and reconnecting...")
        Disconnect()
        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            -- Small delay to ensure clean disconnect before reconnect
            C4:SetTimer(500, function() Connect() end, false)
        else
            C4:UpdateProperty("Connection Status", "Not Configured")
        end
    elseif strProperty == "Port" then
        dbg_err("Port changed, disconnecting and reconnecting...")
        Disconnect()
        C4:SetTimer(500, function() Connect() end, false)
    elseif strProperty == "Strict WebSocket Handshake" then
        dbg_err("Strict WebSocket Handshake changed, reconnecting to verify handshake mode...")
        Disconnect()
        if (Properties["IP Address"] or "") ~= "" then
            C4:SetTimer(500, function() Connect() end, false)
        end
    elseif strProperty == "Debug Mode" then
        gDebugEnabled = (Properties["Debug Mode"] == "On")
    elseif strProperty == "Debug Level" then
        local level = Properties["Debug Level"]
        if level == "Error" then gDebugLevel = DEBUG_ERROR
        elseif level == "Warning" then gDebugLevel = DEBUG_WARN
        elseif level == "Info" then gDebugLevel = DEBUG_INFO
        elseif level == "Debug" then gDebugLevel = DEBUG_DEBUG
        elseif level == "Trace" then gDebugLevel = DEBUG_TRACE
        end
        dbg_err("Debug level set to: " .. tostring(gDebugLevel))
    elseif strProperty == "Ping Interval (seconds)" then
        if gConnected and gHandshakeComplete then
            StartPingTimer()  -- Restart with new interval
        end
    end
end

-- =============================================================================
-- NETWORK CALLBACKS
-- =============================================================================

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if idBinding ~= NETWORK_BINDING_ID then return end
    if strStatus == "ONLINE" then
        gConnected = true
        gConnecting = false
        local ipAddress = Properties["IP Address"]
        local port = tonumber(Properties["Port"]) or 88
        local handshake = BuildWebSocketHandshake(ipAddress, port)
        C4:SendToNetwork(NETWORK_BINDING_ID, port, handshake)
        C4:UpdateProperty("Connection Status", "Handshaking...")
    elseif strStatus == "OFFLINE" then
        gConnected = false
        gConnecting = false
        gHandshakeComplete = false
        StopPingTimer()
        HandleConnectionEvent(false)
        C4:UpdateProperty("Connection Status", "Disconnected")
        ScheduleReconnect()
    end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    if idBinding ~= NETWORK_BINDING_ID then return end
    gReceiveBuffer = gReceiveBuffer .. strData
    if not gHandshakeComplete then
        local headerEnd = gReceiveBuffer:find("\r\n\r\n")
        if headerEnd then
            local response = gReceiveBuffer:sub(1, headerEnd + 3)
            gReceiveBuffer = gReceiveBuffer:sub(headerEnd + 4)
            if ValidateHandshakeResponse(response) then
                gHandshakeComplete = true
                C4:UpdateProperty("Connection Status", "Connected")
                HandleConnectionEvent(true)
                StartPingTimer()
                RequestAllStatus()
                UpdateAllProxies()
                -- FORCE EXTRAS SETUP ON CONNECT
                SetupExtras()
            else
                Disconnect()
                ScheduleReconnect()
            end
        else
            return
        end
    end
    while #gReceiveBuffer > 0 do
        local opcode, payload, remaining = ParseWebSocketFrame(gReceiveBuffer)
        if opcode == nil then break end
        if opcode == false then
            Disconnect()
            ScheduleReconnect()
            break
        end
        gReceiveBuffer = remaining
        if opcode == 0x01 then
            ParseStatusMessage(payload)
        elseif opcode == 0x08 then
            dbg_err("WebSocket close frame received")
            Disconnect()
            ScheduleReconnect()
        elseif opcode == 0x09 then
            dbg_err("WebSocket ping frame received")
            SendPong(payload)
        elseif opcode == 0x0A then
            dbg_all("WebSocket pong frame received")
        else
            dbg_all("Ignoring unsupported WebSocket opcode: " .. tostring(opcode))
        end
    end
end

-- =============================================================================
-- COMMAND HELPERS
-- =============================================================================

function ClampNumber(value, minValue, maxValue, defaultValue)
    local num = tonumber(value)
    if num == nil then num = defaultValue end
    if num == nil then return nil end
    if minValue ~= nil and num < minValue then num = minValue end
    if maxValue ~= nil and num > maxValue then num = maxValue end
    return num
end

function GetCommandParam(tParams, ...)
    tParams = tParams or {}
    local names = {...}
    for i = 1, #names do
        local value = tParams[names[i]]
        if value ~= nil then return value end
    end
    return nil
end

function CancelPendingTimerCommandTimers()
    CancelPendingModeReadyWork()
    CancelPendingTimerStartWork()
    CancelTimerSuppressionClear()
end

function CancelPendingModeReadyWork()
    if gTimerModeDelayTimer then
        gTimerModeDelayTimer:Cancel()
        gTimerModeDelayTimer = nil
    end
end

function CancelPendingTimerStartWork()
    if gTimerStartDelayTimer then
        gTimerStartDelayTimer:Cancel()
        gTimerStartDelayTimer = nil
    end
end

function CancelTimerSuppressionClear()
    if gTimerSuppressClearTimer then
        gTimerSuppressClearTimer:Cancel()
        gTimerSuppressClearTimer = nil
    end
end

function SetTimerSuppression(enabled, reason)
    CancelTimerSuppressionClear()
    gSuppressTimerUpdates = enabled
    dbg_err("Timer suppression " .. (enabled and "enabled" or "disabled") .. ": " .. tostring(reason))
end

function IsDeviceCommandReady()
    return gConnected and gHandshakeComplete
end

function RequireDeviceCommandReady(action)
    if IsDeviceCommandReady() then return true end
    dbg_err("Command refused while device is disconnected or handshaking: " .. tostring(action))
    return false
end

function RequireConfirmedDeviceStatus(status, action)
    if not RequireDeviceCommandReady(action) then return false end
    if gStatusSeen[status] then return true end
    dbg_err("Command refused until device reports " .. tostring(status) .. ": " .. tostring(action))
    return false
end

function ScheduleTimerSuppressionClear()
    CancelTimerSuppressionClear()
    gTimerSuppressClearTimer = C4:SetTimer(2000, function(timer)
        gTimerSuppressClearTimer = nil
        SetTimerSuppression(false, "scheduled clear")
    end, false)
end

function ClearTimerStateAndSend(turnOff)
    if not RequireDeviceCommandReady(turnOff and "Turn Off" or "Cancel Timer") then return false end
    CancelPendingTimerCommandTimers()
    SetTimerSuppression(true, "clearing timer")
    local sent = SendDeviceControl("timer_status", "0")
    sent = SendDeviceControl("timer_set", "0") or sent
    if turnOff then
        sent = SendDeviceControl("main_mode", MODE_OFF) or sent
    end
    if not sent then
        SetTimerSuppression(false, "clear timer send failed")
        return false
    end
    gState.timer_set = "0"
    gState.timer_count = "0"
    gState.timer_status = "0"
    C4:UpdateProperty("Timer Remaining", "Off")
    UpdateTimerExtras()
    ScheduleTimerSuppressionClear()
    return true
end

function ArmTimerAfterDelay(updateTimerExtras)
    gTimerStartDelayTimer = C4:SetTimer(200, function(timer)
        gTimerStartDelayTimer = nil
        if SendDeviceControl("timer_status", "1") then
            ScheduleTimerSuppressionClear()
        else
            SetTimerSuppression(false, "timer start send failed")
        end
    end, false)

    if updateTimerExtras then
        UpdateTimerExtras()
    else
        UpdateExtrasState()
    end
end

function SetRequestedTimerState(minutes)
    -- Intentional optimistic timer UI state: the Extras timer slider should move
    -- immediately while device timer_count echoes are suppressed.
    local msValue = minutes * 60000
    gState.timer_set = tostring(msValue)
    gState.timer_count = tostring(msValue)
    gState.timer_status = "1"
    return msValue
end

function SetTimerValueAndArm(minutes, updateTimerExtras)
    if not RequireDeviceCommandReady("Set Timer") then return false end
    local msValue = minutes * 60000
    SetTimerSuppression(true, "setting timer")
    gTimerExpired = false
    if not SendDeviceControl("timer_set", tostring(msValue)) then
        SetTimerSuppression(false, "timer_set send failed")
        return false
    end
    SetRequestedTimerState(minutes)
    ArmTimerAfterDelay(updateTimerExtras)
    return true
end

function ScheduleModeReadyWork(callback)
    CancelPendingModeReadyWork()
    gTimerModeDelayTimer = C4:SetTimer(750, function(timer)
        gTimerModeDelayTimer = nil
        callback()
    end, false)
end

function SetRequestedExtrasControlState(control, value)
    -- Intentional optimistic Extras UI state: slider controls should not snap
    -- back while waiting for the device echo to confirm the write.
    if control == "flame_control" or control == "fan_control" or control == "lamp_control" then
        local valueString = tostring(value)
        gState[control] = valueString
        UpdatePropertiesForStatus({ status = control, value = valueString })
        ScheduleExtrasRefresh("optimistic:" .. control, false)
    end
end

function CommandSetMode(mode)
    if mode == MODE_OFF or mode == MODE_MANUAL or mode == MODE_SMART or mode == MODE_ECO then
        if not RequireDeviceCommandReady("Set Mode") then return false end
        CancelPendingModeReadyWork()
        return SendDeviceControl("main_mode", mode)
    end
    dbg_err("Invalid mode command value: " .. tostring(mode))
    return false
end

function CommandTurnOff()
    return ClearTimerStateAndSend(true)
end

function CommandTurnOn()
    if not RequireDeviceCommandReady("Turn On") then return false end
    CancelPendingTimerCommandTimers()
    if not SendDeviceControl("main_mode", GetDefaultOnMode()) then return false end
    local defaultFlame = GetDefaultFlameLevel()
    local defaultTimer = GetDefaultTimerMinutes()
    ScheduleModeReadyWork(function()
        if not RequireDeviceCommandReady("Turn On default flame") then return end
        if SendDeviceControl("flame_control", tostring(defaultFlame)) then
            SetRequestedExtrasControlState("flame_control", defaultFlame)
        end
        if defaultTimer and defaultTimer > 0 then
            SetTimerValueAndArm(defaultTimer, false)
        end
    end)
    -- If no timer will be armed, clear suppression now; no later callback will do it.
    if not defaultTimer or defaultTimer <= 0 then
        SetTimerSuppression(false, "turn on without default timer")
    end
    return true
end

function CommandSetFlame(level)
    if not RequireDeviceCommandReady("Set Flame Level") then return false end
    level = ClampNumber(level, 0, 6, nil)
    if level == nil then
        dbg_err("Set Flame Level missing or invalid Level parameter")
        return false
    end

    if gState.main_mode ~= MODE_MANUAL then
        if not SendDeviceControl("main_mode", MODE_MANUAL) then return false end
        ScheduleModeReadyWork(function()
            if not RequireDeviceCommandReady("Set Flame Level after mode change") then return end
            if SendDeviceControl("flame_control", tostring(level)) then
                SetRequestedExtrasControlState("flame_control", level)
            end
        end)
    else
        CancelPendingModeReadyWork()
        if not SendDeviceControl("flame_control", tostring(level)) then return false end
        SetRequestedExtrasControlState("flame_control", level)
    end
    return true
end

function CommandFlameUp()
    local level = (tonumber(gState.flame_control) or 0) + 1
    return CommandSetFlame(level)
end

function CommandFlameDown()
    local level = (tonumber(gState.flame_control) or 0) - 1
    return CommandSetFlame(level)
end

function CommandSetFan(level)
    if not RequireDeviceCommandReady("Set Fan Level") then return false end
    level = ClampNumber(level, 0, 6, nil)
    if level == nil then
        dbg_err("Set Fan Level missing or invalid Level parameter")
        return false
    end
    if not SendDeviceControl("fan_control", tostring(level)) then return false end
    SetRequestedExtrasControlState("fan_control", level)
    return true
end

function CommandSetLight(level)
    if not RequireDeviceCommandReady("Set Light Level") then return false end
    level = ClampNumber(level, 0, 6, nil)
    if level == nil then
        dbg_err("Set Light Level missing or invalid Level parameter")
        return false
    end
    if not SendDeviceControl("lamp_control", tostring(level)) then return false end
    SetRequestedExtrasControlState("lamp_control", level)
    return true
end

function CommandSetTemperatureF(tempF)
    if not RequireDeviceCommandReady("Set Temperature") then return false end
    tempF = ClampNumber(tempF, 60, 90, nil)
    if tempF == nil then
        dbg_err("Set Temperature missing or invalid Temperature parameter")
        return false
    end
    if not SendDeviceControl("temperature_set", EncodeTemperature(tempF)) then return false end
    SetPendingSetpoint(tempF)
    return true
end

function CommandSetPilot(value)
    if not RequireDeviceCommandReady("Set Pilot") then return false end
    value = tostring(ClampNumber(value, 0, 1, 0))
    return SendDeviceControl("pilot_control", value)
end

function CommandTogglePilot()
    if not RequireConfirmedDeviceStatus("pilot_control", "Toggle Pilot") then return false end
    return CommandSetPilot(gState.pilot_control == "1" and 0 or 1)
end

function CommandToggleAux()
    if not RequireConfirmedDeviceStatus("aux_control", "Toggle Aux") then return false end
    local value = gState.aux_control == "1" and "0" or "1"
    return SendDeviceControl("aux_control", value)
end

function CommandToggleFrontFlame()
    if not RequireConfirmedDeviceStatus("split_control", "Toggle Front Flame") then return false end
    local value = gState.split_control == "1" and "0" or "1"
    return SendDeviceControl("split_control", value)
end

function CommandSetTimerMinutes(minutes)
    if not RequireDeviceCommandReady("Set Timer") then return false end
    minutes = ClampNumber(minutes, 0, 480, nil)
    if minutes == nil then
        dbg_err("Set Timer missing or invalid Minutes parameter")
        return false
    end

    dbg_err("CommandSetTimerMinutes: " .. tostring(minutes) .. " minutes, current mode: " .. tostring(gState.main_mode))
    CancelPendingTimerCommandTimers()

    if minutes > 0 then
        SetTimerSuppression(true, "set timer command")
        gTimerExpired = false

        if gState.main_mode == MODE_OFF or gState.main_mode == MODE_STANDBY then
            dbg_err("Fireplace is off, turning on with timer")
            if not SendDeviceControl("main_mode", GetDefaultOnMode()) then
                SetTimerSuppression(false, "timer mode send failed")
                return false
            end
            local defaultFlame = GetDefaultFlameLevel()
            ScheduleModeReadyWork(function()
                if not RequireDeviceCommandReady("Set Timer after mode change") then
                    SetTimerSuppression(false, "timer mode-ready work disconnected")
                    return
                end
                if SendDeviceControl("flame_control", tostring(defaultFlame)) then
                    SetRequestedExtrasControlState("flame_control", defaultFlame)
                end
                SetTimerValueAndArm(minutes, true)
            end)
        else
            return SetTimerValueAndArm(minutes, true)
        end
    else
        dbg_err("Timer set to 0, turning off fireplace")
        return ClearTimerStateAndSend(true)
    end
    return true
end

function CommandCancelTimer()
    return ClearTimerStateAndSend(false)
end

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}
    dbg_err("ExecuteCommand: " .. tostring(strCommand))

    if strCommand == "Turn On" then
        return CommandTurnOn()
    elseif strCommand == "Turn Off" then
        return CommandTurnOff()
    elseif strCommand == "Set Mode Manual" then
        return CommandSetMode(MODE_MANUAL)
    elseif strCommand == "Set Mode Smart" then
        return CommandSetMode(MODE_SMART)
    elseif strCommand == "Set Mode Eco" then
        return CommandSetMode(MODE_ECO)
    elseif strCommand == "Set Flame Level" then
        return CommandSetFlame(GetCommandParam(tParams, "Level", "LEVEL", "level"))
    elseif strCommand == "Flame Up" then
        return CommandFlameUp()
    elseif strCommand == "Flame Down" then
        return CommandFlameDown()
    elseif strCommand == "Set Fan Level" then
        return CommandSetFan(GetCommandParam(tParams, "Level", "LEVEL", "level"))
    elseif strCommand == "Fan On" then
        return CommandSetFan(6)
    elseif strCommand == "Fan Off" then
        return CommandSetFan(0)
    elseif strCommand == "Set Light Level" then
        return CommandSetLight(GetCommandParam(tParams, "Level", "LEVEL", "level"))
    elseif strCommand == "Light On" then
        return CommandSetLight(6)
    elseif strCommand == "Light Off" then
        return CommandSetLight(0)
    elseif strCommand == "Set Temperature" then
        return CommandSetTemperatureF(GetCommandParam(tParams, "Temperature", "TEMPERATURE", "temperature"))
    elseif strCommand == "Toggle Pilot" then
        return CommandTogglePilot()
    elseif strCommand == "Pilot On" then
        return CommandSetPilot(1)
    elseif strCommand == "Pilot Off" then
        return CommandSetPilot(0)
    elseif strCommand == "Toggle Aux" then
        return CommandToggleAux()
    elseif strCommand == "Toggle Front Flame" then
        return CommandToggleFrontFlame()
    elseif strCommand == "Set Timer" then
        local minutes = ClampNumber(GetCommandParam(tParams, "Minutes", "MINUTES", "minutes"), 1, 480, nil)
        return CommandSetTimerMinutes(minutes)
    elseif strCommand == "Cancel Timer" then
        return CommandCancelTimer()
    end

    dbg_err("Unhandled ExecuteCommand: " .. tostring(strCommand))
    return false
end

-- =============================================================================
-- PROXY CALLBACKS
-- =============================================================================

function ReceivedFromProxy(idBinding, strCommand, tParams)
    tParams = tParams or {}
    
    -- Handle Request for Extras
    if strCommand == "GET_EXTRAS_SETUP" then
        dbg_err("GET_EXTRAS_SETUP received - returning extras setup XML directly")
        local xml = GetExtrasXML()
        dbg_all("Extras XML: " .. xml)
        -- Return the XML directly as the response
        return xml
    end
    
    -- Handle Request for Extras State
    if strCommand == "GET_EXTRAS_STATE" then
        dbg_err("GET_EXTRAS_STATE received - returning extras setup XML with current values")
        -- Return the setup XML which contains current values embedded
        return GetExtrasXML()
    end
    
    if idBinding == THERMOSTAT_PROXY_ID then HandleThermostatCommand(strCommand, tParams)
    end
end

function HandleThermostatCommand(strCommand, tParams)
    if strCommand == "SET_MODE_HVAC" then
        local mode = tParams["MODE"]
        if mode == "Off" then
            CommandTurnOff()
        elseif mode == "Heat" then
            CommandTurnOn()
        end
        
    elseif strCommand == "SET_SETPOINT_HEAT" or strCommand == "SET_SETPOINT_SINGLE" then
        local tempF
        if tParams["FAHRENHEIT"] then tempF = tonumber(tParams["FAHRENHEIT"])
        elseif tParams["CELSIUS"] then 
            tempF = CelsiusToFahrenheit(tonumber(tParams["CELSIUS"]))
        else 
            tempF = tonumber(tParams["SETPOINT"]) 
        end
        
        if tempF and tempF < 50 then tempF = CelsiusToFahrenheit(tempF) end
        CommandSetTemperatureF(tempF or 70)
        
    elseif strCommand == "SET_MODE_FAN" then
        local mode = tParams["MODE"]
        local level = 0
        -- Map standard names to levels
        if mode == "Off" then
            level = 0
        elseif mode == "Low" then
            level = 2
        elseif mode == "Medium" then
            level = 4
        elseif mode == "High" then
            level = 6
        else
            -- Try parsing as number for backwards compatibility
            level = tonumber(mode) or 0
        end
        dbg_err("SET_MODE_FAN: " .. tostring(mode) .. " -> level " .. level)
        CommandSetFan(level)
        
    elseif strCommand == "SET_EXTRAS" then
        dbg_err("Received SET_EXTRAS command")
        -- Handle flame preset (Low/Medium/High quick select)
        if tParams["pf_flame_preset"] then
            local val = tonumber(tParams["pf_flame_preset"])
            if val then
                dbg_err("Flame preset selected: " .. val)
                CommandSetFlame(val)
            end
        end
        -- Handle flame slider (fine adjustment)
        if tParams["pf_flame"] then
            local val = tonumber(tParams["pf_flame"])
            if val then
                CommandSetFlame(val)
            end
        end
        if tParams["pf_fan"] then
            local val = tonumber(tParams["pf_fan"])
            if val then CommandSetFan(val) end
        end
        if tParams["pf_light"] then
            local val = tonumber(tParams["pf_light"])
            if val then CommandSetLight(val) end
        end
    elseif strCommand == "SET_SCALE" then
        local scale = tParams["SCALE"] or "FAHRENHEIT"
        C4:SendToProxy(THERMOSTAT_PROXY_ID, "SCALE_CHANGED", { SCALE = scale })
        UpdateThermostatSetpoint()
        
    elseif strCommand == "SET_PRESET" then
        local preset = tParams["PRESET"] or tParams["MODE"] or tParams["NAME"] or ""
        local changed = false
        dbg_err("SET_PRESET received: " .. preset)
        if preset == "Manual" then
            changed = CommandSetMode(MODE_MANUAL)
        elseif preset == "Smart" then
            changed = CommandSetMode(MODE_SMART)
        elseif preset == "Eco" then
            changed = CommandSetMode(MODE_ECO)
        end
        -- Notify proxy of preset change immediately
        if changed then
            UpdatePresetMode(
                preset == "Manual" and MODE_MANUAL or
                preset == "Smart" and MODE_SMART or
                preset == "Eco" and MODE_ECO or
                gState.main_mode
            )
        end
        
    elseif strCommand == "SET_MODE_HOLD" then
        -- Hold modes repurposed for quick flame control:
        -- "Low Flame" = level 1, "Medium Flame" = level 3, "High Flame" = level 6
        local holdMode = tParams["MODE"] or ""
        dbg_err("SET_MODE_HOLD received: " .. holdMode)
        if holdMode == "Low Flame" then
            -- Low flame (level 1)
            if CommandSetFlame(1) then
                C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "Low Flame" })
            end
        elseif holdMode == "Medium Flame" then
            -- Medium flame (level 3)
            if CommandSetFlame(3) then
                C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "Medium Flame" })
            end
        elseif holdMode == "High Flame" then
            -- High flame (level 6)
            if CommandSetFlame(6) then
                C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "High Flame" })
            end
        end
        
    -- New extras commands (matching Ecobee-style format)
    elseif strCommand == "SELECT_MODE" then
        local val = tParams["VALUE"] or tParams["value"] or ""
        dbg_err("SELECT_MODE: " .. tostring(val))
        if val == "off" then
            CommandTurnOff()
        elseif val == "manual" then
            CommandSetMode(MODE_MANUAL)
        elseif val == "smart" then
            CommandSetMode(MODE_SMART)
        elseif val == "eco" then
            CommandSetMode(MODE_ECO)
        end
        
    elseif strCommand == "SELECT_FLAME_PRESET" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_err("SELECT_FLAME_PRESET: " .. tostring(val))
        if val then
            CommandSetFlame(val)
        end
        
    elseif strCommand == "SET_FLAME_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_err("SET_FLAME_LEVEL: " .. tostring(val))
        if val then
            CommandSetFlame(val)
        end
        
    elseif strCommand == "SET_FAN_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_err("SET_FAN_LEVEL: " .. tostring(val))
        if val then CommandSetFan(val) end
        
    elseif strCommand == "SET_LIGHT_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_err("SET_LIGHT_LEVEL: " .. tostring(val))
        if val then CommandSetLight(val) end
        
    elseif strCommand == "SET_TIMER_MINUTES" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_err("SET_TIMER_MINUTES: " .. tostring(val) .. " minutes, current mode: " .. tostring(gState.main_mode))
        if val and val >= 0 then CommandSetTimerMinutes(val) end
    end
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

function ResetDriverState()
    -- Reset all connection state
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gReceiveBuffer = ""
    gExtrasThrottle = false
    SetTimerSuppression(false, "driver state reset")
    gTimerExpired = false
    gLastMainMode = nil
    gLastConnectionOnline = false
    gStatusSeen = {}

    -- Cancel any pending timers
    StopPingTimer()
    StopReconnectTimer()
    CancelPendingTimerCommandTimers()
    
    -- Reset device state
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
    
    dbg_err("Driver state reset")
end

function OnDriverInit()
    local success, err = pcall(function()
        dbg_err("OnDriverInit - resetting state")
        math.randomseed(os.time())
        ResetDriverState()
        InitializePropertiesFromState()
    end)
    if not success then print("OnDriverInit Error: " .. tostring(err)) end
end

function OnDriverLateInit()
    -- Initialize debug settings from properties before any logging
    gDebugEnabled = (Properties["Debug Mode"] == "On")
    local level = Properties["Debug Level"]
    if level == "Error" then gDebugLevel = DEBUG_ERROR
    elseif level == "Warning" then gDebugLevel = DEBUG_WARN
    elseif level == "Info" then gDebugLevel = DEBUG_INFO
    elseif level == "Debug" then gDebugLevel = DEBUG_DEBUG
    elseif level == "Trace" then gDebugLevel = DEBUG_TRACE
    end

    dbg_err("OnDriverLateInit - Build: " .. BUILD_TIMESTAMP)
    local success, err = pcall(function()
        C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ") [" .. BUILD_TIMESTAMP .. "]")
        
        -- Ensure clean state before connecting
        Disconnect()
        
        -- DELAYED EXTRAS SETUP TO ENSURE PROXY IS READY
        C4:SetTimer(2000, function() SetupExtras() end, false)
        
        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            -- Delay connection slightly to ensure network is ready
            C4:SetTimer(500, function() Connect() end, false)
        else
            C4:UpdateProperty("Connection Status", "Not Configured")
        end
    end)
    if not success then print("OnDriverLateInit Error: " .. tostring(err)) end
end

function InitializePropertiesFromState()
    C4:UpdateProperty("Operating Mode", GetModeString(gState.main_mode))
    C4:UpdateProperty("Flame Level", gState.flame_control)
    C4:UpdateProperty("Fan Level", gState.fan_control)
    C4:UpdateProperty("Light Level", gState.lamp_control)
    C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(gState.temperature_set) .. "F")
    C4:UpdateProperty("Room Temperature", DecodeTemperature(gState.room_temperature) .. "F")
    C4:UpdateProperty("Thermostat Enabled", gState.thermo_control == "1" and "Yes" or "No")
    C4:UpdateProperty("Pilot Status", gState.pilot_control == "1" and "On" or "Off")
    C4:UpdateProperty("Aux Output", gState.aux_control == "1" and "On" or "Off")
    C4:UpdateProperty("Front Flame (Split)", gState.split_control == "1" and "On" or "Off")
    C4:UpdateProperty("Timer Active", gState.timer_status == "1" and "Yes" or "No")
    C4:UpdateProperty("Timer Remaining", "Off")
    local burnerNum = tonumber(gState.burner_status) or 0
    if burnerNum < 0 then burnerNum = burnerNum + 0x10000 end
    C4:UpdateProperty("Burner Status", string.format("0x%04X", burnerNum))
    C4:UpdateProperty("WiFi Signal Strength", "-" .. gState.wifi_signal_str .. " dBm")
    UpdateThermostatSetpoint()
end

function OnDriverDestroyed()
    dbg_err("OnDriverDestroyed - cleaning up")
    StopPingTimer()
    StopReconnectTimer()
    CancelPendingTimerCommandTimers()
    Disconnect()
end

function OnDriverUpdated()
    -- Called when driver is updated/reloaded
    dbg_err("OnDriverUpdated - driver updated to version " .. DRIVER_VERSION)
    
    -- Clean up old state
    StopPingTimer()
    StopReconnectTimer()
    CancelPendingTimerCommandTimers()
    Disconnect()
    
    -- Reset state
    ResetDriverState()
    
    -- Update version display
    C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ")")
    
    -- Reinitialize
    InitializePropertiesFromState()
    
    -- Reconnect after delay
    C4:SetTimer(1000, function()
        SetupExtras()
        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            Connect()
        end
    end, false)
end
