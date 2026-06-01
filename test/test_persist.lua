-- vendor/persist.lua + LogDriverVersionTransition behavior. Uses the C4 shim's
-- in-memory persist store backing.

require("c4_shim")
dofile("driver.lua")

Test.resetPersist()

-- Basic round-trip with primitive value
persist:set("test.string", "hello")
Test.assertEqual(persist:get("test.string", nil), "hello", "string round-trip")

persist:set("test.number", 42)
Test.assertEqual(persist:get("test.number", nil), 42, "number round-trip")

persist:set("test.bool", true)
Test.assertEqual(persist:get("test.bool", nil), true, "bool round-trip")

-- Table round-trip preserves nested structure
persist:set("test.table", { a = 1, b = { c = "deep", d = true } })
local r = persist:get("test.table", nil)
Test.assertEqual(type(r), "table", "table comes back as table")
Test.assertEqual(r.a, 1, "table.a")
Test.assertEqual(r.b.c, "deep", "table.b.c (nested)")
Test.assertEqual(r.b.d, true, "table.b.d (nested bool)")

-- Default returned when key absent
Test.assertEqual(persist:get("test.missing", "fallback"), "fallback", "missing key -> default")
Test.assertEqual(persist:get("test.missing", nil), nil, "missing key with nil default -> nil")

-- set(nil) deletes
persist:set("test.string", nil)
Test.assertEqual(persist:get("test.string", "gone"), "gone", "set(nil) deletes the key")

-- delete() also works
persist:set("test.number", 99)
persist:delete("test.number")
Test.assertEqual(persist:get("test.number", "deleted"), "deleted", "delete() removes the key")

-- Empty / invalid keys are no-ops (defensive)
persist:set("", "ignored")
Test.assertEqual(persist:get("", "default"), "default", "empty key is a no-op")

-- Corrupt cache value falls through to default
Test.resetPersist()
local store = Test.getPersistStore()
store["test.corrupt"] = "this is not valid JSON"
Test.assertEqual(persist:get("test.corrupt", "fallback"), "fallback", "corrupt JSON -> default")

--------------------------------------------------------------------------------
-- LogDriverVersionTransition write-count contract (from the T2b adversarial
-- review: only persist:set when the cached value actually differs).
--------------------------------------------------------------------------------

Test.resetPersist()

-- Wrap C4:PersistSetValue with a counter so we can assert write economy.
local set_calls = 0
local original_set = C4.PersistSetValue
function C4:PersistSetValue(key, value, encrypted)
    if key == PERSIST_KEY_LAST_VERSION then
        set_calls = set_calls + 1
    end
    original_set(self, key, value, encrypted)
end

-- First run: cache is empty -> 1 write expected
set_calls = 0
LogDriverVersionTransition()
Test.assertEqual(set_calls, 1, "first run: 1 write")

-- Same version on next call: 0 writes expected
set_calls = 0
LogDriverVersionTransition()
Test.assertEqual(set_calls, 0, "same version: 0 writes")

-- Simulated upgrade: 1 write expected
local store2 = Test.getPersistStore()
store2[PERSIST_KEY_LAST_VERSION] = '"2026051731"' -- JSON-encoded prior version
set_calls = 0
LogDriverVersionTransition()
Test.assertEqual(set_calls, 1, "upgrade: 1 write")

-- Confirm post-upgrade cached value is now the current DRIVER_VERSION
local stored = persist:get(PERSIST_KEY_LAST_VERSION, nil)
Test.assertEqual(stored, DRIVER_VERSION, "cache updated to current DRIVER_VERSION")

print("test_persist OK")
