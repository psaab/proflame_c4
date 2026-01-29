--[[
    Proflame WiFi Fireplace Controller - Control4 Driver
    Copyright 2025 Paul Saab. All rights reserved.
]]

-- =============================================================================
-- CONSTANTS
-- =============================================================================

DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2025012905"
DRIVER_DATE = "2025-01-29"

NETWORK_BINDING_ID = 6001
THERMOSTAT_PROXY_ID = 5001

MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_MANUAL = "5"
MODE_SMART = "6"
MODE_ECO = "7"

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
BUILD_TIMESTAMP = "20250129-160000"

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
gWebSocketKey = nil
gDebugLevel = DEBUG_DEBUG
gExtrasThrottle = false
gSuppressTimerUpdates = false  -- Suppress device timer_count updates while we're setting timer

gPendingSetpointF = nil
gPendingTimer = nil
gPendingFlame = nil
gPendingDefaultTimer = nil

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
    level = level or DEBUG_INFO
    if level <= gDebugLevel then
        print("[Proflame] " .. tostring(msg))
    end
end

function dbg(msg)
    Log(msg, DEBUG_DEBUG)
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
        result = result .. '"' .. tostring(k) .. '":'
        if type(v) == "string" then result = result .. '"' .. v .. '"'
        elseif type(v) == "number" then result = result .. tostring(v)
        elseif type(v) == "boolean" then result = result .. (v and "true" or "false")
        else result = result .. '"' .. tostring(v) .. '"'
        end
    end
    result = result .. "}"
    return result
end

function JsonDecode(str)
    if not str then return {} end
    local result = {}
    for key, value in str:gmatch('"([^"]+)":"([^"]*)"') do
        result[key] = value
    end
    for key, value in str:gmatch('"([^"]+)":(-?%d+)') do
        if not result[key] then result[key] = value end
    end
    return result
end

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

function MakeCommand(control, value)
    return '{"control0":"' .. control .. '","value0":"' .. tostring(value) .. '"}'
end

-- Alternative command format from spec - {"command":"set_control","name":"X","value":"Y"}
function MakeCommandAlt(control, value)
    return '{"command":"set_control","name":"' .. control .. '","value":"' .. tostring(value) .. '"}'
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
    local timerMs = tonumber(gState.timer_set) or 0
    local timerMinutes = math.floor(timerMs / 60000)
    
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
    local modeValue = "manual"
    if mode == MODE_SMART then
        modeValue = "smart"
    elseif mode == MODE_ECO then
        modeValue = "eco"
    end
    
    -- Build mode items with current mode first (this is how Ecobee does it)
    local modeItems = ""
    if modeValue == "manual" then
        modeItems = '<item text="Manual" value="manual"/><item text="Smart Thermostat" value="smart"/><item text="Eco" value="eco"/>'
    elseif modeValue == "smart" then
        modeItems = '<item text="Smart Thermostat" value="smart"/><item text="Manual" value="manual"/><item text="Eco" value="eco"/>'
    else
        modeItems = '<item text="Eco" value="eco"/><item text="Manual" value="manual"/><item text="Smart Thermostat" value="smart"/>'
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
    dbg("Sending extras setup via DataToUI")
    local xml = GetExtrasXML()
    dbg("Extras XML: " .. xml)
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
    dbg("Updating timer extras (minutes changed)")
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
        dbg("Reconnect timer fired")
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

function OnHeatModeTimer()
    -- Called after mode switch to Heat - set flame and timer
    local flame = gPendingFlame or 3
    local timer = gPendingDefaultTimer or 120
    SendProflameCommand("flame_control", tostring(flame))
    if timer > 0 then
        -- Convert minutes to milliseconds
        local msValue = timer * 60000
        SendProflameCommand("timer_set", tostring(msValue))
        gState.timer_set = tostring(msValue)
        -- Start the timer
        C4:SetTimer(200, function()
            SendProflameCommand("timer_status", "1")
        end, false)
        UpdateExtrasState()
    end
    gPendingFlame = nil
    gPendingDefaultTimer = nil
