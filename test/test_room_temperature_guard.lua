-- Room-temperature plausibility guard.
--
-- The codec is Fahrenheit x10 ("720" -> 72.0°F). Some firmware reports an
-- uninitialized/sentinel reading like raw "6845" -> 684.5°F when no real
-- sensor value is available. Such out-of-range values must be dropped so the
-- bogus number never reaches the "Room Temperature" property or the thermostat
-- proxy; the last good reading is retained.

require("c4_shim")
dofile("driver.lua")

-- Seed a known-good last value so we can prove it is retained on rejection.
gState.room_temperature = "720"

-- Implausible sentinel (the field-reported bug): 684.5°F -> dropped.
local change = ApplyDeviceStatus("room_temperature", "6845")
Test.assertEqual(change, nil, "implausible room temperature (684.5F) is dropped")
Test.assertEqual(gState.room_temperature, "720", "last good reading is retained on rejection")

-- temperature_read is an alias for the same field; also guarded.
change = ApplyDeviceStatus("temperature_read", "6845")
Test.assertEqual(change, nil, "implausible temperature_read alias is dropped too")

-- A plausible reading updates state and dispatches a change.
change = ApplyDeviceStatus("room_temperature", "685")
Test.assert(change ~= nil, "plausible room temperature (68.5F) is accepted")
Test.assertEqual(change.status, "room_temperature", "accepted reading dispatches a room_temperature change")
Test.assertEqual(gState.room_temperature, "685", "accepted reading updates state")

-- Boundary values around the window are accepted.
Test.assert(ApplyDeviceStatus("room_temperature", "1400") ~= nil, "140.0F (max) accepted")
Test.assert(ApplyDeviceStatus("room_temperature", "-400") ~= nil, "-40.0F (min) accepted")

-- Just outside the window is rejected.
Test.assertEqual(ApplyDeviceStatus("room_temperature", "1405"), nil, "140.5F (above max) dropped")

-- Non-numeric junk must be dropped, not silently accepted as the DecodeTemperature
-- 700 fallback (70.0F, which is inside the window).
gState.room_temperature = "700"
Test.assertEqual(ApplyDeviceStatus("room_temperature", "nan"), nil, "non-numeric reading dropped")
Test.assertEqual(ApplyDeviceStatus("room_temperature", ""), nil, "empty reading dropped")
Test.assertEqual(gState.room_temperature, "700", "non-numeric junk does not overwrite last good value")

print("test_room_temperature_guard OK")
