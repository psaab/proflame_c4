-- Temperature codec round-trips. The Proflame device encodes temperatures as
-- integer (Fahrenheit x 10), e.g. 70°F = "700", 68.5°F = "685".

require("c4_shim")
dofile("driver.lua")

-- DecodeTemperature: int*10 -> F (preserves half-degree precision per Spec §2.8).
Test.assertEqual(DecodeTemperature("700"), 70, "70F decode")
Test.assertEqual(DecodeTemperature("685"), 68.5, "68.5F decode (half-degree precision)")
Test.assertEqual(DecodeTemperature("320"), 32, "32F (freezing) decode")
Test.assertEqual(DecodeTemperature("900"), 90, "90F (max setpoint) decode")
Test.assertEqual(DecodeTemperature("0"), 0, "0F decode")
Test.assertEqual(DecodeTemperature("-100"), -10, "negative temperature decode")

-- EncodeTemperature: F -> int*10 string
Test.assertEqual(EncodeTemperature(70), "700", "70F encode")
Test.assertEqual(EncodeTemperature(68.5), "685", "68.5F encode")
Test.assertEqual(EncodeTemperature(32), "320", "32F encode")

-- Round-trip including fractional half-degree setpoints
for _, f in ipairs({ 32, 50, 60, 65.5, 68.5, 70, 72, 75, 80, 90 }) do
    local encoded = EncodeTemperature(f)
    local decoded = DecodeTemperature(encoded)
    Test.assertEqual(decoded, f, "round-trip " .. tostring(f) .. "F")
end

-- Fahrenheit <-> Celsius conversions
Test.assertEqual(FahrenheitToCelsius(32), 0, "32F = 0C")
Test.assertEqual(FahrenheitToCelsius(212), 100, "212F = 100C")
Test.assertEqual(CelsiusToFahrenheit(0), 32, "0C = 32F")
Test.assertEqual(CelsiusToFahrenheit(100), 212, "100C = 212F")
Test.assertEqual(CelsiusToFahrenheit(20), 68, "20C = 68F")

print("test_temperature OK")
