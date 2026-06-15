-- Issue #64: BuildThermostatDynamicCapabilities (the table sent via
-- DYNAMIC_CAPABILITIES_CHANGED) must NOT carry HVAC_MODES / HVAC_STATES.
-- Those are constant for this heat-only device, declared statically in
-- driver.xml (<hvac_modes>/<hvac_states>), and the allowed-mode subset is
-- emitted separately via ALLOWED_HVAC_MODES_CHANGED. They are not part of
-- DYNAMIC_CAPABILITIES_CHANGED.

require("c4_shim")
dofile("driver.lua")

--------------------------------------------------------------------------------
-- 1. The dynamic-capabilities payload must NOT contain the redundant keys.
--------------------------------------------------------------------------------
local caps = BuildThermostatDynamicCapabilities()

Test.assertEqual(
    caps.HVAC_MODES, nil,
    "BuildThermostatDynamicCapabilities must NOT include HVAC_MODES (issue #64)"
)
Test.assertEqual(
    caps.HVAC_STATES, nil,
    "BuildThermostatDynamicCapabilities must NOT include HVAC_STATES (issue #64)"
)

--------------------------------------------------------------------------------
-- 2. The other capabilities must STILL be present and unchanged.
--------------------------------------------------------------------------------
Test.assertEqual(caps.HAS_EXTRAS, "true", "HAS_EXTRAS retained")
Test.assertEqual(caps.CAN_PRESET, "False", "CAN_PRESET retained")
Test.assertEqual(caps.CAN_PRESET_SCHEDULE, "False", "CAN_PRESET_SCHEDULE retained")
Test.assert(caps.HOLD_MODES ~= nil, "HOLD_MODES retained")
Test.assertEqual(caps.FAN_MODES, "Off,Low,Medium,High", "FAN_MODES retained")

--------------------------------------------------------------------------------
-- 3. End-to-end: the table actually pushed to the proxy via
--    DYNAMIC_CAPABILITIES_CHANGED carries neither key, while the
--    ALLOWED_HVAC_MODES_CHANGED notification still emits the heat-only subset.
--------------------------------------------------------------------------------
-- The shim's C4 has no real SendToProxy (its metatable __index returns a noop),
-- so override the field directly to capture every emitted proxy notification.
local _sent = {}
local _real_SendToProxy = rawget(C4, "SendToProxy")
function C4:SendToProxy(id, command, params)
    table.insert(_sent, { id = id, command = command, params = params })
end

SendThermostatDynamicCapabilities("test")
SendThermostatAllowedModes("test")

C4.SendToProxy = _real_SendToProxy

local dynPayload, allowedHvacPayload
for _, m in ipairs(_sent) do
    if m.command == "DYNAMIC_CAPABILITIES_CHANGED" then
        dynPayload = m.params
    elseif m.command == "ALLOWED_HVAC_MODES_CHANGED" then
        allowedHvacPayload = m.params
    end
end

Test.assert(dynPayload ~= nil, "DYNAMIC_CAPABILITIES_CHANGED was emitted")
Test.assertEqual(
    dynPayload.HVAC_MODES, nil,
    "emitted DYNAMIC_CAPABILITIES_CHANGED payload omits HVAC_MODES"
)
Test.assertEqual(
    dynPayload.HVAC_STATES, nil,
    "emitted DYNAMIC_CAPABILITIES_CHANGED payload omits HVAC_STATES"
)

Test.assert(allowedHvacPayload ~= nil, "ALLOWED_HVAC_MODES_CHANGED still emitted")
Test.assertEqual(
    allowedHvacPayload.MODES, "Off,Heat",
    "ALLOWED_HVAC_MODES_CHANGED still carries the heat-only subset"
)

print("test_dynamic_capabilities OK")
