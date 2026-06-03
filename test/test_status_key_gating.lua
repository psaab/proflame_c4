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
-- 2b. fw_* sub-fields are the B1 carve-out: in KNOWN_IGNORED (the regular
--     ApplyDeviceStatus dispatch pipeline is skipped) but captured into
--     gFirmwareVersions and composed into the "Firmware Versions" Composer
--     property, plus an INFO log per field with the running composition.
--------------------------------------------------------------------------------
-- Stub C4:UpdateProperty so we can capture the composed value.
local _prop_updates = {}
function C4:UpdateProperty(name, value)
    _prop_updates[name] = value
end

local function fw_dispatch(field, value)
    reset_capture()
    _prop_updates["Firmware Versions"] = nil
    ProcessStatusUpdate(field, value)
end

-- Clear any state from previous test cases (handled-key dispatches earlier
-- in this file may have touched the firmware accumulator).
gFirmwareVersions = {
    fw_revision = "", fw_ble = "", fw_ifc_c = "", fw_ifc_s = "", fw_rc = "",
}

fw_dispatch("fw_revision", "FW: 625.04.673")
Test.assertEqual(
    _prop_updates["Firmware Versions"],
    "Main=FW: 625.04.673",
    "fw_revision composes as 'Main=...' in the property"
)
Test.assert(
    any_print_matches("Firmware fw_revision = FW: 625.04.673"),
    "fw_revision dispatch logs at INFO with the composed value"
)
Test.assert(
    not any_print_matches("ProcessStatusUpdate:"),
    "fw_revision does NOT route through the normal debug-dispatch log"
)

fw_dispatch("fw_ble", "1.2.3")
Test.assertEqual(
    _prop_updates["Firmware Versions"],
    "Main=FW: 625.04.673, BLE=1.2.3",
    "fw_ble appended after Main"
)

fw_dispatch("fw_ifc_c", "0.0.0")
fw_dispatch("fw_ifc_s", "ifc-s")
fw_dispatch("fw_rc", "rc-build")
Test.assertEqual(
    _prop_updates["Firmware Versions"],
    "Main=FW: 625.04.673, BLE=1.2.3, IFC-C=0.0.0, IFC-S=ifc-s, RC=rc-build",
    "all 5 fw_* fields compose in presentation order regardless of arrival order"
)

-- Duplicate value should not re-fire UpdateProperty
fw_dispatch("fw_revision", "FW: 625.04.673")
Test.assertEqual(
    _prop_updates["Firmware Versions"],
    nil,
    "duplicate fw_* value does NOT re-fire UpdateProperty"
)

--------------------------------------------------------------------------------
-- 2c. A3 carve-out: temperature_unit captures into gTemperatureUnit and writes
--     the "Temperature Unit" Composer property, and the suffix on the two
--     live temperature properties (Temperature Setpoint, Room Temperature)
--     flips immediately without waiting for the next device frame.
--------------------------------------------------------------------------------
local function reset_temp_state(initialUnit, setpointEncoded, roomEncoded)
    -- Clear the property-update capture and reset the unit so the carve-out
    -- is forced to take the "value changed" branch.
    _prop_updates = {}
    -- Force a non-matching initial value so the next CaptureTemperatureUnit
    -- call always goes through the update branch. We use a string the
    -- production code will never produce ("Z") to bypass the idempotence
    -- short-circuit even when the test re-asserts the same final unit.
    gTemperatureUnit = initialUnit or "Z"
    gState = gState or {}
    gState.temperature_set = setpointEncoded or "700"
    gState.room_temperature = roomEncoded or "685"
end

-- "1" -> Fahrenheit
reset_temp_state("Z", "750", "705")
ProcessStatusUpdate("temperature_unit", "1")
Test.assertEqual(gTemperatureUnit, "F", 'temperature_unit "1" sets gTemperatureUnit = "F"')
Test.assertEqual(
    _prop_updates["Temperature Unit"], "Fahrenheit",
    'temperature_unit "1" writes "Fahrenheit" to the Composer property'
)
Test.assertEqual(
    _prop_updates["Temperature Setpoint"], "75F",
    'F unit re-stamps Temperature Setpoint with "F" suffix immediately'
)
Test.assertEqual(
    _prop_updates["Room Temperature"], "70.5F",
    'F unit re-stamps Room Temperature with "F" suffix immediately'
)