end

function OnSmartEcoModeTimer()
    -- Called after mode switch to Smart/Eco - just set timer (no flame override)
    local timer = gPendingDefaultTimer or 120
    if timer > 0 then
        -- Convert minutes to milliseconds
        local msValue = timer * 60000
        SendProflameCommand("timer_set", tostring(msValue))
        gState.timer_set = tostring(msValue)
        -- Start the timer
        C4:SetTimer(200, function()
            SendProflameCommand("timer_status", "1")
        end, false)
        UpdateExtrasState()
    end
    gPendingDefaultTimer = nil
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

function ValidateHandshakeResponse(response)
    if not response then return false end
    if not response:find("101") then return false end
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
    local opcode = bit.band(byte1, 0x0F)
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
    local port = tonumber(Properties["Port"]) or 88
    if gConnected then
        pcall(function() C4:NetDisconnect(NETWORK_BINDING_ID, port) end)
    end
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gReceiveBuffer = ""
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

function SendProflameCommand(control, value)
    local cmd = MakeCommand(control, value)
    dbg("Sending command: " .. cmd)
    if gState[control] ~= nil then gState[control] = value end
    
    if control == "main_mode" then
        C4:UpdateProperty("Operating Mode", GetModeString(value))
        UpdateThermostatProxy(value)
    elseif control == "flame_control" then
        C4:UpdateProperty("Flame Level", tostring(value))
        UpdateFlameLevel()
    elseif control == "fan_control" then
        C4:UpdateProperty("Fan Level", tostring(value))
        UpdateFanMode()
    elseif control == "lamp_control" then
        C4:UpdateProperty("Light Level", tostring(value))
    elseif control == "temperature_set" then
        C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(value) .. "F")
        UpdateThermostatSetpoint()
    end
    
    UpdateExtrasState()
    return SendWebSocketMessage(cmd)
end

-- Send command using alternative format (for timer control)
function SendProflameCommandAlt(control, value)
    local cmd = MakeCommandAlt(control, value)
    dbg("Sending alt command: " .. cmd)
    return SendWebSocketMessage(cmd)
end

function RequestAllStatus()
    -- The Proflame device requires PROFLAMECONNECTION to trigger full status dump
    -- This is similar to PROFLAMEPING/PROFLAMEPONG but for initial connection
    dbg("Sending PROFLAMECONNECTION to request full status")
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

function UpdateRoomTemperature()
    local tempEncoded = gState.room_temperature or "700"
    local tempF = DecodeTemperature(tempEncoded)
    local tempC = FahrenheitToCelsius(tempF)
    C4:UpdateProperty("Room Temperature", tostring(tempF) .. "F")
    dbg("Sending room temperature to proxy: " .. tempF .. "F (" .. tempC .. "C)")
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "TEMPERATURE_CHANGED", {TEMPERATURE = tempC, SCALE = "C"})
end

-- =============================================================================
-- SETPOINT PENDING LOGIC (Anti-Jump)
-- =============================================================================

