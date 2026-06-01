-- Control4 API shim for offline unit tests.
--
-- Sets up the minimal subset of the C4 global, Properties table, and timer
-- entry points the driver touches during construction (top-level execution)
-- and during the pure-logic code paths the test suite exercises. Anything
-- not stubbed below should be no-ops via the metatable __index fallback so
-- a test that accidentally touches a new C4 method gets a benign callable
-- rather than a "attempt to call a nil value" crash.
--
-- Tests should `require("c4_shim")` first, then `dofile("driver.lua")`.

local function noop() end

-- Methods touched by the driver but not explicitly stubbed below fall through
-- to `noop`, which returns nil (NOT empty string). If a future test calls a
-- C4 method that the production driver expects to return a string/table, add
-- an explicit stub for that method below — don't rely on the fallback.
C4 = setmetatable({}, {
    __index = function()
        return noop
    end,
})

Properties = setmetatable({}, {
    __index = function()
        return ""
    end,
})

--------------------------------------------------------------------------------
-- Crypto / Base64 — match the QW1 contract exactly enough for handshake derivation
--------------------------------------------------------------------------------

function C4:Hash(algo, input, options)
    -- Unit tests don't validate handshakes against a real device; return a
    -- deterministic stub. If a future test needs a real digest it can override.
    return "stub-hash-" .. tostring(input):sub(1, 8)
end

function C4:Base64Encode(s)
    -- Identity encode for tests; sufficient for code paths that just need a
    -- non-empty string back. Replace in a specific test if real B64 is needed.
    return tostring(s or "")
end

function C4:Base64Decode(s)
    return tostring(s or "")
end

--------------------------------------------------------------------------------
-- Persistence — in-memory backing store so tests round-trip realistically.
--------------------------------------------------------------------------------

local _persist_store = {}

function C4:PersistGetValue(key, encrypted)
    return _persist_store[key]
end

function C4:PersistSetValue(key, value, encrypted)
    _persist_store[key] = value
end

function C4:PersistDeleteValue(key)
    _persist_store[key] = nil
end

--------------------------------------------------------------------------------
-- Logging sinks — capturable so tests can assert routing behavior.
--------------------------------------------------------------------------------

local _captured_debug_log = {}
local _captured_error_log = {}

function C4:DebugLog(msg)
    table.insert(_captured_debug_log, tostring(msg))
end

function C4:ErrorLog(msg)
    table.insert(_captured_error_log, tostring(msg))
end

--------------------------------------------------------------------------------
-- Property updates — capturable for tests that need to assert
-- C4:UpdateProperty calls.
--------------------------------------------------------------------------------

local _property_updates = {}

function C4:UpdateProperty(name, value)
    _property_updates[name] = value
end

--------------------------------------------------------------------------------
-- Test helpers — namespace `Test` for inspection / reset between cases.
--------------------------------------------------------------------------------

Test = {}

function Test.resetPersist()
    _persist_store = {}
end

function Test.getPersistStore()
    return _persist_store
end

function Test.clearLogCapture()
    _captured_debug_log = {}
    _captured_error_log = {}
end

function Test.getDebugLog()
    return _captured_debug_log
end

function Test.getErrorLog()
    return _captured_error_log
end

function Test.clearPropertyUpdates()
    _property_updates = {}
end

function Test.getPropertyUpdates()
    return _property_updates
end

function Test.assert(condition, message)
    if not condition then
        error("ASSERTION FAILED: " .. tostring(message), 2)
    end
end

-- Reference equality. For tables use Test.assertTableEqual.
function Test.assertEqual(actual, expected, message)
    if actual ~= expected then
        error(
            "ASSERTION FAILED: "
                .. tostring(message or "")
                .. "\n  expected: "
                .. tostring(expected)
                .. "\n  actual:   "
                .. tostring(actual),
            2
        )
    end
end

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function pretty(v, depth)
    depth = depth or 0
    if depth > 4 then return "{...}" end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        table.insert(parts, tostring(k) .. "=" .. pretty(val, depth + 1))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Recursive value-equality for tables (and pass-through for primitives).
function Test.assertTableEqual(actual, expected, message)
    if not deepEqual(actual, expected) then
        error(
            "ASSERTION FAILED: "
                .. tostring(message or "")
                .. "\n  expected: "
                .. pretty(expected)
                .. "\n  actual:   "
                .. pretty(actual),
            2
        )
    end
end
