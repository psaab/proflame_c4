-- Thin-wrapper layer over vendor/JSON.lua. Verifies the string-coercion shim
-- in JsonDecode and the format-string-safe contract of the command builders.

require("c4_shim")
dofile("driver.lua")

-- Indexed status payload from Spec §2.4
local indexed = [[{"status0":"main_mode","value0":"5","status1":"flame_control","value1":"3"}]]
local d = JsonDecode(indexed)
Test.assertEqual(d.status0, "main_mode", "indexed status0")
Test.assertEqual(d.value0, "5", "indexed value0 (string)")
Test.assertEqual(d.status1, "flame_control", "indexed status1")
Test.assertEqual(d.value1, "3", "indexed value1 (string)")

-- Direct-key payload (Spec §2.4 alternate format)
local direct = [[{"temperature_read":"700","timer_read":"3600000","rssi":"45"}]]
local dr = JsonDecode(direct)
Test.assertEqual(dr.temperature_read, "700", "direct temperature_read")
Test.assertEqual(dr.timer_read, "3600000", "direct timer_read (ms)")
Test.assertEqual(dr.rssi, "45", "direct rssi")

-- Unquoted numeric values coerce to strings (preserves the legacy contract)
local unquoted = [[{"temperature_read":700,"timer_read":3600000}]]
local du = JsonDecode(unquoted)
Test.assertEqual(du.temperature_read, "700", "unquoted number -> string")
Test.assertEqual(du.timer_read, "3600000", "unquoted timer ms -> string")
Test.assertEqual(type(du.temperature_read), "string", "value type is string")

-- Booleans coerce to "true"/"false" strings
local bools = [[{"thermo_control":true,"pilot_control":false}]]
local db = JsonDecode(bools)
Test.assertEqual(db.thermo_control, "true", "bool true -> 'true'")
Test.assertEqual(db.pilot_control, "false", "bool false -> 'false'")

-- Nested objects are silently dropped (matches the pre-T2 hand-rolled parser
-- contract: flat objects only)
local nested = [[{"outer":"a","nested":{"inner":"b"},"trailing":"c"}]]
local dn = JsonDecode(nested)
Test.assertEqual(dn.outer, "a", "outer key preserved")
Test.assertEqual(dn.trailing, "c", "trailing key after nested object preserved")
Test.assertEqual(dn.nested, nil, "nested object dropped")

-- Malformed JSON fails closed (returns empty table)
local malformed = JsonDecode([[{"foo":"bar]])
Test.assertEqual(type(malformed), "table", "malformed JSON -> table")
Test.assert(next(malformed) == nil, "malformed JSON -> empty table")

-- nil / non-string input
Test.assertEqual(type(JsonDecode(nil)), "table", "nil input -> table")
Test.assertEqual(type(JsonDecode("")), "table", "empty string -> table")

-- JsonEscape: format-string safety contract
Test.assertEqual(JsonEscape("simple"), "simple", "ascii passthrough")
Test.assertEqual(JsonEscape([[a"b]]), [[a\"b]], "embedded quote escaped")
Test.assertEqual(JsonEscape([[a\b]]), [[a\\b]], "embedded backslash escaped")
Test.assertEqual(JsonEscape(""), "", "empty string")

-- JsonEncode wraps tables
Test.assertEqual(JsonEncode({}), "[]", "empty table -> empty array (JSON.lua default for ambiguous tables)")
local encoded = JsonEncode({ a = "1", b = "2" })
-- Alphabetical sort means a < b
Test.assertEqual(encoded, [[{"a":"1","b":"2"}]], "table encoded with alphabetical key sort")

print("test_json OK")
