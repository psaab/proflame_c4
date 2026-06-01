-- The two outbound command shapes that ship over the WebSocket. JSON.lua's
-- alphabetical key sort happens to match the documented order for both:
--   set_control:    command < name < value  (Spec §2.4)
--   legacy indexed: control0 < value0       (Spec §2.4)
-- Adding new keys to either shape must preserve that ordering.

require("c4_shim")
dofile("driver.lua")

Test.assertEqual(
    BuildSetControlCommand("flame_control", "3"),
    [[{"command":"set_control","name":"flame_control","value":"3"}]],
    "documented set_control format"
)

Test.assertEqual(
    BuildSetControlCommand("main_mode", "5"),
    [[{"command":"set_control","name":"main_mode","value":"5"}]],
    "documented set_control with mode=Manual"
)

Test.assertEqual(
    BuildLegacyIndexedCommand("flame_control", "3"),
    [[{"control0":"flame_control","value0":"3"}]],
    "legacy indexed format"
)

-- Numeric values stringified via tostring()
Test.assertEqual(
    BuildSetControlCommand("flame_control", 4),
    [[{"command":"set_control","name":"flame_control","value":"4"}]],
    "numeric value tostring'd to quoted string"
)

-- No spaces anywhere in either output (Spec §2.4 "CRITICAL: All JSON messages
-- must have NO SPACES")
local function assertNoSpaces(s, label)
    Test.assert(not s:find(" "), label .. ": no spaces in output (got: " .. s .. ")")
end
assertNoSpaces(BuildSetControlCommand("a", "b"), "set_control")
assertNoSpaces(BuildLegacyIndexedCommand("a", "b"), "legacy")

-- BuildDeviceControlCommandPlan returns the right number of payloads per format
local function planLabels(plan)
    local labels = {}
    for _, p in ipairs(plan) do
        table.insert(labels, p.label)
    end
    return table.concat(labels, ",")
end

local p1 = BuildDeviceControlCommandPlan("flame_control", "3", COMMAND_FORMAT_LEGACY_ONLY)
Test.assertEqual(planLabels(p1), "legacy", "Legacy Only -> legacy payload only")

local p2 = BuildDeviceControlCommandPlan("flame_control", "3", COMMAND_FORMAT_DOCUMENTED_ONLY)
Test.assertEqual(planLabels(p2), "documented", "Documented Only -> documented payload only")

local p3 = BuildDeviceControlCommandPlan("flame_control", "3", COMMAND_FORMAT_DUAL_DOCUMENTED_FIRST)
Test.assertEqual(planLabels(p3), "documented,legacy", "Dual (Documented First) -> documented then legacy")

local p4 = BuildDeviceControlCommandPlan("flame_control", "3", COMMAND_FORMAT_DUAL_LEGACY_FIRST)
Test.assertEqual(planLabels(p4), "legacy,documented", "Dual (Legacy First) -> legacy then documented")

-- Turn Off uses the dedicated internal alias and forces legacy-only
local p5 = BuildDeviceControlCommandPlan("main_mode", "0", COMMAND_FORMAT_TURN_OFF_LEGACY_ONLY)
Test.assertEqual(planLabels(p5), "legacy", "Turn Off internal alias -> legacy only")

print("test_command_builders OK")