function SetPendingSetpoint(tempF)
    gPendingSetpointF = tempF
    dbg("SetPendingSetpoint locked: " .. tostring(tempF))
    if gPendingTimer then gPendingTimer:Cancel() end
    gPendingTimer = C4:SetTimer(5000, function()
        dbg("Pending setpoint timer expired, unlocking")
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
        dbg("Connection acknowledged by device")
        C4:UpdateProperty("Connection Status", "Connected")
        return
    end
    if data:sub(1, 1) == "{" then
        dbg("Received JSON: " .. data:sub(1, 200))
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
                end
            end
        end
    end
end

function ProcessStatusUpdate(status, value)
    if not status or not value then return end
    
    dbg("ProcessStatusUpdate: " .. tostring(status) .. " = " .. tostring(value))
    
    if status == "temperature_set" then
        local incomingF = DecodeTemperature(value)
        if gPendingSetpointF ~= nil then
            if math.abs(incomingF - gPendingSetpointF) < 1 then
                dbg("Pending setpoint confirmed: " .. incomingF)
                gPendingSetpointF = nil
            else
                dbg("Ignoring stale setpoint: " .. incomingF)
                return
            end
        end
    end
    
    if gState[status] ~= nil then gState[status] = value end
    
    UpdateExtrasState()
    
    if status == "main_mode" then
        C4:UpdateProperty("Operating Mode", GetModeString(value))
        UpdateThermostatProxy(value)
        UpdatePresetMode(value)
        -- If fireplace turns off and we're not suppressing, reset timer slider to 0
        if (value == MODE_OFF or value == MODE_STANDBY) and not gSuppressTimerUpdates then
            gState.timer_set = "0"
            gState.timer_count = "0"
            C4:UpdateProperty("Timer Remaining", "Off")
            UpdateTimerExtras()
        end
    elseif status == "flame_control" then
        C4:UpdateProperty("Flame Level", tostring(value))
        UpdateFlameLevel()
        UpdateHoldModeFromFlame()
    elseif status == "fan_control" then
        C4:UpdateProperty("Fan Level", tostring(value))
        UpdateFanMode()
    elseif status == "lamp_control" then
        C4:UpdateProperty("Light Level", tostring(value))
    elseif status == "temperature_set" then
        C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(value) .. "F")
        UpdateThermostatSetpoint()
    elseif status == "room_temperature" or status == "temperature_read" then
        gState.room_temperature = value
        dbg("Room temperature updated: " .. value .. " (raw) = " .. DecodeTemperature(value) .. "F")
        UpdateRoomTemperature()
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
        -- If timer is turned off by device and we're not suppressing, clear remaining time and reset slider
        if value == "0" and not gSuppressTimerUpdates then
            C4:UpdateProperty("Timer Remaining", "Off")
            gState.timer_set = "0"
            gState.timer_count = "0"
            UpdateTimerExtras()
        end
    elseif status == "timer_set" then
        -- Don't update gState.timer_set from device responses
        -- We only set timer_set from our own commands to avoid sync issues
        -- Just log the device's reported value for debugging
        local minutes = math.floor(tonumber(value) / 60000)
        dbg("Device timer_set: " .. tostring(value) .. " ms (" .. minutes .. " minutes), our timer_set: " .. tostring(gState.timer_set))
    elseif status == "timer_count" then
        -- Skip timer_count updates while we're actively setting the timer
        if gSuppressTimerUpdates then
            dbg("Timer count update suppressed: " .. tostring(value))
            return
        end
        
        local newCount = tonumber(value) or 0
        local newMinutes = math.floor(newCount / 60000)
        
        -- Get old minutes from timer_count (for detecting minute changes)
        local oldCount = tonumber(gState.timer_count) or 0
        local oldMinutes = math.floor(oldCount / 60000)
        
        -- Store the raw count
        gState.timer_count = value
        
        -- Convert milliseconds to hours:minutes:seconds for display
        local totalSeconds = math.floor(newCount / 1000)
        local hours = math.floor(totalSeconds / 3600)
        local minutes = math.floor((totalSeconds % 3600) / 60)
        local seconds = totalSeconds % 60
        local timeStr
        if hours > 0 then
            timeStr = string.format("%d:%02d:%02d", hours, minutes, seconds)
        elseif newCount > 0 then
            timeStr = string.format("%d:%02d", minutes, seconds)
        else
            timeStr = "Off"
        end
        C4:UpdateProperty("Timer Remaining", timeStr)
        
        -- Update the slider when minute changes
        dbg("Timer count: " .. newCount .. "ms (" .. newMinutes .. "m), old count: " .. oldCount .. "ms (" .. oldMinutes .. "m)")
        if oldMinutes ~= newMinutes then
            dbg("Timer minute changed: " .. oldMinutes .. " -> " .. newMinutes .. ", updating slider")
            -- Update timer_set to match for slider display
            gState.timer_set = tostring(newMinutes * 60000)
            UpdateTimerExtras()
        end
    elseif status == "burner_status" then
        C4:UpdateProperty("Burner Status", tostring(value))
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
    dbg("Fan mode updated: level " .. levelNum .. " = " .. fanMode)
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "FAN_MODE_CHANGED", { MODE = fanMode })
end