-- "0" -> Celsius (mid-session flip; suffix must change without a setpoint frame)
reset_temp_state("Z", "750", "705")
ProcessStatusUpdate("temperature_unit", "0")
Test.assertEqual(gTemperatureUnit, "C", 'temperature_unit "0" sets gTemperatureUnit = "C"')
Test.assertEqual(
    _prop_updates["Temperature Unit"], "Celsius",
    'temperature_unit "0" writes "Celsius" to the Composer property'
)
Test.assertEqual(
    _prop_updates["Temperature Setpoint"], "75C",
    'C unit re-stamps Temperature Setpoint with "C" suffix without a fresh frame'
)
Test.assertEqual(
    _prop_updates["Room Temperature"], "70.5C",
    'C unit re-stamps Room Temperature with "C" suffix without a fresh frame'
)

-- Anything else -> defensive default to F (preserves historical behavior)
for _, malformed in ipairs({ "2", "", "F", "yes", "0\n[ERROR]:fake" }) do
    reset_temp_state("Z", "700", "700")
    ProcessStatusUpdate("temperature_unit", malformed)
    local printable = (malformed:gsub("%c", "?"))  -- parens force single return
    Test.assertEqual(
        gTemperatureUnit, "F",
        'temperature_unit "' .. printable .. '" defensively defaults to F'
    )
    Test.assertEqual(
        _prop_updates["Temperature Unit"], "Fahrenheit",
        'malformed value renders as "Fahrenheit" in the property'
    )
end

-- Idempotence: same unit re-pushed is a no-op (no property update reissued)
gTemperatureUnit = "F"
_prop_updates = {}
ProcessStatusUpdate("temperature_unit", "1")
Test.assertEqual(
    _prop_updates["Temperature Unit"], nil,
    "duplicate temperature_unit=1 does NOT re-fire UpdateProperty"
)

-- Direct dispatch of a temperature_set status under gTemperatureUnit = "C"
-- routes through the UpdatePropertiesForStatus branch (the actually-handled
-- path) and produces a "C"-suffixed value.
gTemperatureUnit = "C"
_prop_updates = {}
ProcessStatusUpdate("temperature_set", "720")
Test.assertEqual(
    _prop_updates["Temperature Setpoint"], "72C",
    'temperature_set dispatched with gTemperatureUnit="C" emits a "C"-suffixed property value'
)

-- And under gTemperatureUnit = "F" the same dispatch emits "F".
gTemperatureUnit = "F"
_prop_updates = {}
ProcessStatusUpdate("temperature_set", "720")
Test.assertEqual(
    _prop_updates["Temperature Setpoint"], "72F",
    'temperature_set dispatched with gTemperatureUnit="F" emits an "F"-suffixed property value'
)

-- Codex #57 regression check: InitializePropertiesFromState must re-stamp
-- the "Temperature Unit" and "Firmware Versions" properties from the
-- accumulators (so a state reset doesn't leave Composer showing the prior
-- session's strings).
gTemperatureUnit = "F"
gFirmwareVersions = {
    fw_revision = "", fw_ble = "", fw_ifc_c = "", fw_ifc_s = "", fw_rc = "",
}
gState.temperature_set = "700"
gState.room_temperature = "700"
_prop_updates = {}
InitializePropertiesFromState()
Test.assertEqual(
    _prop_updates["Temperature Unit"], "Fahrenheit",
    "InitializePropertiesFromState re-stamps Temperature Unit (Codex #57)"
)
Test.assertEqual(
    _prop_updates["Firmware Versions"], "",
    "InitializePropertiesFromState re-stamps Firmware Versions to '' after reset (Codex #57)"
)

-- Restore the production-default unit for the rest of the suite.
gTemperatureUnit = "F"

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

-- Codex #58 regression: SanitizeDeviceString strips control characters out of
-- the unknown-key WARN log so a hostile/buggy device can't inject newlines or
-- forged level prefixes. The raw bytes must not appear; the warn line should.
reset_capture()
ProcessStatusUpdate("evil_key", "real\n[ERROR]:forged")
Test.assert(
    any_print_matches("Unknown status key from firmware"),
    "sanitized unknown-key warn still includes the warn prefix"
)
Test.assert(
    not any_print_matches("\n[ERROR]:forged"),
    "raw newline + forged level prefix must NOT survive into the log line"
)
Test.assert(
    any_print_matches("real [ERROR]:forged") or any_print_matches("real  [ERROR]:forged"),
    "sanitized value renders control bytes as spaces"
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
