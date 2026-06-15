--[[
    Proflame WiFi Fireplace Controller - Control4 Driver
    Copyright 2025 Paul Saab. All rights reserved.
]]

-- =============================================================================
-- CONSTANTS
-- =============================================================================

DRIVER_NAME = "Proflame WiFi Fireplace"
DRIVER_VERSION = "2026061504"
DRIVER_DATE = "2026-06-15"

-- The WebSocket network binding is now allocated dynamically by the vendored
-- drivers-common-public/module/websocket.lua (it scans 6100-6199 for the first
-- free binding via C4:GetBindingAddress). The previous static binding 6001
-- (with its <connection> entry in driver.xml) was removed in C1 Phase 2.
-- Code paths that previously referenced NETWORK_BINDING_ID now read
-- `gWebSocket and gWebSocket.netBinding` instead.
THERMOSTAT_PROXY_ID = 5001

EVENT_FIREPLACE_TURNED_ON = 1
EVENT_FIREPLACE_TURNED_OFF = 2
EVENT_MODE_CHANGED = 3
EVENT_CONNECTION_LOST = 4
EVENT_CONNECTION_RESTORED = 5

MODE_OFF = "0"
MODE_STANDBY = "1"
MODE_STANDBY_ALT = "2"  -- Proflame reports this after app-driven off/standby even though command off is 0.
MODE_MANUAL = "5"
MODE_SMART = "6"
MODE_ECO = "7"

COMMAND_FORMAT_DUAL_DOCUMENTED_FIRST = "Dual (Documented First)"
COMMAND_FORMAT_LEGACY_ONLY = "Legacy Only"
COMMAND_FORMAT_DOCUMENTED_ONLY = "Documented Only"
COMMAND_FORMAT_DUAL_LEGACY_FIRST = "Dual (Legacy First)"
-- Internal-only alias so Turn Off cannot accidentally inherit the Composer-selected non-Turn-Off format.
COMMAND_FORMAT_TURN_OFF_LEGACY_ONLY = "Turn Off Legacy Only"

DEFAULT_FLAME_LEVEL = 6
DEFAULT_TIMER_MINUTES = 180
FLAME_HOLD_MODES = "Low Flame,Medium Flame,High Flame"

-- Debug-level constants kept as aliases over vendor/logging.lua's LogLevel enum
-- so legacy `Log(msg, DEBUG_DEBUG)` call sites keep working. The numeric values
-- match the vendored Log.LogLevel.{ERROR,WARN,INFO,DEBUG,TRACE} on purpose.
DEBUG_ERROR = 1
DEBUG_WARN = 2
DEBUG_INFO = 3
DEBUG_DEBUG = 4
DEBUG_TRACE = 5

-- Status-key classification sets used by ProcessStatusUpdate to gate log spam.
--
-- HANDLED_STATUS_KEYS lists every key whose value our driver routes to
-- gState / Composer properties / proxy notifications / events. These produce
-- a single debug-level log line per status update.
--
-- KNOWN_IGNORED_STATUS_KEYS lists keys the device sends in its initial dump
-- (captured at tools/probes/evidence/characterize-20260603T024355Z.json for
-- firmware FW: 625.04.673) that we intentionally do NOT handle today. These
-- produce no log at all — the firmware emits 67 of them on every reconnect,
-- and logging each one buries genuinely-interesting traffic.
--
-- A key in neither set is treated as a firmware addition we haven't seen
-- before and surfaced at WARN level so future firmware changes are visible.
HANDLED_STATUS_KEYS = {
    main_mode = true, flame_control = true, fan_control = true, lamp_control = true,
    temperature_set = true, room_temperature = true, temperature_read = true,
    thermo_control = true, pilot_control = true, aux_control = true, split_control = true,
    timer_set = true, timer_count = true, timer_status = true, timer_read = true,
    wifi_signal_str = true, rssi = true,
    burner_status = true,
}

KNOWN_IGNORED_STATUS_KEYS = {
    -- Capability/enablement flags (17)
    en_aux = true, en_bit_csc = true, en_fan = true, en_flame = true, en_lamp = true,
    en_ls = true, en_ls_oem = true, en_man = true, en_pilot = true, en_room = true,
    en_scene = true, en_set = true, en_spl = true, en_sth = true, en_th = true,
    en_timer = true, en_weekly = true,
    -- Firmware version sub-fields (5; B1 will promote to a single property)
    fw_revision = true, fw_ble = true, fw_ifc_c = true, fw_ifc_s = true, fw_rc = true,
    -- LED/RGB controls (13; no ThermostatV2 mapping)
    led_conf = true, led_main = true, led_p_1 = true, led_p_2 = true, led_p_3 = true,
    rgb_0_intensity = true, rgb_1_intensity = true, rgb_2_intensity = true, rgb_3_intensity = true,
    rgbw_0_code = true, rgbw_1_code = true, rgbw_2_code = true, rgbw_3_code = true,
    -- Weekly schedule (7)
    p_day_1 = true, p_day_2 = true, p_day_3 = true, p_day_4 = true, p_day_5 = true,
    p_day_6 = true, p_day_7 = true,
    -- OTA / system diagnostics (6)
    ota_dongle = true, ota_touch = true, reset_dongle = true, free_heap = true,
    min_free_heap = true, modbus_ifc = true,
    -- Device identity (4)
    dongle_name = true, dongle_type = true, scenario_name = true, label_aux = true,
    -- Other firmware-emitted fields with no current driver use (16; B2 may promote
    -- child_lock / pilot_mode / remote_control / auxiliary_out / split_flow to
    -- read-only properties). `temperature_unit` stays in KNOWN_IGNORED but has
    -- an A3 carve-out (see ProcessStatusUpdate) that captures the device's
    -- F-vs-C preference into gTemperatureUnit and updates the "Temperature
    -- Unit" Composer property — same shape as the fw_* B1 carve-out.
    auxiliary_out = true, child_lock = true, color_period = true, data_to_server = true,
    idx_room = true, index_aux = true, index_weekly = true, loads_conf = true,
    not_keep_ls = true, num_cascade = true, pilot_mode = true, remote_control = true,
    sequence_rgb = true, split_flow = true, temperature_unit = true, true_white = true,
}

-- =============================================================================
-- DRIVER LOAD CLEANUP
-- When the Lua file is loaded/reloaded, this code runs immediately
-- =============================================================================

