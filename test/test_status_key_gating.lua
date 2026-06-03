-- A2: ProcessStatusUpdate should classify each incoming status key into one of
-- three buckets and produce the corresponding log behavior:
--   HANDLED        -> debug log + dispatch to ApplyDeviceStatus
--   KNOWN_IGNORED  -> no log at all (allowlist suppresses ~67 keys/reconnect)
--   neither        -> WARN log (firmware emitted a key we don't know about)

require("c4_shim")

-- Capture every Print log line so we can assert on them. The default shim's
-- C4:ErrorLog/DebugLog capture is per-process but the print() path bypasses
-- both (vendor/logging.lua writes through Lua's print when output mode
-- includes "Print"). Wrap the real print so the assertions can inspect what
-- went out.
local _captured_print = {}
local _real_print = print
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring(select(i, ...))
    end
    table.insert(_captured_print, table.concat(parts, "\t"))
end

dofile("driver.lua")

-- Allow log output through the print path (default after driver load is
-- "Print and Log" so this is already on; explicit just in case).
log:setLogMode("Print and Log")
log:setLogLevel(log.LogLevel.TRACE)

local function reset_capture()
    _captured_print = {}
end

local function any_print_matches(pattern)
    for _, line in ipairs(_captured_print) do
        if line:find(pattern, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- 1. HANDLED key produces a debug log line
--------------------------------------------------------------------------------
reset_capture()
ProcessStatusUpdate("main_mode", "5")
Test.assert(
    any_print_matches("ProcessStatusUpdate: main_mode = 5"),
    "handled key (main_mode) produces a debug log line"
)

reset_capture()
ProcessStatusUpdate("flame_control", "3")
Test.assert(
    any_print_matches("ProcessStatusUpdate: flame_control = 3"),
    "handled key (flame_control) produces a debug log line"
)

--------------------------------------------------------------------------------
-- 2a. KNOWN_IGNORED keys produce NO log (except the fw_revision INFO carve-out)
--------------------------------------------------------------------------------
for _, ignored in ipairs({ "en_fan", "rgb_0_intensity",
                            "p_day_1", "free_heap", "child_lock",
                            "temperature_unit", "scenario_name" }) do
    reset_capture()
    ProcessStatusUpdate(ignored, "whatever")
    Test.assert(
        not any_print_matches("ProcessStatusUpdate"),
        "known-ignored key '" .. ignored .. "' must NOT log ProcessStatusUpdate"
    )
    Test.assert(
        not any_print_matches("Unknown status key"),
        "known-ignored key '" .. ignored .. "' must NOT log as Unknown"
    )
    Test.assert(
        not any_print_matches("Ignoring unsupported"),
        "known-ignored key '" .. ignored .. "' must NOT log legacy 'Ignoring' message"
    )
end

--------------------------------------------------------------------------------
-- 2b. fw_revision is the carve-out: it's in KNOWN_IGNORED (so the dispatch
--     pipeline is skipped) but produces an INFO log so the firmware version
--     stays operator-visible until B1 promotes it to a Composer property.
--------------------------------------------------------------------------------
reset_capture()
ProcessStatusUpdate("fw_revision", "FW: 625.04.673")
Test.assert(
    any_print_matches("Firmware revision reported by device: FW: 625.04.673"),
    "fw_revision produces an INFO log even though it's in KNOWN_IGNORED"
)
Test.assert(
    not any_print_matches("ProcessStatusUpdate:"),
    "fw_revision INFO does NOT also produce the debug-dispatch log"
)

--------------------------------------------------------------------------------
-- 3. Unknown key (not in either set) produces a WARN log so firmware additions
--    surface visibly. Use a key we know isn't in either set.
--------------------------------------------------------------------------------
reset_capture()
ProcessStatusUpdate("brand_new_firmware_field", "42")
Test.assert(
    any_print_matches("Unknown status key from firmware"),
    "unknown key produces a WARN log mentioning 'Unknown status key from firmware'"
)
Test.assert(
    any_print_matches("brand_new_firmware_field"),
    "unknown key log includes the key name"
)
Test.assert(
    any_print_matches("=42"),
    "unknown key log includes the value"
)

--------------------------------------------------------------------------------
-- 4. Direct-walker mapping still works for the alternate spec format
--    (rssi -> wifi_signal_str, temperature_read -> room_temperature).
--    Build a status payload with the alternate names and confirm
--    ParseStatusMessage dispatches through ProcessStatusUpdate WITHOUT spamming.
--------------------------------------------------------------------------------
reset_capture()
ParseStatusMessage([[{"rssi":"45","temperature_read":"700","fw_revision":"FW: 625.04.673"}]])
Test.assert(
    any_print_matches("ProcessStatusUpdate: wifi_signal_str = 45"),
    "direct rssi mapped through to wifi_signal_str dispatch"
)
Test.assert(
    any_print_matches("ProcessStatusUpdate: temperature_read = 700")
        or any_print_matches("ProcessStatusUpdate: room_temperature = 700"),
    "direct temperature_read dispatched (mapped or as-is)"
)
Test.assert(
    not any_print_matches("ProcessStatusUpdate: fw_revision"),
    "fw_revision in direct format is silent (known-ignored)"
)
Test.assert(
    not any_print_matches("Ignoring unsupported JSON status key"),
    "legacy 'Ignoring unsupported JSON status key' log is fully removed"
)

print("test_status_key_gating OK")
_real_print("test_status_key_gating OK")