function UpdateFlameLevel()
    local flameLevel = tonumber(gState.flame_control) or 0
    local percent = math.floor(flameLevel / 6 * 100)
    local isOn = (flameLevel > 0) and (gState.main_mode ~= MODE_OFF and gState.main_mode ~= MODE_STANDBY)
    dbg("Flame level updated: " .. flameLevel .. " = " .. percent .. "%, on=" .. tostring(isOn))
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
    dbg("Hold mode updated to: " .. holdMode .. " (flame level " .. flameLevel .. ")")
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
        dbg("Updating preset mode to: " .. preset)
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
    dbg("OnPropertyChanged: " .. tostring(strProperty))
    if strProperty == "IP Address" then 
        dbg("IP Address changed, disconnecting and reconnecting...")
        Disconnect()
        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            -- Small delay to ensure clean disconnect before reconnect
            C4:SetTimer(500, function() Connect() end, false)
        else
            C4:UpdateProperty("Connection Status", "Not Configured")
        end
    elseif strProperty == "Port" then
        dbg("Port changed, disconnecting and reconnecting...")
        Disconnect()
        C4:SetTimer(500, function() Connect() end, false)
    elseif strProperty == "Debug Level" then
        local level = Properties["Debug Level"]
        if level == "Error" then gDebugLevel = DEBUG_ERROR
        elseif level == "Warning" then gDebugLevel = DEBUG_WARN
        elseif level == "Info" then gDebugLevel = DEBUG_INFO
        elseif level == "Debug" then gDebugLevel = DEBUG_DEBUG
        elseif level == "Trace" then gDebugLevel = DEBUG_TRACE
        end
        dbg("Debug level set to: " .. tostring(gDebugLevel))
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
        gReceiveBuffer = remaining
        if opcode == 0x01 then ParseStatusMessage(payload)
        elseif opcode == 0x08 then Disconnect() ScheduleReconnect()
        end
    end
end

-- =============================================================================
-- PROXY CALLBACKS
-- =============================================================================

