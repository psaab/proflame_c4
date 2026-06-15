-- Verify the global print() shadow (issue #69).
--
-- The vendored drivers-common-public/module/websocket.lua calls the bare
-- global print(...) in several spots (:Start(), the keepalive timeout path,
-- ConnectionChanged, etc.), bypassing the driver's Debug Mode / Debug Level
-- gating. driver.lua installs a print shadow that forwards those calls
-- through dbg_debug so they're gated by the configured log level and land in
-- the C4:DebugLog sink instead of raw console output.

-- Capture the genuine builtin print BEFORE loading the driver so we can assert
-- the shadow actually replaced it.
local _builtin_print = print

require("c4_shim")
dofile("driver.lua")

--------------------------------------------------------------------------------
-- 1. The shadow is installed: the global `print` is no longer the builtin.
--------------------------------------------------------------------------------
Test.assert(print ~= _builtin_print, "global print was replaced by the shadow")
Test.assertEqual(type(print), "function", "shadowed print is still callable")

--------------------------------------------------------------------------------
-- 2. A vendor-style print(...) routes through the driver's debug logger.
--    With Debug Mode = On and Debug Level = Debug, dbg_debug reaches the
--    C4:DebugLog sink (captured by c4_shim).
--------------------------------------------------------------------------------
Properties["Debug Mode"] = "On"
Properties["Debug Level"] = "Debug"
ApplyDebugLogSettings()

Test.clearLogCapture()
print("vendor-style", "msg")

local debugLog = Test.getDebugLog()
Test.assert(#debugLog >= 1, "print() produced at least one debug-log line")

-- The varargs must be tostring-ed and space-joined like builtin print().
local found = false
for _, line in ipairs(debugLog) do
    if line:find("vendor%-style msg", 1) then
        found = true
        break
    end
end
Test.assert(found, "print() varargs joined with a space and routed to DebugLog")

--------------------------------------------------------------------------------
-- 3. nil / mixed args are tostring-ed without erroring (vendor concatenates
--    self.url etc.; we must be just as forgiving as builtin print()).
--------------------------------------------------------------------------------
Test.clearLogCapture()
local ok = pcall(function() print("a", nil, 42, true) end)
Test.assert(ok, "print() with nil/number/boolean args does not error")

local debugLog2 = Test.getDebugLog()
local found2 = false
for _, line in ipairs(debugLog2) do
    if line:find("a nil 42 true", 1, true) then
        found2 = true
        break
    end
end
Test.assert(found2, "mixed/nil args tostring-ed and space-joined")

--------------------------------------------------------------------------------
-- 4. Gating: when the level excludes Debug (Debug Level = Error), a vendor
--    print() must NOT reach the debug sink — that's the whole point of #69.
--------------------------------------------------------------------------------
Properties["Debug Mode"] = "On"
Properties["Debug Level"] = "Error"
ApplyDebugLogSettings()

Test.clearLogCapture()
print("should", "be", "suppressed")
Test.assertEqual(#Test.getDebugLog(), 0, "vendor print suppressed when level < Debug")

-- Restore a sane logging level for any later in-process use.
Properties["Debug Level"] = "Debug"
ApplyDebugLogSettings()

--------------------------------------------------------------------------------
-- 5. No infinite recursion when Debug Mode mirrors to the console. With
--    "Print and Log" mode the logger's _log() calls the global print to mirror
--    output; the shadow's re-entrancy guard must keep that one level deep.
--    (If recursion were unbounded this call would stack-overflow rather than
--    return.)
--------------------------------------------------------------------------------
local okNoRecurse = pcall(function() print("recursion", "guard", "check") end)
Test.assert(okNoRecurse, "print under Print-and-Log mode does not recurse/overflow")

-- Use the captured builtin so this status line is not itself swallowed by the
-- shadow under the test's gating.
_builtin_print("test_print_redirect: all assertions passed")