-- Force cleanup of any existing timers from previous driver instance.
-- C1 Phase 2 dropped the hand-rolled PROFLAMEPING keepalive (gPingTimerId);
-- the vendored WebSocket module owns the WS-level ping/pong now.
--
-- Legacy cleanup for OTA upgrade from pre-Phase-2 installs (Codex review of
-- PR #68 BLOCKER #3): if the old gPingTimerId global is still set when this
-- new code loads, it's a 5s repeating timer from the previous instance
-- pointing at the now-deleted OnPingTimer — left uncancelled, it fires every
-- 5s and produces a Lua runtime error. Cancel it explicitly. Similarly, the
-- pre-Phase-2 driver opened a NetConnect on static binding 6001; explicitly
-- NetDisconnect that so it doesn't linger and compete with the dynamically
-- allocated binding the vendored WebSocket module is about to grab.
if gPingTimerId then
    pcall(function() gPingTimerId:Cancel() end)
    gPingTimerId = nil
end
pcall(function()
    local port = 88
    if Properties and Properties["Port"] then port = tonumber(Properties["Port"]) or 88 end
    C4:NetDisconnect(6001, port)
end)
if gReconnectTimerId then
    pcall(function() gReconnectTimerId:Cancel() end)
    gReconnectTimerId = nil
end
if gConnectTimeoutTimerId then
    pcall(function() gConnectTimeoutTimerId:Cancel() end)
    gConnectTimeoutTimerId = nil
end
if gStatusRefreshTimerId then
    pcall(function() gStatusRefreshTimerId:Cancel() end)
    gStatusRefreshTimerId = nil
end
if gUpdateCheckTimerId then
    pcall(function() gUpdateCheckTimerId:Cancel() end)
    gUpdateCheckTimerId = nil
end
if gInitialUpdateCheckTimerId then
    pcall(function() gInitialUpdateCheckTimerId:Cancel() end)
    gInitialUpdateCheckTimerId = nil
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
if gTimerSafetyCheckTimer then
    pcall(function() gTimerSafetyCheckTimer:Cancel() end)
    gTimerSafetyCheckTimer = nil
end

-- Synchronous WebSocket teardown for the reload path. Codex round-2 review
-- of #68 flagged that just calling gWebSocket:Close() leaves the vendor's
-- 3-second Closing timer alive — a Phase-2 -> Phase-2 hot reload (driver
-- update, controller restart) lets that old timer fire NetDisconnect AFTER
-- the new instance has allocated a binding (potentially the same number, if
-- our explicit NetDisconnect below frees the old slot first). Same root
-- bug as the original BLOCKER #2 in Disconnect. We can't call our regular
-- TeardownWebSocket helper here because it lives much further down the
-- file and isn't defined yet, so we inline the critical parts: NetDisconnect
-- the old binding, clear the dispatch registries, bust the vendor's
-- Sockets caches, and release the binding address. The cleared globals
-- (OCS/RFN/WebSocket.Sockets) are FROM THE PREVIOUS INSTANCE — they survive
-- the Lua reload as top-level globals until the new bundled handlers.lua /
-- websocket.lua blocks run later in this file and reinitialize them.
if gWebSocket then
    pcall(function()
        local ws = gWebSocket
        local netBinding = ws.netBinding
        local port = ws.port or (Properties and tonumber(Properties["Port"])) or 88
        local url = ws.url
        local timerPrefix = ws.timerPrefix
        -- Cancel the vendored Ping/PongResponse/Closing timers from the
        -- previous instance. CancelTimer here is the OLD instance's vendored
        -- timer module (survives reload as a top-level global until the new
        -- timer.lua bundle below reinitializes it). C4:SetTimer handles
        -- survive Lua reloads, so without cancellation here the old Closing
        -- timer can still fire C4:NetDisconnect on whatever binding the new
        -- instance has allocated.
        if timerPrefix and type(CancelTimer) == "function" then
            pcall(function() CancelTimer(timerPrefix .. 'Ping') end)
            pcall(function() CancelTimer(timerPrefix .. 'PongResponse') end)
            pcall(function() CancelTimer(timerPrefix .. 'Closing') end)
        end
        if netBinding then
            pcall(function() C4:NetDisconnect(netBinding, port) end)
            if OCS then OCS[netBinding] = nil end
            if RFN then RFN[netBinding] = nil end
            if WebSocket and WebSocket.Sockets then
                WebSocket.Sockets[netBinding] = nil
            end
            pcall(function() C4:SetBindingAddress(netBinding, '') end)
        end
        if WebSocket and WebSocket.Sockets and url then
            WebSocket.Sockets[url] = nil
        end
    end)
    gWebSocket = nil
end

-- Load-time log buffer. The "Driver loading" / "Updated Driver Version
-- property" messages below run at the very top of the file, BEFORE the
-- vendored logging module (which provides the `log` global) and our dbg_*
-- helpers are defined. We can't route them through dbg_info() yet, so we
-- stash them here and flush the buffer through dbg_info() right after
-- log:setLogLevel() runs further down. This keeps our own code off raw
-- print() while preserving the at-load ordering of these lifecycle notes.
gLoadTimeLogBuffer = {}
local function _logAtLoad(msg)
    gLoadTimeLogBuffer[#gLoadTimeLogBuffer + 1] = tostring(msg)
end

-- Log that we're loading
_logAtLoad("[Proflame] Driver loading - Version " .. DRIVER_VERSION .. " (" .. DRIVER_DATE .. ")")

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

-- Firmware sub-version accumulator. Populated by ProcessStatusUpdate's
-- fw_* carve-out (see HANDLED_STATUS_KEYS / KNOWN_IGNORED_STATUS_KEYS
-- comments). Composed into the read-only "Firmware Versions" Composer
-- property whenever any of the 5 sub-fields changes. Field-name keys
-- match the device's wire-format names; presentation order is fixed in
-- FormatFirmwareVersions().
gFirmwareVersions = {
    fw_revision = "",
    fw_ble = "",
    fw_ifc_c = "",
    fw_ifc_s = "",
    fw_rc = "",
}

-- Device-reported temperature unit preference ("F" or "C"). Populated by
-- ProcessStatusUpdate's temperature_unit A3 carve-out (wire values "1"->F,
-- "0"->C; anything else defaults to F to preserve historical behavior).
-- Drives the display suffix in UpdateRoomTemperatureProperty(),
-- UpdatePropertiesForStatus()'s temperature_set branch, and
-- InitializePropertiesFromState() via TemperatureSuffix(). The wire
-- encoding (Fx10 integer) is NOT changed — only the trailing F/C glyph
-- that operators see in the Composer property pane.
gTemperatureUnit = "F"

-- Build timestamp for cache busting - this changes every build
BUILD_TIMESTAMP = "20260603-000005"

-- Try to update version property immediately on load
pcall(function()
    if C4 and C4.UpdateProperty then
        C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ") [" .. BUILD_TIMESTAMP .. "]")
        _logAtLoad("[Proflame] Updated Driver Version property at load time")
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
gReconnectTimerId = nil
gConnectTimeoutTimerId = nil
gStatusRefreshTimerId = nil
gUpdateCheckTimerId = nil
gInitialUpdateCheckTimerId = nil
gTimerModeDelayTimer = nil
gTimerStartDelayTimer = nil
gTimerSuppressClearTimer = nil
gTurnOffConfirmTimer = nil
gTurnOffRetryTimer = nil
gTurnOffRetryCount = 0
gTurnOffInProgress = false
gTimerSafetyCheckTimer = nil
gTimerSafetyOffPending = false
-- Vendored WebSocket object (drivers-common-public/module/websocket.lua).
-- Created in Connect() via WebSocket:new(url); owns the dynamically allocated
-- network binding (gWebSocket.netBinding, scanned from 6100-6199). Holds the
-- WS-level ping/pong timers and dispatches inbound text frames into our
-- OnWebSocketMessage callback after stripping framing/masking. Set back to
-- nil in Disconnect() so a stale handle can't dispatch onto a closed binding.
gWebSocket = nil
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
gFirmwareVersions = {
    fw_revision = "",
    fw_ble = "",
    fw_ifc_c = "",
    fw_ifc_s = "",
    fw_rc = "",
}
gTemperatureUnit = "F"

-- =============================================================================
-- LOGGING
-- Delegates to the `log` global provided by vendor/logging.lua (bundled
-- below in the VENDORED section). All call sites pass user-supplied strings
-- that may contain `%` characters, so we feed them through log:level("%s", s)
-- rather than as the format string itself.
-- =============================================================================

function Log(msg, level)
    log:log(level or log.LogLevel.INFO, "%s", tostring(msg))
end

-- Severity-tagged wrappers. Each takes a single argument and passes it as a
-- format ARGUMENT (not the format string itself) so `%` characters in device
-- responses don't trip string.format.
--
-- Naming convention (per the 2026-06-02 logging discipline refactor):
--   dbg_err   -> log:error  (true failures, refused/invalid input)
--   dbg_warn  -> log:warn   (recoverable / ignored / suppressed conditions)
--   dbg_info  -> log:info   (lifecycle, connection state, config changes)
--   dbg_debug -> log:debug  (wire data, status processing, command echo)
--   dbg_trace -> log:trace  (high-volume / rarely-needed debugging)
-- Plus the legacy `dbg_all` alias, identical to `dbg_debug`, kept for the
-- handful of call sites that already used it.
--
-- All of these route through `_guarded_log`, which sets `_c4_in_logger` around
-- the actual `log:*` call. That flag is the re-entrancy guard for the global
-- print() shadow installed further down (issue #69): when Debug Mode = On the
-- vendored logging module's _log() mirrors output to the controller console via
-- the bare global `print`, which is now our shadow. Setting the flag HERE (the
-- single chokepoint every driver log call funnels through) means the logger's
-- own mirror print() falls straight through to the real print, while genuine
-- external/vendor print() calls — which happen with the flag clear — are routed
-- into dbg_debug. Setting the flag only inside the shadow (the original #69
-- impl) missed this path: an ordinary dbg_info() call mirrors via print with the
-- flag clear, so the mirror line was wrongly re-routed back through dbg_debug
-- (doubled at Debug level, swallowed below it).
_c4_print = print  -- captured before the shadow replaces global print
_c4_in_logger = false
local function _guarded_log(level, msg)
    _c4_in_logger = true
    -- pcall + index-inside so a missing/half-initialized `log` can never turn a
    -- log call into a hard driver error, and the flag is always cleared.
    local ok, err = pcall(function() log[level](log, "%s", tostring(msg)) end)
    _c4_in_logger = false
    if not ok then _c4_print("Proflame log error: " .. tostring(err)) end
end

function dbg_err(msg)
    _guarded_log("error", msg)
end

function dbg_warn(msg)
    _guarded_log("warn", msg)
end

function dbg_info(msg)
    _guarded_log("info", msg)
end

function dbg_debug(msg)
    _guarded_log("debug", msg)
end

function dbg_trace(msg)
    _guarded_log("trace", msg)
end

function dbg_all(msg)
    _guarded_log("debug", msg)
end

-- =============================================================================
-- GLOBAL print() SHADOW (issue #69)
--
-- The vendored drivers-common-public/module/websocket.lua (and other vendor
-- modules) call the bare global `print(...)` in several spots — :Start(),
-- the keepalive timeout path, ConnectionChanged, etc. Those calls bypass the
-- driver's Debug Mode / Debug Level Composer gating and the module's own
-- DEBUG_WEBSOCKET flag, producing log noise during reconnect loops. We do NOT
-- edit the vendored file (it must stay byte-identical to upstream for
-- re-sync), so instead we shadow the global `print` here and forward its
-- arguments through dbg_debug — which is gated by the configured log level.
--
-- `print` is resolved as a global at call time, so installing the shadow now
-- (during driver load, before any vendored function runs at runtime) is
-- sufficient to intercept every later vendored print().
--
-- Re-entrancy: when Debug Mode = On the vendored logging module's _log()
-- mirrors output to the controller console via the bare global `print` — i.e.
-- this shadow. The `_c4_in_logger` flag (set by `_guarded_log`, the chokepoint
-- every dbg_* call funnels through, defined above) tells us we're already
-- inside a driver log call, so the logger's own mirror print() must pass
-- straight through to the captured original `print` rather than re-route back
-- into dbg_debug. Genuine external/vendor print() calls arrive with the flag
-- clear and get routed into dbg_debug (gated by the configured log level).
-- `_c4_print` and `_c4_in_logger` are file-level globals (set above, before the
-- dbg_* helpers) so they're reachable here regardless of any vendor bundle
-- insert that lands between the two points.
-- luacheck: globals print
print = function(...)
    if _c4_in_logger then
        -- Re-entry from the logger's own console mirror: emit via the real
        -- print so we don't loop, and so Debug Mode's console output still
        -- works.
        return _c4_print(...)
    end
    -- Concatenate varargs (tostring-ing each, nil-safe) with spaces, matching
    -- Lua's built-in print() field separator.
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    local msg = table.concat(parts, " ")
    if type(dbg_debug) == "function" then
        -- dbg_debug -> _guarded_log sets _c4_in_logger, so the logger's mirror
        -- print() lands in the pass-through branch above. No loop.
        dbg_debug(msg)
    else
        _c4_print(msg)
    end
end

-- Maps the Composer "Debug Level" property values to vendor LogLevel constants.
DEBUG_LEVEL_MAP = {
    Error = DEBUG_ERROR,
    Warning = DEBUG_WARN,
    Info = DEBUG_INFO,
    Debug = DEBUG_DEBUG,
    Trace = DEBUG_TRACE,
}

function ApplyDebugLogSettings()
    local mode = (Properties and Properties["Debug Mode"] == "On") and "Print and Log" or ""
    log:setLogMode(mode)
    local levelName = Properties and Properties["Debug Level"]
    log:setLogLevel(DEBUG_LEVEL_MAP[levelName] or DEBUG_DEBUG)
end

-- =============================================================================
-- EVENTS
-- =============================================================================

function IsFireplaceOnMode(mode)
    return mode == MODE_MANUAL or mode == MODE_SMART or mode == MODE_ECO
end

function IsFireplaceOffMode(mode)
    return mode == MODE_OFF or mode == MODE_STANDBY or mode == MODE_STANDBY_ALT
end

function FireDriverEvent(eventId, eventName)
    dbg_info("Firing event: " .. tostring(eventName) .. " (" .. tostring(eventId) .. ")")
    C4:FireEventByID(eventId)
end

function HandleModeEvents(newMode)
    if gLastMainMode == nil then
        gLastMainMode = newMode
        dbg_info("Mode event baseline set: " .. tostring(newMode))
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
-- VENDORED: JSON.lua by Jeffrey Friedl
-- http://regex.info/blog/lua/json -- version 20211016.28
-- Released under Creative Commons CC-BY 3.0
-- =============================================================================

-- Required by the vendored JSON.lua encoder; aliasing tostring is locale-safe
-- on the en_US Control4 controller (no decimal-comma locales in play).
function tostring_return_period(v)
    return tostring(v)
end

-- BUNDLE_INSERT vendor/JSON.lua

-- BUNDLE_INSERT vendor/logging.lua

-- BUNDLE_INSERT vendor/persist.lua

-- BUNDLE_INSERT vendor/deferred.lua

-- BUNDLE_INSERT vendor/version.lua

-- BUNDLE_INSERT vendor/lib_helpers.lua

-- BUNDLE_INSERT vendor/http.lua

-- BUNDLE_INSERT vendor/github_updater.lua

-- =============================================================================
-- VENDORED: Snap One drivers-common-public (WebSocket module + deps)
--
-- C1 Phase 1 vendors the upstream Snap One WebSocket helper and its full
-- transitive Lua dependency tree. The five files below are byte-identical to
-- snap-one/drivers-common-public master and live under
-- vendor/drivers-common-public/ preserving the upstream directory layout. The
-- bundle order below is load-bearing: lib registers Select/CopyTable/JSON
-- helpers; timer registers SetTimer/CancelTimer; metrics returns the Metrics
-- factory; handlers reads Metrics/lib at top-level and registers
-- OCS/RFN/OPC/etc. dispatch tables plus framework handler functions; websocket
-- reads handlers/timer/Metrics globals and returns the WebSocket factory.
--
-- Phase 1 is INERT for our hot paths: nothing in this driver calls
-- WebSocket:new() yet, and the five framework handlers our driver overrides
-- (OnConnectionStatusChanged, OnPropertyChanged, ReceivedFromNetwork,
-- ExecuteCommand, ReceivedFromProxy) defined inside handlers.lua are
-- immediately shadowed by our hand-rolled versions further down this file.
--
-- Caveat (Codex review of #67): handlers.lua additionally defines top-level
-- OnBindingChanged, OnDeviceEvent, OnSystemEvent, OnVariableChanged,
-- OnWatchedVariableChanged, TestCondition, and UIRequest. Our driver does NOT
-- define these, so the vendored versions are now live. Each dispatches
-- through an empty registry table (OBC, ODE, OSE, OVC, OWVC, etc.) — with
-- nothing registered against those tables, every call is a no-op that returns
-- nil. Phase 1 makes these reachable; Phase 2 will either register against
-- them (the framework-native path) or continue ignoring them.

--
-- The vendored files require()-import each other (e.g. handlers.lua does
-- `require('drivers-common-public.global.lib')`). The shim below makes those
-- requires no-ops that return the appropriate already-bundled global so the
-- top-level executable code in each vendor file works under the bundled
-- single-file deployment model that Control4 uses. require() for any string
-- not in this map falls through to the original loader (nil under DriverWorks,
-- the real Lua loader under our test harness).
-- =============================================================================

do  -- Snap One require shim
    local _vendored_modules = {
        -- handlers.lua and (transitively) lib.lua both require this. Our own
        -- vendor/JSON.lua is already bundled above as the global `JSON`, so
        -- return that — preserves the encoder we already use everywhere else.
        ['drivers-common-public.module.json']     = function() return JSON end,
        -- The remaining four are bundled inline below. By the time any
        -- require() for them executes, the corresponding bundled block has
        -- already run and registered its globals (Metrics / WebSocket /
        -- top-level functions). Returning the published global is the closest
        -- analogue to what the real Lua loader would hand back.
        ['drivers-common-public.global.lib']      = function() return nil end,
        ['drivers-common-public.global.timer']    = function() return nil end,
        ['drivers-common-public.global.handlers'] = function() return nil end,
        ['drivers-common-public.module.metrics']  = function() return Metrics end,
        ['drivers-common-public.module.websocket']= function() return WebSocket end,
    }
    local _original_require = require
    -- luacheck: globals require
    require = function(modname)
        local entry = _vendored_modules[modname]
        if entry then return entry() end
        if _original_require then return _original_require(modname) end
        error('require not available for module: ' .. tostring(modname))
    end
end

-- BUNDLE_INSERT vendor/drivers-common-public/global/lib.lua

-- BUNDLE_INSERT vendor/drivers-common-public/global/timer.lua

-- BUNDLE_INSERT vendor/drivers-common-public/module/metrics.lua

-- BUNDLE_INSERT vendor/drivers-common-public/global/handlers.lua

-- BUNDLE_INSERT vendor/drivers-common-public/module/websocket.lua

-- Initial log configuration. ApplyDebugLogSettings() above re-applies these
-- from Composer Properties in OnDriverLateInit and OnPropertyChanged.
-- Sentinel ordering is load-bearing: JSON must come before logging (logging's
-- table-renderer uses JSON:encode) and before persist (persist serializes via
-- JSON:encode/decode). Adding a new vendored library? Add it after the libs
-- it depends on.
log:setLogName("Proflame")
log:setLogMode("Print and Log")
log:setLogLevel(DEBUG_DEBUG)

-- Flush the load-time log buffer now that `log` and dbg_info exist. These are
-- the "Driver loading" / "Updated Driver Version property" lifecycle notes
-- captured at the top of the file before the logger was available (issue #69:
-- our own code no longer depends on raw print). NOTE: the logger is still at
-- its load-time default here (mode "Print and Log", level DEBUG_DEBUG, set just
-- above) — OnDriverLateInit applies the Composer-configured Debug Mode/Level
-- later — so these banner lines are emitted UNCONDITIONALLY at load, preserving
-- the old raw-print banner's always-visible behavior. They are NOT gated by the
-- user's Debug Level; only later runtime logging is.
if gLoadTimeLogBuffer then
    for _, _bufferedMsg in ipairs(gLoadTimeLogBuffer) do
        dbg_info(_bufferedMsg)
    end
    gLoadTimeLogBuffer = nil
end

-- =============================================================================
-- JSON HELPERS (thin wrappers over vendored JSON.lua)
-- =============================================================================

function JsonEncode(tbl)
    if type(tbl) ~= "table" then return "{}" end
    local ok, encoded = pcall(JSON.encode, JSON, tbl)
    return ok and encoded or "{}"
end

function JsonEscape(value)
    local s = tostring(value or "")
    local ok, literal = pcall(JSON.encode, JSON, s)
    if not ok or type(literal) ~= "string" or #literal < 2 then return s end
    return literal:sub(2, -2)
end

function JsonDecode(str)
    if type(str) ~= "string" or str == "" then return {} end
    local ok, parsed = pcall(JSON.decode, JSON, str)
    if not ok or type(parsed) ~= "table" then return {} end
    local out = {}
    for k, v in pairs(parsed) do
        local key = tostring(k)
        if type(v) == "string" then
            out[key] = v
        elseif type(v) == "number" then
            out[key] = tostring(v)
        elseif type(v) == "boolean" then
            out[key] = v and "true" or "false"
        end
    end
    return out
end


-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- The two builders below depend on JSON.lua sorting object keys alphabetically
-- so the emitted wire format matches the documented order:
--   set_control: command < name < value
--   legacy:     control0 < value0
-- Any new key added to either table must preserve that ordering, or the
-- Proflame parser may reject (or silently re-interpret) the payload.
function BuildSetControlCommand(control, value)
    return JSON:encode({ command = "set_control", name = tostring(control), value = tostring(value) })
end

function BuildLegacyIndexedCommand(control, value)
    return JSON:encode({ control0 = tostring(control), value0 = tostring(value) })
end

function BuildDeviceControlCommandPlan(control, value, format)
    local documented = {
        label = "documented",
        payload = BuildSetControlCommand(control, value)
    }
    local legacy = {
        label = "legacy",
        payload = BuildLegacyIndexedCommand(control, value)
    }

    if format == COMMAND_FORMAT_LEGACY_ONLY or format == COMMAND_FORMAT_TURN_OFF_LEGACY_ONLY then
        return { legacy }
    elseif format == COMMAND_FORMAT_DOCUMENTED_ONLY then
        return { documented }
    elseif format == COMMAND_FORMAT_DUAL_LEGACY_FIRST then
        return { legacy, documented }
    end
    return { documented, legacy }
end

function DecodeTemperature(encoded)
    local temp = tonumber(encoded) or 700
    return temp / 10
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
    elseif mode == MODE_STANDBY or mode == MODE_STANDBY_ALT then return "Standby"
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
    if IsFireplaceOffMode(mode) and timerStatus ~= 1 then
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
    dbg_debug("Updating timer extras (minutes changed)")
    SetupExtras()
end

-- =============================================================================
-- TIMERS
-- =============================================================================

-- C1 Phase 2 dropped the hand-rolled PROFLAMEPING text-frame keepalive
-- (StartPingTimer/StopPingTimer/OnPingTimer) and the associated
-- "Ping Interval (seconds)" Composer property + gPingTimerId global. The
-- vendored drivers-common-public/module/websocket.lua now runs a 30s
-- WS-level ping/pong (opcode 0x09/0x0A) with a 10s pong-response timeout
-- — that's the correct keepalive mechanism per RFC 6455, and the 2026-06-03
-- probe (tools/probes/evidence/characterize-20260603T024355Z.json
-- ws_ping.ws_pong_received=true) confirms the device replies to it.
function OnReconnectTimer()
    gReconnectTimerId = nil
    if not gConnected and not gConnecting then
        dbg_info("Reconnect timer fired")
        Connect()
    end
end

-- Periodic status-refresh timer. The 2026-06-02 probe (tools/probes/FINDINGS.md
-- §8) showed the Proflame device does NOT push spontaneously during idle
-- silence — 0 frames in a 10s silent window. So local-panel state changes
-- (someone pressing a button on the physical fireplace control) are invisible
-- to the driver until the next user-initiated command or reconnect.
--
-- This periodically resends PROFLAMECONNECTION which triggers the device's
-- full status dump (5 frames, ~85 status pairs), letting us pick up any
-- local-side changes. Default 5 minutes; 0 disables. The PROFLAMEPING
-- keepalive at 5s continues to run independently.
function StartStatusRefreshTimer()
    StopStatusRefreshTimer()
    local minutes = tonumber(Properties["Status Refresh Interval (minutes)"]) or 5
    if minutes <= 0 then
        dbg_info("Status refresh timer disabled (Status Refresh Interval = 0)")
        return
    end
    local intervalMs = minutes * 60 * 1000
    gStatusRefreshTimerId = C4:SetTimer(intervalMs, function(timer)
        if gConnected and gHandshakeComplete then
            dbg_info("Status refresh timer fired; requesting full status dump from device")
            RequestAllStatus()
        end
    end, true)
end

function StopStatusRefreshTimer()
    if gStatusRefreshTimerId then
        gStatusRefreshTimerId:Cancel()
        gStatusRefreshTimerId = nil
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

-- Connect-attempt watchdog (issue #71). Between ws:Start() and the first
-- callback there is NO liveness timer: the vendored module only arms its
-- ping/pong watchdog after the binding goes ONLINE (websocket.lua
-- ConnectionChanged), and our reconnect timer is one-shot and refuses to
-- fire while gConnecting is true. So if C4:NetConnect against an unreachable
-- device never produces an OFFLINE ConnectionChanged, gConnecting stays true
-- forever, OnWebSocketOffline never runs, nothing reschedules, and the UI
-- sticks at "Connecting..." indefinitely. This timer guarantees forward
-- progress: if neither Established nor Offline has cleared gConnecting by the
-- timeout, force a teardown and reschedule. Armed in Connect(), cancelled in
-- OnWebSocketEstablished / OnWebSocketOffline / Disconnect.
function StartConnectTimeoutTimer()
    StopConnectTimeoutTimer()
    local seconds = tonumber(Properties["Connect Timeout (seconds)"]) or 30
    -- The Composer property is RANGED_INTEGER min 5, so the watchdog can't be
    -- disabled from the UI (Codex review of #72: a 0-disable would reopen the
    -- exact stuck-in-Connecting bug this fixes). This guard is purely
    -- defensive against a nil/garbage Properties value that slipped past the
    -- `or 30` fallback (e.g. a negative literal) — never schedule a 0ms timer.
    if seconds <= 0 then
        return
    end
    gConnectTimeoutTimerId = C4:SetTimer(seconds * 1000, function(timer) OnConnectTimeout() end, false)
end

function StopConnectTimeoutTimer()
    if gConnectTimeoutTimerId then
        gConnectTimeoutTimerId:Cancel()
        gConnectTimeoutTimerId = nil
    end
end

function OnConnectTimeout()
    gConnectTimeoutTimerId = nil
    -- Only act if we're still mid-connect. A successful Established or a clean
    -- Offline would have cancelled this timer; if it fired anyway and we're
    -- already connected/idle, do nothing.
    if gConnected or not gConnecting then
        return
    end
    dbg_warn("Connect attempt timed out; tearing down and rescheduling")
    TeardownWebSocket(false)
    gConnecting = false
    gHandshakeComplete = false
    C4:UpdateProperty("Connection Status", "Disconnected")
    ScheduleReconnect()
end

-- =============================================================================
-- WEBSOCKET
-- =============================================================================
--
-- C1 Phase 2 deleted the 9 hand-rolled WebSocket helpers that used to live
-- here (GenerateWebSocketKey, BuildWebSocketHandshake, ParseHttpHeaders,
-- ExpectedWebSocketAccept, ValidateHandshakeResponse, CreateWebSocketFrame,
-- ParseWebSocketFrame, SendWebSocketMessage, SendPing, SendPong). The vendored
-- drivers-common-public/module/websocket.lua now owns RFC 6455 framing,
-- masking, fragmentation, the upgrade handshake (MakeHeaders/parseHTTPPacket),
-- and the WS-level ping/pong keepalive. We talk to it through gWebSocket
-- and the four callbacks below (Established / ProcessMessage / Offline /
-- ClosedByRemote). See OnWebSocketMessage for the app-protocol decode that
-- used to be at the bottom of the old ReceivedFromNetwork loop.

-- =============================================================================
-- NETWORK
-- =============================================================================

function Connect()
    local ipAddress = Properties["IP Address"]
    if not ipAddress or ipAddress == "" then
        C4:UpdateProperty("Connection Status", "Not Configured")
        return
    end
    if gWebSocket then
        -- Already have a socket — either connecting, connected, or in the
        -- 3-second close window. WebSocket:new(url) would return the cached
        -- one anyway; bailing here keeps Connect() idempotent so the
        -- IP/Port change handlers and OnDriverLateInit can both call it
        -- without stacking sockets.
        return
    end
    local port = tonumber(Properties["Port"]) or 88
    gConnecting = true
    gHandshakeComplete = false
    C4:UpdateProperty("Connection Status", "Connecting...")
    local url = string.format("ws://%s:%d/", ipAddress, port)
    local ws, err = WebSocket:new(url)
    if not ws then
        dbg_err("WebSocket:new() failed: " .. tostring(err))
        gConnecting = false
        C4:UpdateProperty("Connection Status", "Disconnected")
        ScheduleReconnect()
        return
    end
    -- Vendor's setupC4Connection scans bindings 6100-6199 for a free slot;
    -- if all are occupied it leaves netBinding nil but still returns the
    -- ws object (Codex review of #68 DESIGN #4). Without netBinding, :Start
    -- silently no-ops and no callback ever fires — UI would stick at
    -- "Connecting..." forever. Catch it here and reschedule.
    if not ws.netBinding then
        dbg_err("WebSocket:new() returned with no allocated binding (6100-6199 all busy?)")
        if WebSocket and WebSocket.Sockets then
            WebSocket.Sockets[url] = nil
        end
        gConnecting = false
        C4:UpdateProperty("Connection Status", "Disconnected")
        ScheduleReconnect()
        return
    end
    gWebSocket = ws
    ws:SetEstablishedFunction(OnWebSocketEstablished)
    ws:SetProcessMessageFunction(OnWebSocketMessage)
    ws:SetOfflineFunction(OnWebSocketOffline)
    ws:SetClosedByRemoteFunction(OnWebSocketClosedByRemote)
    -- Arm the connect-attempt watchdog (issue #71) before Start() so the whole
    -- connecting window is covered. Cancelled by OnWebSocketEstablished (success)
    -- or OnWebSocketOffline (clean failure); fires only if neither callback
    -- arrives in time.
    StartConnectTimeoutTimer()
    ws:Start()
end

-- Synchronous WebSocket teardown shared by Disconnect (user-initiated) and
-- OnWebSocketOffline (vendor-callback initiated). The vendored :Close()
-- schedules a 3-second NetDisconnect+cleanup timer (vendor/.../websocket.lua
-- wsObject:Close). That delay is the root of Codex BLOCKER #2: a fast
-- Disconnect+Connect cycle (e.g. Port-property edit calls Disconnect then
-- Connect 500ms later) leaves Sockets[url] cached so WebSocket:new(url)
-- returns the dying object, and 2.5s later the old close timer fires
-- NetDisconnect on the now-active binding, killing the new connection.
--
-- Fix: do the teardown synchronously here. Send the close frame if the
-- socket is still connected, cancel the vendored ping/pong/closing timers,
-- NetDisconnect the binding immediately, clear OCS/RFN dispatch entries,
-- and bust both the URL and binding caches in WebSocket.Sockets so the
-- next WebSocket:new(url) allocates a fresh object on a fresh binding.
function TeardownWebSocket(sendCloseFrame)
    if not gWebSocket then return end
    local ws = gWebSocket
    gWebSocket = nil
    pcall(function()
        local netBinding = ws.netBinding
        local port = ws.port
        local url = ws.url
        local timerPrefix = ws.timerPrefix
        if sendCloseFrame and ws.connected then
            -- RFC 6455 close frame, status 1000 (normal). Same bytes the
            -- vendor :Close() sends; we send it here so the device still
            -- sees a graceful close before NetDisconnect tears the socket.
            local closePkt = string.char(0x88, 0x82, 0x00, 0x00, 0x00, 0x00, 0x03, 0xE8)
            pcall(function() ws:sendToNetwork(closePkt) end)
        end
        ws.running = false
        ws.connected = false
        if type(CancelTimer) == "function" then
            pcall(function() CancelTimer(timerPrefix .. 'Ping') end)
            pcall(function() CancelTimer(timerPrefix .. 'PongResponse') end)
            pcall(function() CancelTimer(timerPrefix .. 'Closing') end)
        end
        if netBinding then
            pcall(function() C4:NetDisconnect(netBinding, port) end)
            if OCS then OCS[netBinding] = nil end
            if RFN then RFN[netBinding] = nil end
            if WebSocket and WebSocket.Sockets then
                WebSocket.Sockets[netBinding] = nil
            end
            pcall(function() C4:SetBindingAddress(netBinding, '') end)
        end
        if WebSocket and WebSocket.Sockets and url then
            WebSocket.Sockets[url] = nil
        end
    end)
end

function Disconnect()
    StopStatusRefreshTimer()
    StopConnectTimeoutTimer()
    CancelPendingTimerCommandTimers()
    CancelTurnOffConfirmTimer()
    if gSuppressTimerUpdates then
        SetTimerSuppression(false, "disconnect")
    end
    ClearTurnOffInProgress("disconnect")
    TeardownWebSocket(true)  -- send close frame on the way out
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    gStatusSeen = {}
    HandleConnectionEvent(false)
    C4:UpdateProperty("Connection Status", "Disconnected")
end

function Reconnect()
    Disconnect()
    ScheduleReconnect()
end

-- Send a single app-protocol text frame through the vendored WebSocket. The
-- vendored :Send() wraps the payload in an opcode-0x01 frame with masking
-- and emits it on the dynamically-allocated binding. Returns false if we
-- have no socket or the handshake hasn't completed (matches the behavior
-- of the old SendWebSocketMessage that fronted CreateWebSocketFrame).
function SendWebSocketMessage(message)
    if not gWebSocket or not gConnected or not gHandshakeComplete then
        return false
    end
    gWebSocket:Send(message)
    return true
end

function SendDeviceControlWithFormat(control, value, format, context)
    -- This low-level sender intentionally does not check gTurnOffInProgress.
    -- Public command paths should use SendDeviceControl unless they are part
    -- of the Turn Off sequence that must run while the guard is active.
    if not gConnected or not gHandshakeComplete then
        dbg_err("Refusing device command while disconnected or handshaking: " .. tostring(control) .. "=" .. tostring(value))
        return false
    end

    local plan = BuildDeviceControlCommandPlan(control, value, format)
    local sent = false
    for _, command in ipairs(plan) do
        local prefix = context and ("Sending " .. tostring(context) .. " " .. command.label .. " command: ") or ("Sending " .. command.label .. " command: ")
        dbg_debug(prefix .. command.payload)
        sent = SendWebSocketMessage(command.payload) or sent
    end
    return sent
end

function SendDeviceControl(control, value)
    if gTurnOffInProgress then
        dbg_err("Refusing device command while turn off is pending: " .. tostring(control) .. "=" .. tostring(value))
        return false
    end

    local format = Properties["Command Format (non-Turn-Off)"] or COMMAND_FORMAT_LEGACY_ONLY
    return SendDeviceControlWithFormat(control, value, format, nil)
end

function RequestAllStatus()
    -- The Proflame device requires PROFLAMECONNECTION to trigger full status dump.
    -- After C1 Phase 2, the WS-level ping/pong owned by the vendored
    -- websocket.lua handles connection-liveness checking; PROFLAMECONNECTION
    -- is purely an app-protocol full-status-refresh request.
    dbg_debug("Sending PROFLAMECONNECTION to request full status")
    SendWebSocketMessage("PROFLAMECONNECTION")
end

function BuildThermostatDynamicCapabilities()
    -- Keep UI capability experiments in runtime notifications where possible.
    -- Static driver.xml capability changes can trigger heavier Controller/Director reloads.
    -- Match the casing already used by the static XML and README examples.
    return {
        HAS_EXTRAS = "true",
        CAN_PRESET = "False",
        CAN_PRESET_SCHEDULE = "False",
        HOLD_MODES = FLAME_HOLD_MODES,
        FAN_MODES = "Off,Low,Medium,High"
        -- HVAC_MODES / HVAC_STATES intentionally omitted (issue #64): they are
        -- constant for this heat-only device, already declared statically in
        -- driver.xml (<hvac_modes>/<hvac_states>), and the allowed-mode subset is
        -- emitted separately via ALLOWED_HVAC_MODES_CHANGED in
        -- SendThermostatAllowedModes. They are not part of DYNAMIC_CAPABILITIES_CHANGED.
    }
end

function SendThermostatDynamicCapabilities(reason)
    local capabilities = BuildThermostatDynamicCapabilities()
    -- SDK-supported hold labels are limited, so Navigator may not render custom labels under the button.
    -- Treat this runtime capability refresh as a best-effort probe; some Navigators may ignore it.
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "DYNAMIC_CAPABILITIES_CHANGED", capabilities)
    dbg_info("Thermostat dynamic capabilities refreshed" .. (reason and (": " .. tostring(reason)) or ""))
end

function SendThermostatAllowedModes(reason)
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "ALLOWED_FAN_MODES_CHANGED", { MODES = "Off,Low,Medium,High" })
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "ALLOWED_HVAC_MODES_CHANGED", { MODES = "Off,Heat" })
    dbg_info("Thermostat allowed modes refreshed" .. (reason and (": " .. tostring(reason)) or ""))
end

function RefreshThermostatUiSurface(reason, includeExtras)
    SendThermostatDynamicCapabilities(reason)
    SendThermostatAllowedModes(reason)

    UpdateThermostatProxy()
    UpdateThermostatSetpoint()
    UpdateRoomTemperature()
    UpdateFanMode()
    UpdateFlameLevel()
    UpdateHoldModeFromFlame()
    UpdateExtrasState()

    if includeExtras then
        SetupExtras()
    end
end

function UpdateAllProxies()
    RefreshThermostatUiSurface("UpdateAllProxies", true)
end

function UpdateHoldModeCapabilities()
    SendThermostatDynamicCapabilities("hold mode refresh")
end

function UpdateRoomTemperatureProperty()
    local tempEncoded = gState.room_temperature or "700"
    local tempF = DecodeTemperature(tempEncoded)
    C4:UpdateProperty("Room Temperature", tostring(tempF) .. TemperatureSuffix())
end

function UpdateRoomTemperatureProxy()
    local tempEncoded = gState.room_temperature or "700"
    local tempF = DecodeTemperature(tempEncoded)
    local tempC = FahrenheitToCelsius(tempF)
    dbg_debug("Sending room temperature to proxy: " .. tempF .. "F (" .. tempC .. "C)")
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
    dbg_debug("SetPendingSetpoint locked: " .. tostring(tempF))
    if gPendingTimer then gPendingTimer:Cancel() end
    gPendingTimer = C4:SetTimer(5000, function()
        dbg_warn("Pending setpoint timer expired, unlocking")
        gPendingSetpointF = nil
    end, false)
end

-- =============================================================================
-- STATUS PARSING
-- =============================================================================

function ParseStatusMessage(data)
    if not data then return end
    if data == "PROFLAMEPONG" then
        -- PROFLAMEPING is gone (C1 Phase 2 dropped the app-level keepalive),
        -- so we never solicit a PROFLAMEPONG. The device also does not emit it
        -- spontaneously (the 2026-06-02 probe saw 0 frames in a 10s silent
        -- window), which made the old "Last Ping Response" property dead UI —
        -- it was removed in #70. We still swallow any stray PROFLAMEPONG echo
        -- here so it is not logged as an unknown frame.
        dbg_debug("PROFLAMEPONG echo received")
        return
    end
    if data == "PROFLAMECONNECTIONOPEN" then
        dbg_info("Connection acknowledged by device")
        C4:UpdateProperty("Connection Status", "Connected")
        HandleConnectionEvent(true)
        return
    end
    if data:sub(1, 1) == "{" then
        dbg_debug("Received JSON: " .. data:sub(1, 200))
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

        -- Direct key-value format from device status response. ProcessStatusUpdate
        -- handles the HANDLED / KNOWN_IGNORED / unknown classification internally
        -- so we no longer need a separate "is this known?" guard here. The
        -- field-name mappings (rssi -> wifi_signal_str, temperature_read ->
        -- room_temperature, timer_read -> timer_count) translate device-side
        -- names to the canonical names ProcessStatusUpdate / ApplyDeviceStatus
        -- expect.
        local fieldMap = {
            rssi = "wifi_signal_str",
            temperature_read = "room_temperature",
            timer_read = "timer_count",
        }

        for key, value in pairs(json) do
            if not key:match("^status%d+$") and not key:match("^value%d+$") then
                ProcessStatusUpdate(fieldMap[key] or key, value)
            end
        end
    end
end

-- Decodes a single already-unframed text payload from the device. The
-- vendored WebSocket module strips RFC 6455 framing/masking and hands us
-- the raw application payload via the :SetProcessMessageFunction callback,
-- so this is the entry point for our app-protocol decode
-- (PROFLAMECONNECTIONOPEN / PROFLAMEPONG / JSON status frames). It's the
-- factored-out equivalent of the per-frame branch that used to live inside
-- the old hand-rolled ReceivedFromNetwork loop. Reusable from the
-- probe-replay test in test/test_websocket_integration.lua.
function HandleProflameMessage(data)
    ParseStatusMessage(data)
end

-- Returns a change table consumed by property/proxy/event/Extras adapters.
-- Required fields: status, value. Optional fields: timerCleared,
-- timerExpired, timerExtras, newCount.
function ApplyDeviceStatus(status, value)
    if status == "temperature_set" then
        local incomingF = DecodeTemperature(value)
        if gPendingSetpointF ~= nil then
            if math.abs(incomingF - gPendingSetpointF) < 1 then
                dbg_debug("Pending setpoint confirmed: " .. incomingF)
                gPendingSetpointF = nil
            else
                dbg_warn("Ignoring stale setpoint: " .. incomingF)
                return
            end
        end
    end

    if status == "main_mode" then
        gState.main_mode = value
        if gTurnOffInProgress and IsFireplaceOffMode(value) then
            ClearTurnOffInProgress("confirmed off mode " .. tostring(value))
        elseif gTurnOffInProgress and IsFireplaceOnMode(value) then
            dbg_warn("Turn off still pending; ignoring on-mode echo: " .. tostring(value))
            ScheduleTurnOffRetry("on-mode echo " .. tostring(value))
            return
        end
        if IsFireplaceOffMode(value) and not gSuppressTimerUpdates then
            gTimerSafetyOffPending = false
            CancelTimerSafetyCheck()
            gState.timer_set = "0"
            gState.timer_count = "0"
            return { status = status, value = value, timerCleared = true, timerExtras = true }
        end
        return { status = status, value = value }
    elseif status == "timer_status" then
        -- Skip timer_status updates while we're actively setting the timer
        if gSuppressTimerUpdates then
            dbg_warn("Timer status update suppressed: " .. tostring(value))
            return
        end
        gState.timer_status = value
        -- If timer becomes active, clear the expired flag
        if value == "1" then
            gTimerExpired = false
            gTimerSafetyOffPending = false
            CancelTimerSafetyCheck()
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
        dbg_debug("Device timer_set: " .. tostring(value) .. " ms (" .. minutes .. " minutes), our timer_set: " .. tostring(gState.timer_set))
        return
    elseif status == "timer_count" then
        -- Skip timer_count updates while we're actively setting the timer
        if gSuppressTimerUpdates then
            dbg_warn("Timer count update suppressed: " .. tostring(value))
            return
        end

        -- Ignore timer_count updates when timer has expired (device sends default values)
        if gTimerExpired then
            dbg_warn("Timer count ignored (timer expired): " .. tostring(value))
            return
        end

        -- Ignore timer_count updates when fireplace is off/standby or timer is disabled
        -- The device sends default timer values when entering standby which we should ignore
        local mode = gState.main_mode
        if IsFireplaceOffMode(mode) then
            dbg_warn("Timer count ignored (mode=" .. tostring(mode) .. "): " .. tostring(value))
            return
        end
        if gState.timer_status == "0" then
            dbg_warn("Timer count ignored (timer_status=0): " .. tostring(value))
            return
        end

        local newCount = tonumber(value) or 0
        local newMinutes = math.floor(newCount / 60000)

        -- Get old minutes from timer_count (for detecting minute changes)
        local oldCount = tonumber(gState.timer_count) or 0
        local oldMinutes = math.floor(oldCount / 60000)

        -- Detect timer expiry: count reaches 0
        if newCount == 0 and oldCount > 0 then
            dbg_info("Timer expired (count reached 0)")
            gTimerExpired = true
            gState.timer_count = "0"
            gState.timer_set = "0"
            return { status = status, value = value, timerExpired = true, timerExtras = true }
        end

        -- Store the raw count
        gState.timer_count = value
        local change = { status = status, value = value, newCount = newCount }
        dbg_debug("Timer count: " .. newCount .. "ms (" .. newMinutes .. "m), old count: " .. oldCount .. "ms (" .. oldMinutes .. "m)")
        if oldMinutes ~= newMinutes then
            dbg_debug("Timer minute changed: " .. oldMinutes .. " -> " .. newMinutes .. ", updating slider")
            -- Update timer_set to match for slider display
            gState.timer_set = tostring(newMinutes * 60000)
            change.timerExtras = true
        end
        return change
    elseif status == "room_temperature" or status == "temperature_read" then
        gState.room_temperature = value
        dbg_debug("Room temperature updated: " .. value .. " (raw) = " .. DecodeTemperature(value) .. "F")
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
        C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(value) .. TemperatureSuffix())
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

-- Defense-in-depth scrub for device-controlled strings before they reach a log
-- line or a Composer STRING property. Replaces ALL Lua control characters
-- (`%c`: \0-\31 plus \127) with a single space so a buggy/hostile device can't
-- inject newline + forged "[ERROR]: ..." prefixes into our logs, and so
-- Composer's property pane / CSV export doesn't render literal control bytes.
-- Optional max_len truncates oversize values with an ellipsis. Returns "" for
-- nil input. Used by CaptureFirmwareVersion (B1), CaptureTemperatureUnit (A3),
-- and the unknown-status-key WARN branch in ProcessStatusUpdate. Addresses
-- GitHub issue #58.
function SanitizeDeviceString(s, max_len)
    if s == nil then return "" end
    local result = tostring(s):gsub("%c", " ")
    if max_len and #result > max_len then
        result = result:sub(1, max_len) .. "..."
    end
    return result
end

-- Display suffix ("F" or "C") used everywhere the driver writes a
-- human-readable temperature string into a Composer STRING property. Derived
-- from gTemperatureUnit which itself is captured from the device's
-- `temperature_unit` status key by CaptureTemperatureUnit. Defaults to "F" if
-- the device hasn't reported a unit yet — matches the historical hard-coded
-- behavior so existing operators see no change.
function TemperatureSuffix()
    if gTemperatureUnit == "C" then return "C" end
    return "F"
end

-- Composer-friendly display string for the "Temperature Unit" property.
-- Returns "Fahrenheit" or "Celsius" instead of the raw "1"/"0" the device
-- sends. Defaults to "Fahrenheit" for symmetry with TemperatureSuffix().
function TemperatureUnitDisplay()
    if gTemperatureUnit == "C" then return "Celsius" end
    return "Fahrenheit"
end

-- Captures the device's `temperature_unit` status into gTemperatureUnit and
-- re-emits the "Temperature Unit" Composer property + the suffix on the two
-- live temperature properties (Temperature Setpoint, Room Temperature) so a
-- mid-session unit change reflects immediately without waiting for the next
-- room_temperature / temperature_set frame.
--
-- Wire mapping (confirmed against firmware FW: 625.04.673 via direct probe):
--   "1" -> Fahrenheit
--   "0" -> Celsius
--   anything else -> Fahrenheit (defensive default, preserves driver history)
--
-- Idempotent: no-op if the unit hasn't changed, so the initial-dump duplicates
-- don't spam Composer or re-fire suffix flips.
function CaptureTemperatureUnit(value)
    local raw = SanitizeDeviceString(value, 16)
    local newUnit
    if raw == "0" then
        newUnit = "C"
    elseif raw == "1" then
        newUnit = "F"
    else
        newUnit = "F"
    end
    if gTemperatureUnit == newUnit then return end
    gTemperatureUnit = newUnit
    local display = TemperatureUnitDisplay()
    local suffix = TemperatureSuffix()
    pcall(C4.UpdateProperty, C4, "Temperature Unit", display)
    -- Re-stamp the live temperature properties so the suffix flips
    -- immediately, not on the next device frame. DecodeTemperature is
    -- unchanged — wire format stays Fx10 integer tenths — only the
    -- trailing glyph operators see changes.
    if gState and gState.temperature_set then
        pcall(C4.UpdateProperty, C4, "Temperature Setpoint",
            DecodeTemperature(gState.temperature_set) .. suffix)
    end
    if gState and gState.room_temperature then
        pcall(C4.UpdateProperty, C4, "Room Temperature",
            DecodeTemperature(gState.room_temperature) .. suffix)
    end
    dbg_info("Temperature unit = " .. display
        .. " (wire value: " .. raw .. ", suffix: " .. suffix .. ")")
end

-- Composes the 5 fw_* sub-fields into a single human-readable string for the
-- "Firmware Versions" Composer property. Empty sub-fields are omitted so the
-- display starts populated as the device pushes each one. Presentation order
-- is fixed (revision first, then BLE/IFC/RC) regardless of which order the
-- device emits them in.
function FormatFirmwareVersions()
    local parts = {}
    local labels = {
        { key = "fw_revision", label = "Main" },
        { key = "fw_ble",      label = "BLE" },
        { key = "fw_ifc_c",    label = "IFC-C" },
        { key = "fw_ifc_s",    label = "IFC-S" },
        { key = "fw_rc",       label = "RC" },
    }
    for _, entry in ipairs(labels) do
        local v = gFirmwareVersions[entry.key]
        if v and v ~= "" then
            table.insert(parts, entry.label .. "=" .. tostring(v))
        end
    end
    if #parts == 0 then return "" end
    return table.concat(parts, ", ")
end

-- Captures a single firmware sub-field into gFirmwareVersions and re-emits
-- the composed property. No-op if the value is unchanged (avoids redundant
-- C4:UpdateProperty calls during the device's initial dump where the same
-- value may appear multiple times across frames). Sanitizes device-supplied
-- strings before logging or writing to a Composer property — see
-- SanitizeDeviceString and GitHub issue #58.
function CaptureFirmwareVersion(key, value)
    local strValue = SanitizeDeviceString(value, 128)
    if gFirmwareVersions[key] == strValue then return end
    gFirmwareVersions[key] = strValue
    local formatted = FormatFirmwareVersions()
    pcall(C4.UpdateProperty, C4, "Firmware Versions", formatted)
    dbg_info("Firmware " .. tostring(key) .. " = " .. strValue
        .. " (composed: " .. formatted .. ")")
end

function ProcessStatusUpdate(status, value)
    if not status or not value then return end

    -- Spam suppression: the device sends ~85 status pairs per reconnect, of
    -- which we route ~18 keys and intentionally ignore ~67. Without these
    -- guards every reconnect produces ~85 debug log lines; the noise buries
    -- the actually-useful messages.
    if KNOWN_IGNORED_STATUS_KEYS[status] then
        -- Carve-out: the 5 fw_* sub-fields are KNOWN_IGNORED for the regular
        -- dispatch path but DO get captured into gFirmwareVersions and
        -- composed into the "Firmware Versions" Composer property. This keeps
        -- the firmware-identity surface visible to operators (B1) without
        -- routing the values through ApplyDeviceStatus / UpdatePropertiesForStatus
        -- which only know about gState fields.
        if gFirmwareVersions[status] ~= nil then
            CaptureFirmwareVersion(status, value)
        elseif status == "temperature_unit" then
            -- A3 carve-out (same shape as the fw_* one): the device tells us
            -- whether it's displaying Fahrenheit or Celsius. We don't route
            -- temperature_unit through gState because it doesn't fit the
            -- "wire-value-string" model — it's a presentation-only signal.
            CaptureTemperatureUnit(value)
        end
        return
    end
    if not HANDLED_STATUS_KEYS[status] then
        -- Firmware sent a key the driver doesn't know about. Surface at WARN
        -- so new firmware revisions are noticed and the allowlist can be
        -- updated explicitly (rather than this becoming silent drift).
        -- Sanitize the key + value so a hostile/buggy device can't inject
        -- control bytes (newlines, forged level prefixes) into the log — see
        -- SanitizeDeviceString and GitHub issue #58.
        dbg_warn("Unknown status key from firmware (not handled, not allowlisted): "
            .. SanitizeDeviceString(status, 64) .. "=" .. SanitizeDeviceString(value, 128))
        return
    end

    dbg_debug("ProcessStatusUpdate: " .. tostring(status) .. " = " .. tostring(value))
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

    if change.status == "main_mode" or change.status == "timer_status" or change.timerExpired then
        EnforceTimerRequiredForOnState("status:" .. tostring(change.status), false)
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
    dbg_debug("Fan mode updated: level " .. levelNum .. " = " .. fanMode)
    C4:SendToProxy(THERMOSTAT_PROXY_ID, "FAN_MODE_CHANGED", { MODE = fanMode })
end

function UpdateFlameLevel()
    local flameLevel = tonumber(gState.flame_control) or 0
    local percent = math.floor(flameLevel / 6 * 100)
    local isOn = (flameLevel > 0) and IsFireplaceOnMode(gState.main_mode)
    dbg_debug("Flame level updated: " .. flameLevel .. " = " .. percent .. "%, on=" .. tostring(isOn))
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
    dbg_debug("Hold mode display updated to: " .. holdMode .. " (flame level " .. flameLevel .. ")")
end

-- =============================================================================
-- PROPERTY HANDLER
-- =============================================================================

function OnPropertyChanged(strProperty)
    dbg_info("OnPropertyChanged: " .. tostring(strProperty))
    if strProperty == "IP Address" then
        dbg_info("IP Address changed, disconnecting and reconnecting...")
        Disconnect()
        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            -- Small delay to ensure clean disconnect before reconnect
            C4:SetTimer(500, function() Connect() end, false)
        else
            C4:UpdateProperty("Connection Status", "Not Configured")
        end
    elseif strProperty == "Port" then
        dbg_info("Port changed, disconnecting and reconnecting...")
        Disconnect()
        C4:SetTimer(500, function() Connect() end, false)
    elseif strProperty == "Command Format (non-Turn-Off)" then
        dbg_info("Command Format (non-Turn-Off) set to: " .. tostring(Properties["Command Format (non-Turn-Off)"]))
    elseif strProperty == "Debug Mode" or strProperty == "Debug Level" then
        ApplyDebugLogSettings()
        dbg_info("Debug settings: mode=" .. tostring(Properties["Debug Mode"]) .. " level=" .. tostring(Properties["Debug Level"]))
    elseif strProperty == "Status Refresh Interval (minutes)" then
        if gConnected and gHandshakeComplete then
            StartStatusRefreshTimer()  -- Restart with new interval (or stop if 0)
        end
    elseif strProperty == "Update Check Interval (hours)" then
        StartUpdateCheckTimer()  -- Restart with new interval (or stop if 0)
    end
end

-- =============================================================================
-- NETWORK CALLBACKS
-- =============================================================================
--
-- The framework still calls OnConnectionStatusChanged / ReceivedFromNetwork
-- as top-level entry points. Under C1 Phase 2 the vendored websocket.lua
-- registers OCS[netBinding] / RFN[netBinding] for its dynamically-allocated
-- binding inside its setupC4Connection(). Our top-level shadowing
-- versions below check whether the call is for the vendored WebSocket's
-- binding and, if so, delegate to the OCS/RFN table entry — otherwise the
-- vendored handshake parser and ws-frame parser never get to run.

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if gWebSocket and gWebSocket.netBinding == idBinding then
        local cb = OCS and OCS[idBinding]
        if type(cb) == "function" then
            return cb(idBinding, nPort, strStatus)
        end
    end
    -- No other consumers register OCS callbacks today; fall through silently.
end

function ReceivedFromNetwork(idBinding, nPort, strData)
    if gWebSocket and gWebSocket.netBinding == idBinding then
        local cb = RFN and RFN[idBinding]
        if type(cb) == "function" then
            return cb(idBinding, nPort, strData)
        end
    end
    -- No other consumers register RFN callbacks today; fall through silently.
end

-- =============================================================================
-- WEBSOCKET CALLBACKS
-- =============================================================================
--
-- The vendored WebSocket fires :Established after its own RFC 6455 handshake
-- validation succeeds (status line + Upgrade + Connection + Sec-WebSocket-
-- Accept all check out per vendor/drivers-common-public/module/websocket.lua
-- parseHTTPPacket). At that point we own the app-protocol layer: send
-- PROFLAMECONNECTION, refresh proxies, start the status-refresh timer.
function OnWebSocketEstablished(ws)
    StopConnectTimeoutTimer()
    gConnected = true
    gConnecting = false
    gHandshakeComplete = true
    C4:UpdateProperty("Connection Status", "Connected")
    HandleConnectionEvent(true)
    StartStatusRefreshTimer()
    RequestAllStatus()
    UpdateAllProxies()
    SetupExtras()
end

-- :ProcessMessage receives ONE already-decoded text-frame payload at a time
-- (vendor module strips RFC 6455 framing/masking + reassembles fragments).
-- Drive that straight into the existing app-protocol decoder.
function OnWebSocketMessage(ws, data)
    HandleProflameMessage(data)
end

-- :Offline fires on either our local close (gWebSocket:Close) or a network-
-- layer drop. Tear down the WebSocket handle and the vendor's URL/binding
-- caches synchronously (per Codex review of #68 BLOCKER #1: without this,
-- gWebSocket stays non-nil and the next OnReconnectTimer's Connect()
-- short-circuits — the driver gets stuck Disconnected until manual action).
-- Don't send a close frame on the way out: TCP is already gone (vendor
-- module cleared ws.connected before firing this callback), so writing to
-- the dead socket would just print noise.
function OnWebSocketOffline(ws)
    StopConnectTimeoutTimer()
    TeardownWebSocket(false)
    gConnected = false
    gConnecting = false
    gHandshakeComplete = false
    StopStatusRefreshTimer()
    HandleConnectionEvent(false)
    C4:UpdateProperty("Connection Status", "Disconnected")
    ScheduleReconnect()
end

-- :ClosedByRemote fires when the device sends a CLOSE control frame. The
-- vendored module follows up with its own Close() (which trips Offline a
-- few seconds later when NetDisconnect lands), but to keep the reconnect
-- timer prompt we do the same teardown as Offline immediately.
function OnWebSocketClosedByRemote(ws)
    dbg_info("WebSocket close frame received from device")
    OnWebSocketOffline(ws)
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

function CancelTurnOffConfirmTimer()
    if gTurnOffConfirmTimer then
        gTurnOffConfirmTimer:Cancel()
        gTurnOffConfirmTimer = nil
    end
end

function CancelTurnOffRetryTimer()
    if gTurnOffRetryTimer then
        gTurnOffRetryTimer:Cancel()
        gTurnOffRetryTimer = nil
    end
end

function CancelTimerSafetyCheck()
    if gTimerSafetyCheckTimer then
        gTimerSafetyCheckTimer:Cancel()
        gTimerSafetyCheckTimer = nil
    end
end

function ClearTurnOffInProgress(reason)
    if gTurnOffInProgress then
        dbg_debug("Turn off guard cleared: " .. tostring(reason))
    end
    gTimerSafetyOffPending = false
    gTurnOffInProgress = false
    gTurnOffRetryCount = 0
    CancelTurnOffRetryTimer()
end

function ScheduleTimerSafetyCheck(reason)
    if gTimerSafetyCheckTimer then return end
    dbg_debug("Timer safety check deferred: " .. tostring(reason))
    gTimerSafetyCheckTimer = C4:SetTimer(1500, function(timer)
        gTimerSafetyCheckTimer = nil
        EnforceTimerRequiredForOnState("timer_status unknown after status sync", true)
    end, false)
end

function EnforceTimerRequiredForOnState(reason, allowUnknownTimerStatus)
    local mode = gState.main_mode
    if not IsFireplaceOnMode(mode) then
        gTimerSafetyOffPending = false
        CancelTimerSafetyCheck()
        return
    end

    local timerStatusKnown = gStatusSeen["timer_status"] == true
    local timerRunning = timerStatusKnown and gState.timer_status == "1" and not gTimerExpired
    if timerRunning then
        gTimerSafetyOffPending = false
        CancelTimerSafetyCheck()
        return
    end

    if gSuppressTimerUpdates then
        dbg_debug("Timer safety check skipped while timer updates are suppressed: " .. tostring(reason))
        return
    end
    if gTurnOffInProgress then
        return
    end
    if not timerStatusKnown and not allowUnknownTimerStatus then
        ScheduleTimerSafetyCheck(reason)
        return
    end
    if gTimerSafetyOffPending then
        dbg_debug("Timer safety force-off already pending: mode=" .. tostring(mode) .. ", timer_status=" .. tostring(gState.timer_status))
        return
    end

    gTimerSafetyOffPending = true
    dbg_warn("Timer safety policy forcing fireplace off: mode=" .. tostring(mode) .. ", timer_status=" .. tostring(gState.timer_status) .. ", reason=" .. tostring(reason))
    ClearTimerStateAndSend(true)
end

function SendTurnOffControls(reason)
    dbg_debug("Sending legacy turn off controls: " .. tostring(reason))
    local sent = SendDeviceControlWithFormat("timer_status", "0", COMMAND_FORMAT_TURN_OFF_LEGACY_ONLY, "turn off")
    sent = SendDeviceControlWithFormat("main_mode", MODE_OFF, COMMAND_FORMAT_TURN_OFF_LEGACY_ONLY, "turn off") or sent
    return sent
end

function ScheduleTurnOffRetry(reason)
    CancelTurnOffRetryTimer()
    if not gTurnOffInProgress then return end
    if gTurnOffRetryCount >= 4 then
        dbg_err("Turn off retry limit reached: " .. tostring(reason))
        ClearTurnOffInProgress("retry limit reached")
        return
    end
    gTurnOffRetryCount = gTurnOffRetryCount + 1
    local delay = 750 * gTurnOffRetryCount
    dbg_debug("Scheduling turn off retry " .. tostring(gTurnOffRetryCount) .. " in " .. tostring(delay) .. "ms: " .. tostring(reason))
    gTurnOffRetryTimer = C4:SetTimer(delay, function(timer)
        gTurnOffRetryTimer = nil
        if RequireDeviceCommandReady("Turn Off retry") and gTurnOffInProgress then
            SendTurnOffControls("retry " .. tostring(gTurnOffRetryCount))
            ScheduleTurnOffRetry("awaiting off confirmation")
        end
    end, false)
end

function SetTimerSuppression(enabled, reason)
    CancelTimerSuppressionClear()
    gSuppressTimerUpdates = enabled
    dbg_debug("Timer suppression " .. (enabled and "enabled" or "disabled") .. ": " .. tostring(reason))
    if not enabled then
        EnforceTimerRequiredForOnState("timer suppression cleared: " .. tostring(reason), false)
    end
end

function IsDeviceCommandReady()
    return gConnected and gHandshakeComplete
end

function RequireDeviceCommandReady(action)
    if IsDeviceCommandReady() then return true end
    dbg_warn("Command refused while device is disconnected or handshaking: " .. tostring(action))
    return false
end

function RequireConfirmedDeviceStatus(status, action)
    if not RequireDeviceCommandReady(action) then return false end
    if gStatusSeen[status] then return true end
    dbg_warn("Command refused until device reports " .. tostring(status) .. ": " .. tostring(action))
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
    CancelTurnOffConfirmTimer()
    SetTimerSuppression(true, "clearing timer")
    local sent
    if turnOff then
        gTurnOffInProgress = true
        gTurnOffRetryCount = 0
        sent = SendTurnOffControls("initial")
        ScheduleTurnOffRetry("initial turn off")
    else
        sent = SendDeviceControl("timer_status", "0")
        sent = SendDeviceControl("timer_set", "0") or sent
    end
    if not sent then
        SetTimerSuppression(false, "clear timer send failed")
        return false
    end
    gState.timer_set = "0"
    gState.timer_count = "0"
    gState.timer_status = "0"
    if turnOff then
        gState.flame_control = "0"
        UpdatePropertiesForStatus({ status = "flame_control", value = "0" })
        gTurnOffConfirmTimer = C4:SetTimer(750, function(timer)
            gTurnOffConfirmTimer = nil
            if RequireDeviceCommandReady("Turn Off confirm") then
                SendTurnOffControls("confirm")
            end
        end, false)
    end
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
    gTimerSafetyOffPending = false
    CancelTimerSafetyCheck()
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
        if mode ~= MODE_OFF then
            ClearTurnOffInProgress("explicit mode command")
        end
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
    ClearTurnOffInProgress("turn on")
    CancelPendingTimerCommandTimers()
    local defaultFlame = GetDefaultFlameLevel()
    local defaultTimer = GetDefaultTimerMinutes()
    gTimerSafetyOffPending = false
    CancelTimerSafetyCheck()
    if defaultTimer and defaultTimer > 0 then
        SetTimerSuppression(true, "turn on while arming default timer")
        gTimerExpired = false
    end
    if not SendDeviceControl("main_mode", GetDefaultOnMode()) then
        if defaultTimer and defaultTimer > 0 then
            SetTimerSuppression(false, "turn on mode send failed")
        end
        return false
    end
    ScheduleModeReadyWork(function()
        if not RequireDeviceCommandReady("Turn On default flame") then
            if defaultTimer and defaultTimer > 0 then
                SetTimerSuppression(false, "turn on mode-ready work disconnected")
            end
            return
        end
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
    if gTurnOffInProgress then
        dbg_warn("Set Flame Level ignored while turn off is in progress")
        return false
    end
    if not RequireDeviceCommandReady("Set Flame Level") then return false end
    level = ClampNumber(level, 0, 6, nil)
    if level == nil then
        dbg_err("Set Flame Level missing or invalid Level parameter")
        return false
    end

    if gState.main_mode ~= MODE_MANUAL then
        dbg_info("Set Flame Level switching fireplace to Manual mode before setting flame; previous mode: " .. tostring(gState.main_mode))
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

    dbg_debug("CommandSetTimerMinutes: " .. tostring(minutes) .. " minutes, current mode: " .. tostring(gState.main_mode))
    CancelPendingTimerCommandTimers()

    if minutes > 0 then
        SetTimerSuppression(true, "set timer command")
        gTimerExpired = false

        if IsFireplaceOffMode(gState.main_mode) then
            dbg_info("Fireplace is off, turning on with timer")
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
        dbg_info("Timer set to 0, turning off fireplace")
        return ClearTimerStateAndSend(true)
    end
    return true
end

function CommandCancelTimer()
    return ClearTimerStateAndSend(false)
end

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}
    dbg_debug("ExecuteCommand: " .. tostring(strCommand))

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
    elseif strCommand == "Install Latest Release" then
        InstallLatestReleaseNow()
        return true
    elseif strCommand == "Check for Update" then
        CheckForUpdateNow()
        return true
    elseif strCommand == "Force Reinstall Latest Release" then
        ForceReinstallLatestRelease()
        return true
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
        dbg_debug("GET_EXTRAS_SETUP received - returning extras setup XML directly")
        local xml = GetExtrasXML()
        dbg_all("Extras XML: " .. xml)
        -- Return the XML directly as the response
        return xml
    end
    
    -- Handle Request for Extras State
    if strCommand == "GET_EXTRAS_STATE" then
        dbg_debug("GET_EXTRAS_STATE received - returning extras setup XML with current values")
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
        dbg_debug("SET_MODE_FAN: " .. tostring(mode) .. " -> level " .. level)
        CommandSetFan(level)
        
    elseif strCommand == "SET_EXTRAS" then
        dbg_debug("Received SET_EXTRAS command")
        -- Handle flame preset (Low/Medium/High quick select)
        if tParams["pf_flame_preset"] then
            local val = tonumber(tParams["pf_flame_preset"])
            if val then
                dbg_debug("Flame preset selected: " .. val)
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
        dbg_warn("SET_PRESET is deprecated because thermostat Presets are disabled; routing legacy preset command: " .. tostring(preset))
        if preset == "Manual" then
            CommandSetMode(MODE_MANUAL)
        elseif preset == "Smart" then
            CommandSetMode(MODE_SMART)
        elseif preset == "Eco" then
            CommandSetMode(MODE_ECO)
        else
            dbg_err("SET_PRESET ignored; unknown preset: " .. tostring(preset))
        end
        
    elseif strCommand == "SET_MODE_HOLD" then
        -- Hold modes repurposed for quick flame control:
        -- "Low Flame" = level 1, "Medium Flame" = level 3, "High Flame" = level 6
        local holdMode = tParams["MODE"] or ""
        dbg_debug("SET_MODE_HOLD received: " .. holdMode)
        if gTurnOffInProgress then
            dbg_warn("SET_MODE_HOLD ignored while turn off is in progress: " .. tostring(holdMode))
            return
        end
        if not IsFireplaceOnMode(gState.main_mode) then
            dbg_warn("SET_MODE_HOLD ignored while fireplace mode is off/standby: " .. tostring(gState.main_mode))
            return
        end
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
        dbg_debug("SELECT_MODE: " .. tostring(val))
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
        dbg_debug("SELECT_FLAME_PRESET: " .. tostring(val))
        if val then
            CommandSetFlame(val)
        end
        
    elseif strCommand == "SET_FLAME_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_debug("SET_FLAME_LEVEL: " .. tostring(val))
        if val then
            CommandSetFlame(val)
        end
        
    elseif strCommand == "SET_FAN_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_debug("SET_FAN_LEVEL: " .. tostring(val))
        if val then CommandSetFan(val) end
        
    elseif strCommand == "SET_LIGHT_LEVEL" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_debug("SET_LIGHT_LEVEL: " .. tostring(val))
        if val then CommandSetLight(val) end
        
    elseif strCommand == "SET_TIMER_MINUTES" then
        local val = tonumber(tParams["VALUE"] or tParams["value"])
        dbg_debug("SET_TIMER_MINUTES: " .. tostring(val) .. " minutes, current mode: " .. tostring(gState.main_mode))
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
    gExtrasThrottle = false
    SetTimerSuppression(false, "driver state reset")
    gTimerExpired = false
    gLastMainMode = nil
    gLastConnectionOnline = false
    gStatusSeen = {}
    gTurnOffInProgress = false
    gTimerSafetyOffPending = false

    -- Cancel any pending timers. The WS-level ping/pong timer is owned by
    -- the vendored WebSocket module and gets cleaned up by gWebSocket:Close()
    -- (called from Disconnect), so it's not in this list.
    StopReconnectTimer()
    StopConnectTimeoutTimer()
    StopStatusRefreshTimer()
    CancelPendingTimerCommandTimers()
    CancelTurnOffConfirmTimer()
    CancelTurnOffRetryTimer()
    CancelTimerSafetyCheck()

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
    gFirmwareVersions = {
        fw_revision = "",
        fw_ble = "",
        fw_ifc_c = "",
        fw_ifc_s = "",
        fw_rc = "",
    }
    gTemperatureUnit = "F"

    dbg_info("Driver state reset")
end

function OnDriverInit()
    local success, err = pcall(function()
        dbg_info("OnDriverInit - resetting state")
        math.randomseed(os.time())
        ResetDriverState()
        InitializePropertiesFromState()
    end)
    if not success then dbg_err("OnDriverInit Error: " .. tostring(err)) end
end

-- Persistence key for the last DRIVER_VERSION the driver was loaded with.
-- Used to emit an upgrade message when the bundled version differs from
-- the previously-seen one (across Director restarts, controller reboots,
-- and driver re-installs that don't wipe PersistData).
PERSIST_KEY_LAST_VERSION = "proflame.last_driver_version"

function LogDriverVersionTransition()
    local previous = persist:get(PERSIST_KEY_LAST_VERSION, nil)
    if previous == DRIVER_VERSION then return end
    if type(previous) == "string" then
        dbg_info("Driver version changed: " .. previous .. " -> " .. DRIVER_VERSION)
    elseif previous == nil then
        dbg_info("Driver version first run on this controller: " .. DRIVER_VERSION)
    end
    persist:set(PERSIST_KEY_LAST_VERSION, DRIVER_VERSION)
end

-- Repo + filename used by the full github-updater. Single-driver setup, so
-- we hard-code the filename of our .c4z install.
GITHUB_UPDATER_REPO = "psaab/proflame_c4"
GITHUB_UPDATER_FILENAMES = { "proflame_wifi_connect.c4z" }

-- Tracks an in-flight Install Latest Release attempt so the Composer property
-- can show progress.
gUpdateInProgress = false

function UpdateUpdateStatusProperty(text)
    pcall(C4.UpdateProperty, C4, "Update Status", tostring(text or ""))
end

-- Trigger the full template github_updater. Downloads any .c4z whose
-- DRIVER_VERSION is older than the latest release tag, writes it to
-- C4Z_ROOT, then drives Composer's local SOAP endpoint to install it.
-- Status updates surface in the "Update Status" property.
--
-- `force` (the "Force Reinstall Latest Release" command) passes forceUpdate=true
-- to updateAll so the latest release is re-downloaded and re-installed even when
-- its tag equals the running DRIVER_VERSION — for recovery/repair of a corrupt
-- or partially-applied install. Note this also re-installs an OLDER release if
-- the latest GitHub release happens to be behind the running build, so it can
-- downgrade; that's the intended "give me exactly the latest published release"
-- semantic.
function InstallLatestReleaseNow(force)
    if gUpdateInProgress then
        dbg_warn("Install Latest Release ignored: an install is already running")
        UpdateUpdateStatusProperty("Install already running")
        return
    end
    gUpdateInProgress = true
    local what = force and "Force-reinstalling the latest release..." or "Checking GitHub for the latest release..."
    UpdateUpdateStatusProperty(what)
    dbg_info("InstallLatestReleaseNow: starting (force=" .. tostring(force and true or false) .. ")")

    local d = github_updater:updateAll(GITHUB_UPDATER_REPO, GITHUB_UPDATER_FILENAMES, false, force and true or false)
    d:next(function(updated)
        gUpdateInProgress = false
        if not updated or #updated == 0 then
            -- updateAll resolves with an empty list in three cases:
            --   (a) DRIVER_VERSION already equals the latest release tag
            --   (b) the latest release has no asset whose name matches
            --       GITHUB_UPDATER_FILENAMES
            --   (c) C4:GetDevicesByC4iName returned no installed driver, so
            --       the filter dropped every entry before download
            -- We can't disambiguate from the resolve value alone, but the
            -- common case is (a). Surface a message that doesn't claim a
            -- specific cause when none is provable. (force=true never resolves
            -- empty for case (a) since forceUpdate skips the version compare.)
            UpdateUpdateStatusProperty(
                "No install applied (current: " .. DRIVER_VERSION
                    .. "). If a release exists with a newer tag, verify its asset is named "
                    .. table.concat(GITHUB_UPDATER_FILENAMES, ", ")
            )
            dbg_info("InstallLatestReleaseNow: no update applied (current=" .. DRIVER_VERSION .. ")")
        else
            UpdateUpdateStatusProperty("Installed: " .. table.concat(updated, ", ") .. " (controller may reload driver)")
            dbg_info("InstallLatestReleaseNow: triggered Composer install of " .. table.concat(updated, ", "))
        end
    end, function(err)
        gUpdateInProgress = false
        local msg = type(err) == "string" and err or (err and err.error) or "unknown error"
        UpdateUpdateStatusProperty("Failed: " .. tostring(msg))
        dbg_err("InstallLatestReleaseNow: failed - " .. tostring(msg))
    end)
end

-- "Force Reinstall Latest Release" command — re-install the latest published
-- release even if its tag matches the running version. See InstallLatestReleaseNow.
function ForceReinstallLatestRelease()
    InstallLatestReleaseNow(true)
end

-- Report-only update check ("Check for Update" command + the periodic timer).
-- Queries the latest GitHub release and reports whether it's newer than the
-- running DRIVER_VERSION in the "Update Status" property, WITHOUT downloading
-- or installing anything. This is the safe "is there an update?" probe; the
-- user still runs "Install Latest Release" to actually apply it.
function CheckForUpdateNow()
    -- Don't stomp the install path's status messages or interleave with it
    -- (Codex review of PR #73). A report-only check while an install is running
    -- would overwrite "Force-reinstalling..."/"Installed:" with a stale
    -- "Up to date"/"Update available" at a confusing moment. Skip silently.
    if gUpdateInProgress then
        dbg_info("CheckForUpdateNow skipped: an install is in progress")
        return
    end
    UpdateUpdateStatusProperty("Checking GitHub for the latest release...")
    dbg_info("CheckForUpdateNow: starting")
    local d = github_updater:getLatestRelease(GITHUB_UPDATER_REPO, false)
    d:next(function(latest)
        local latestVer = latest and latest.version
        local latestTag = (latest and latest.tag_name) or (latestVer and tostring(latestVer)) or "?"
        local currentVer = version_lib(DRIVER_VERSION)
        if latestVer and currentVer and latestVer > currentVer then
            UpdateUpdateStatusProperty(
                "Update available: " .. tostring(latestTag)
                    .. " (current " .. DRIVER_VERSION .. ") — run Install Latest Release"
            )
            dbg_info("CheckForUpdateNow: update available " .. tostring(latestTag) .. " > " .. DRIVER_VERSION)
        else
            UpdateUpdateStatusProperty("Up to date (" .. DRIVER_VERSION .. ", latest release " .. tostring(latestTag) .. ")")
            dbg_info("CheckForUpdateNow: up to date (current=" .. DRIVER_VERSION .. ", latest=" .. tostring(latestTag) .. ")")
        end
    end, function(err)
        local msg = type(err) == "string" and err or (err and err.error) or "unknown error"
        UpdateUpdateStatusProperty("Update check failed: " .. tostring(msg))
        dbg_err("CheckForUpdateNow: failed - " .. tostring(msg))
    end)
end

-- Periodic update-check timer. Repeatedly runs the report-only CheckForUpdateNow
-- so "Update Status" reflects whether a newer release exists without the user
-- having to trigger the command. Install stays manual. Default 24h; 0 disables.
-- Independent of the device connection (it talks to GitHub, not the fireplace),
-- so it is NOT stopped by Disconnect — only by reload cleanup / OnDriverDestroyed
-- / an interval change.
function StartUpdateCheckTimer()
    StopUpdateCheckTimer()
    local hours = tonumber(Properties["Update Check Interval (hours)"]) or 0
    if hours <= 0 then
        dbg_info("Periodic update check disabled (Update Check Interval = 0)")
        return
    end
    local intervalMs = hours * 60 * 60 * 1000
    gUpdateCheckTimerId = C4:SetTimer(intervalMs, function(timer) CheckForUpdateNow() end, true)
    dbg_info("Periodic update check scheduled every " .. hours .. "h")
end

-- Cancels both the repeating check timer and the post-load one-shot (Codex
-- review of PR #73: the anonymous 10s startup check otherwise fires after a
-- teardown/reload inside its window and writes Update Status post-destroy).
function StopUpdateCheckTimer()
    if gUpdateCheckTimerId then
        gUpdateCheckTimerId:Cancel()
        gUpdateCheckTimerId = nil
    end
    if gInitialUpdateCheckTimerId then
        gInitialUpdateCheckTimerId:Cancel()
        gInitialUpdateCheckTimerId = nil
    end
end

-- Top-level async response dispatcher. C4 invokes this for every urlGet/Post
-- ticket the driver has in flight; route to http_client which maintains its
-- own ticket -> callback table. Future C4:urlGet consumers add their own
-- `elseif` branch here.
function ReceivedAsync(ticket, body, responseCode, headers, err)
    if http_client.handleAsyncResponse(ticket, body, responseCode, headers, err) then
        return
    end
    dbg_all("ReceivedAsync ticket " .. tostring(ticket) .. " had no registered handler")
end

function OnDriverLateInit()
    -- Re-apply debug log mode/level from Composer properties; the top-level
    -- log:setLogName/Mode/Level above set the defaults used during driver load.
    ApplyDebugLogSettings()

    -- Surface upgrades/downgrades + first-install in the log.
    pcall(LogDriverVersionTransition)

    -- Install is always manual (the "Install Latest Release" / "Force Reinstall
    -- Latest Release" commands). Update *detection* runs on a report-only timer
    -- (Update Check Interval, default 24h) plus a one-shot check shortly after
    -- load so "Update Status" reflects availability without user action. The
    -- "Check for Update" command triggers the same report-only probe on demand.

    dbg_info("OnDriverLateInit - Build: " .. BUILD_TIMESTAMP)
    local success, err = pcall(function()
        C4:UpdateProperty("Driver Version", DRIVER_VERSION .. " (" .. DRIVER_DATE .. ") [" .. BUILD_TIMESTAMP .. "]")

        -- Ensure clean state before connecting
        Disconnect()

        -- DELAYED EXTRAS SETUP TO ENSURE PROXY IS READY
        C4:SetTimer(2000, function() SetupExtras() end, false)

        -- Start the periodic update-check timer (report-only) and run one check
        -- ~10s after load so the user sees update availability promptly. Both
        -- no-op cleanly if Update Check Interval is 0.
        StartUpdateCheckTimer()
        if (tonumber(Properties["Update Check Interval (hours)"]) or 0) > 0 then
            -- Tracked (not anonymous) so teardown/reload within the 10s window
            -- can cancel it — see StopUpdateCheckTimer.
            gInitialUpdateCheckTimerId = C4:SetTimer(10000, function(timer)
                gInitialUpdateCheckTimerId = nil
                CheckForUpdateNow()
            end, false)
        end

        local ipAddress = Properties["IP Address"] or ""
        if ipAddress ~= "" then
            -- Delay connection slightly to ensure network is ready
            C4:SetTimer(500, function() Connect() end, false)
        else
            C4:UpdateProperty("Connection Status", "Not Configured")
        end
    end)
    if not success then dbg_err("OnDriverLateInit Error: " .. tostring(err)) end
end

function InitializePropertiesFromState()
    -- A3: read the suffix once from the (possibly-just-reset) gTemperatureUnit
    -- so a fresh init shows the default ("F") rather than carrying the prior
    -- session's unit forward. The "Temperature Unit" and "Firmware Versions"
    -- resets here address Codex finding #57 (stale read-only properties after
    -- ResetDriverState clears the accumulators but the displayed strings stay
    -- whatever Composer last latched).
    local suffix = TemperatureSuffix()
    C4:UpdateProperty("Operating Mode", GetModeString(gState.main_mode))
    C4:UpdateProperty("Flame Level", gState.flame_control)
    C4:UpdateProperty("Fan Level", gState.fan_control)
    C4:UpdateProperty("Light Level", gState.lamp_control)
    C4:UpdateProperty("Temperature Setpoint", DecodeTemperature(gState.temperature_set) .. suffix)
    C4:UpdateProperty("Room Temperature", DecodeTemperature(gState.room_temperature) .. suffix)
    C4:UpdateProperty("Temperature Unit", TemperatureUnitDisplay())
    C4:UpdateProperty("Firmware Versions", FormatFirmwareVersions())
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
    RefreshThermostatUiSurface("InitializePropertiesFromState", false)
end

function OnDriverDestroyed()
    dbg_info("OnDriverDestroyed - cleaning up")
    StopReconnectTimer()
    StopUpdateCheckTimer()  -- device-independent; Disconnect() doesn't stop it
    CancelPendingTimerCommandTimers()
    CancelTurnOffConfirmTimer()
    CancelTurnOffRetryTimer()
    CancelTimerSafetyCheck()
    Disconnect()
end

function OnDriverUpdated()
    -- Called when driver is updated/reloaded
    dbg_info("OnDriverUpdated - driver updated to version " .. DRIVER_VERSION)

    -- Clean up old state
    StopReconnectTimer()
    CancelPendingTimerCommandTimers()
    CancelTurnOffConfirmTimer()
    CancelTurnOffRetryTimer()
    CancelTimerSafetyCheck()
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