function ReceivedFromProxy(idBinding, strCommand, tParams)
    tParams = tParams or {}
    
    -- Handle Request for Extras
    if strCommand == "GET_EXTRAS_SETUP" then
        dbg("GET_EXTRAS_SETUP received - returning extras setup XML directly")
        local xml = GetExtrasXML()
        dbg("Extras XML: " .. xml)
        -- Return the XML directly as the response
        return xml
    end
    
    -- Handle Request for Extras State
    if strCommand == "GET_EXTRAS_STATE" then
        dbg("GET_EXTRAS_STATE received - returning extras setup XML with current values")
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
            SendProflameCommand("main_mode", MODE_OFF)
        elseif mode == "Heat" then
            SendProflameCommand("main_mode", MODE_MANUAL)
            -- Set flame level and start default timer
            local defaultFlame = tonumber(Properties["Default Flame Level"]) or 3
            local defaultTimer = tonumber(Properties["Default Timer (minutes)"]) or 120
            C4:SetTimer(750, function(timer)
                SendProflameCommand("flame_control", tostring(defaultFlame))
                if defaultTimer > 0 then
                    local msValue = defaultTimer * 60000
                    SendProflameCommand("timer_set", tostring(msValue))
                    gState.timer_set = tostring(msValue)
                    C4:SetTimer(200, function(timer2)
                        SendProflameCommand("timer_status", "1")
                    end, false)
                    UpdateExtrasState()
                end
            end, false)
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
        tempF = math.max(60, math.min(90, tempF or 70))
        SetPendingSetpoint(tempF)
        SendProflameCommand("temperature_set", EncodeTemperature(tempF))
        
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
        dbg("SET_MODE_FAN: " .. tostring(mode) .. " -> level " .. level)
        SendProflameCommand("fan_control", tostring(level))
        
    elseif strCommand == "SET_EXTRAS" then
        dbg("Received SET_EXTRAS command")
        -- Handle flame preset (Low/Medium/High quick select)
        if tParams["pf_flame_preset"] then
            local val = tonumber(tParams["pf_flame_preset"])
            if val then
                dbg("Flame preset selected: " .. val)
                if gState.main_mode ~= MODE_MANUAL then
                    SendProflameCommand("main_mode", MODE_MANUAL)
                    C4:SetTimer(750, function() SendProflameCommand("flame_control", tostring(val)) end, false)
                else
                    SendProflameCommand("flame_control", tostring(val))
                end
            end
        end
        -- Handle flame slider (fine adjustment)
        if tParams["pf_flame"] then
            local val = tonumber(tParams["pf_flame"])
            if val then
                if gState.main_mode ~= MODE_MANUAL then
                    SendProflameCommand("main_mode", MODE_MANUAL)
                    C4:SetTimer(750, function() SendProflameCommand("flame_control", tostring(val)) end, false)
                else
                    SendProflameCommand("flame_control", tostring(val))
                end
            end
        end
        if tParams["pf_fan"] then
            local val = tonumber(tParams["pf_fan"])
            if val then SendProflameCommand("fan_control", tostring(val)) end
        end
        if tParams["pf_light"] then
            local val = tonumber(tParams["pf_light"])
            if val then SendProflameCommand("lamp_control", tostring(val)) end
        end
    elseif strCommand == "SET_SCALE" then
        local scale = tParams["SCALE"] or "FAHRENHEIT"
        C4:SendToProxy(THERMOSTAT_PROXY_ID, "SCALE_CHANGED", { SCALE = scale })
        UpdateThermostatSetpoint()
        
    elseif strCommand == "SET_PRESET" then
        local preset = tParams["PRESET"] or tParams["MODE"] or tParams["NAME"] or ""
        dbg("SET_PRESET received: " .. preset)
        if preset == "Manual" then
            SendProflameCommand("main_mode", MODE_MANUAL)
            local defaultFlame = tonumber(Properties["Default Flame Level"]) or 3
            C4:SetTimer(750, function() SendProflameCommand("flame_control", tostring(defaultFlame)) end, false)
        elseif preset == "Smart" then
            SendProflameCommand("main_mode", MODE_SMART)
        elseif preset == "Eco" then
            SendProflameCommand("main_mode", MODE_ECO)
        end
        -- Notify proxy of preset change immediately
        UpdatePresetMode(
            preset == "Manual" and MODE_MANUAL or
            preset == "Smart" and MODE_SMART or
            preset == "Eco" and MODE_ECO or
            gState.main_mode
        )
        
    elseif strCommand == "SET_MODE_HOLD" then
        -- Hold modes repurposed for quick flame control:
        -- "Low Flame" = level 1, "Medium Flame" = level 3, "High Flame" = level 6
        local holdMode = tParams["MODE"] or ""
        dbg("SET_MODE_HOLD received: " .. holdMode)
        if holdMode == "Low Flame" then
            -- Low flame (level 1)
            if gState.main_mode ~= MODE_MANUAL then
                SendProflameCommand("main_mode", MODE_MANUAL)
                C4:SetTimer(750, function() SendProflameCommand("flame_control", "1") end, false)
            else
                SendProflameCommand("flame_control", "1")
            end
            C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "Low Flame" })
        elseif holdMode == "Medium Flame" then
            -- Medium flame (level 3)
            if gState.main_mode ~= MODE_MANUAL then
                SendProflameCommand("main_mode", MODE_MANUAL)
                C4:SetTimer(750, function() SendProflameCommand("flame_control", "3") end, false)
            else
                SendProflameCommand("flame_control", "3")
            end
            C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "Medium Flame" })
        elseif holdMode == "High Flame" then
            -- High flame (level 6)
            if gState.main_mode ~= MODE_MANUAL then
                SendProflameCommand("main_mode", MODE_MANUAL)
                C4:SetTimer(750, function() SendProflameCommand("flame_control", "6") end, false)
            else
                SendProflameCommand("flame_control", "6")
            end
            C4:SendToProxy(THERMOSTAT_PROXY_ID, "HOLD_MODE_CHANGED", { MODE = "High Flame" })
        end
        
    -- New extras commands (matching Ecobee-style format)
    elseif strCommand == "SELECT_MODE" then
        local val = tParams["VALUE"] or tParams["value"] or ""
        dbg("SELECT_MODE: " .. tostring(val))
        local defaultTimer = tonumber(Properties["Default Timer (minutes)"]) or 120
        if val == "manual" then
            SendProflameCommand("main_mode", MODE_MANUAL)
            local defaultFlame = tonumber(Properties["Default Flame Level"]) or 3
            C4:SetTimer(750, function(timer)
                SendProflameCommand("flame_control", tostring(defaultFlame))
                if defaultTimer > 0 then
                    local msValue = defaultTimer * 60000
                    SendProflameCommand("timer_set", tostring(msValue))
                    gState.timer_set = tostring(msValue)
                    C4:SetTimer(200, function(timer2)
                        SendProflameCommand("timer_status", "1")
                    end, false)
                    UpdateExtrasState()
                end
            end, false)
        elseif val == "smart" then
            SendProflameCommand("main_mode", MODE_SMART)
            if defaultTimer > 0 then
                C4:SetTimer(750, function(timer)
                    local msValue = defaultTimer * 60000
                    SendProflameCommand("timer_set", tostring(msValue))
                    gState.timer_set = tostring(msValue)
                    C4:SetTimer(200, function(timer2)
                        SendProflameCommand("timer_status", "1")
                    end, false)
                    UpdateExtrasState()
                end, false)
            end
        elseif val == "eco" then
            SendProflameCommand("main_mode", MODE_ECO)
            if defaultTimer > 0 then
                C4:SetTimer(750, function(timer)
                    local msValue = defaultTimer * 60000
                    SendProflameCommand("timer_set", tostring(msValue))
                    gState.timer_set = tostring(msValue)
                    C4:SetTimer(200, function(timer2)
                        SendProflameCommand("timer_status", "1")
                    end, false)
                    UpdateExtrasState()
                end, false)
            end
        end
        
    elseif strCommand == "SELECT_FLAME_PRESET" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg("SELECT_FLAME_PRESET: " .. tostring(val))
        if val then
            if gState.main_mode ~= MODE_MANUAL then
                SendProflameCommand("main_mode", MODE_MANUAL)
                C4:SetTimer(750, function() SendProflameCommand("flame_control", tostring(val)) end, false)
            else
                SendProflameCommand("flame_control", tostring(val))
            end
        end
        
    elseif strCommand == "SET_FLAME_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg("SET_FLAME_LEVEL: " .. tostring(val))
        if val then
            if gState.main_mode ~= MODE_MANUAL then
                SendProflameCommand("main_mode", MODE_MANUAL)
                C4:SetTimer(750, function() SendProflameCommand("flame_control", tostring(val)) end, false)
            else
                SendProflameCommand("flame_control", tostring(val))
            end
        end
        
    elseif strCommand == "SET_FAN_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg("SET_FAN_LEVEL: " .. tostring(val))
        if val then SendProflameCommand("fan_control", tostring(val)) end
        
    elseif strCommand == "SET_LIGHT_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg("SET_LIGHT_LEVEL: " .. tostring(val))
        if val then SendProflameCommand("lamp_control", tostring(val)) end
        
    elseif strCommand == "SET_TIMER_MINUTES" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg("SET_TIMER_MINUTES: " .. tostring(val) .. " minutes, current mode: " .. tostring(gState.main_mode))
        if val and val >= 0 then
            -- Suppress device timer updates while we're setting
            gSuppressTimerUpdates = true
            
            -- Convert minutes to milliseconds (device uses milliseconds)
            local msValue = val * 60000
            if val > 0 then
                -- Set our state immediately
                gState.timer_set = tostring(msValue)
                
                -- If fireplace is off, turn it on first
                if gState.main_mode == MODE_OFF or gState.main_mode == MODE_STANDBY then
                    dbg("Fireplace is off, turning on with timer")
                    SendProflameCommand("main_mode", MODE_MANUAL)
                    local defaultFlame = tonumber(Properties["Default Flame Level"]) or 3
                    C4:SetTimer(750, function(timer)
                        SendProflameCommand("flame_control", tostring(defaultFlame))
                        -- Set timer value in milliseconds
                        SendProflameCommand("timer_set", tostring(msValue))
                        -- Start the timer
                        C4:SetTimer(200, function(timer2)
                            SendProflameCommand("timer_status", "1")
                            -- Clear suppression after commands are sent
                            C4:SetTimer(2000, function(timer3)
                                gSuppressTimerUpdates = false
                                dbg("Timer suppression cleared")
                            end, false)
                        end, false)
                        -- Use UpdateTimerExtras for immediate update
                        UpdateTimerExtras()
                    end, false)
                else
                    -- Fireplace already on, just set timer
                    SendProflameCommand("timer_set", tostring(msValue))
                    -- Start the timer
                    C4:SetTimer(200, function(timer)
                        SendProflameCommand("timer_status", "1")
                        -- Clear suppression after commands are sent
                        C4:SetTimer(2000, function(timer2)
                            gSuppressTimerUpdates = false
                            dbg("Timer suppression cleared")
                        end, false)
                    end, false)
                    -- Use UpdateTimerExtras for immediate update
                    UpdateTimerExtras()
                end
            else
                -- Timer set to 0 - turn off fireplace
                dbg("Timer set to 0, turning off fireplace")
                gState.timer_set = "0"
                gState.timer_count = "0"
                SendProflameCommand("timer_status", "0")
                SendProflameCommand("main_mode", MODE_OFF)
                -- Use UpdateTimerExtras for immediate update (not throttled)
                UpdateTimerExtras()
                -- Clear suppression after a delay
                C4:SetTimer(2000, function(timer)
                    gSuppressTimerUpdates = false
                    dbg("Timer suppression cleared")
                end, false)
            end
        end
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
    gSuppressTimerUpdates = false
    
    -- Cancel any pending timers
    StopPingTimer()
    StopReconnectTimer()
    
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
    
    dbg("Driver state reset")
end

function OnDriverInit()
    local success, err = pcall(function()
        dbg("OnDriverInit - resetting state")
        math.randomseed(os.time())
        ResetDriverState()
        InitializePropertiesFromState()
    end)
    if not success then print("OnDriverInit Error: " .. tostring(err)) end
end

function OnDriverLateInit()
    dbg("OnDriverLateInit - Build: " .. BUILD_TIMESTAMP)
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
    C4:UpdateProperty("Burner Status", gState.burner_status)
    C4:UpdateProperty("WiFi Signal Strength", "-" .. gState.wifi_signal_str .. " dBm")
    UpdateThermostatSetpoint()
end

function OnDriverDestroyed()
    dbg("OnDriverDestroyed - cleaning up")
    StopPingTimer()
    StopReconnectTimer()
    Disconnect()
end

function OnDriverUpdated()
    -- Called when driver is updated/reloaded
    dbg("OnDriverUpdated - driver updated to version " .. DRIVER_VERSION)
    
    -- Clean up old state
    StopPingTimer()
    StopReconnectTimer()
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
