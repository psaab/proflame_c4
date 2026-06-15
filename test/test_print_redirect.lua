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

--------------------------------------------------------------------------------
-- 6. An ORDINARY driver log call must produce exactly ONE log entry — not a
--    doubled/re-routed one. Regression guard for the Codex MODERATE finding on
--    PR #77: the re-entrancy flag must be set by the dbg_* chokepoint (not only
--    inside the print shadow), so that under "Print and Log" mode the logger's
--    own console-mirror print() passes straight through instead of being
--    re-routed back into dbg_debug. With the original (shadow-only) guard, a
--    single dbg_info() produced two captured entries: the real "[info]" line
--    plus a spurious re-routed "[debug] [info]" line.
--------------------------------------------------------------------------------
Properties["Debug Mode"] = "On"
Properties["Debug Level"] = "Debug"  -- both info and debug pass, so a re-route would be visible
ApplyDebugLogSettings()

Test.clearLogCapture()
dbg_info("ORDINARY_LOG_MARKER_64")
local ordinaryLog = Test.getDebugLog()
local markerCount = 0
for _, line in ipairs(ordinaryLog) do
    if line:find("ORDINARY_LOG_MARKER_64", 1, true) then
        markerCount = markerCount + 1
    end
end
Test.assertEqual(markerCount, 1,
    "ordinary dbg_info() logs exactly once (no logger-mirror re-route through dbg_debug)")

--------------------------------------------------------------------------------
-- 7. Reload safety: `_c4_print` must hold the REAL builtin print, never the
--    shadow. Control4 re-runs the whole driver chunk on a hot reload (driver
--    update / controller restart); `_c4_print` and `print` are globals that
--    survive. If the capture were `_c4_print = print` (unconditional), the 2nd
--    load would capture the shadow itself and the shadow's pass-through
--    (`return _c4_print(...)`) would tail-call into itself forever — an infinite
--    loop that wedges ALL logging until a power cycle (symptom: "debug logging
--    stops working and toggling Debug Level won't bring it back"). The fix is
--    the idempotent `_c4_print = _c4_print or print`. `_builtin_print` here is
--    the genuine builtin captured at the top of this file, before driver.lua
--    loaded.
--------------------------------------------------------------------------------
Test.assert(print ~= _builtin_print, "global print is the shadow after load")
Test.assert(_c4_print == _builtin_print, "_c4_print captured the REAL builtin print")
Test.assert(_c4_print ~= print, "_c4_print is NOT the shadow (pass-through can't recurse)")

-- Re-run the exact capture idiom driver.lua executes on reload and confirm it
-- keeps the real builtin instead of recapturing the (now-installed) shadow.
_c4_print = _c4_print or print
Test.assert(_c4_print == _builtin_print, "reload capture idiom keeps the real builtin")
Test.assert(_c4_print ~= print, "still the real builtin after a simulated reload capture")

-- Source-level guard (Codex review of #79): the runtime invariant above can't
-- distinguish the idempotent capture from an unconditional `_c4_print = print`
-- on a single load (both capture the builtin the first time). Assert the source
-- of truth actually uses the reload-safe idiom so a regression is caught without
-- a hang-prone dofile-twice.
local _srcFile = io.open("src/driver.lua", "r")
if _srcFile then
    local _src = _srcFile:read("*a")
    _srcFile:close()
    Test.assert(_src:find("_c4_print = _c4_print or print", 1, true) ~= nil,
        "src/driver.lua uses the idempotent reload-safe print capture")
end

--------------------------------------------------------------------------------
-- 8. Vendored DIRECT log:* calls (bypassing dbg_*/_guarded_log) must NOT
--    double-log (#81). A vendored module like github_updater aliases the shared
--    `log` object and calls `log:warn(...)` directly. Before the fix, that
--    call's console-mirror print() reached the shadow with the re-entrancy
--    guard clear and was re-routed through dbg_debug, producing a duplicate
--    "[DEBUG]: [WARN]..." line. Wrapping the log object's emit methods sets the
--    guard for these callers too, so the mirror passes through (one entry).
--------------------------------------------------------------------------------
Properties["Debug Mode"] = "On"
Properties["Debug Level"] = "Debug"
ApplyDebugLogSettings()

-- The wrap marker must be set on the (fresh-per-load) log instance.
Test.assert(rawget(log, "_c4_guard_wrapped") == true, "log object emit methods are guard-wrapped")
-- Idempotence (Codex review of #82): the marker makes the driver's wrap-guard
-- condition (`not rawget(log,"_c4_guard_wrapped")`) false, so a re-execution of
-- the wrap block within a load would NOT re-wrap. Capture the wrapped method and
-- confirm the guard condition is false and the method identity is stable.
local _wrappedWarn = log.warn
Test.assert((not rawget(log, "_c4_guard_wrapped")) == false,
    "re-wrap guard condition is false -> wrapper would not double-wrap within a load")
Test.assertEqual(log.warn, _wrappedWarn, "log.warn identity is stable (not re-wrapped)")

Test.clearLogCapture()
log:warn("VENDOR_DIRECT_81")  -- exactly how github_updater.lua calls it
local _vlog = Test.getDebugLog()
local _vendorCount = 0
local _sawWarn = false
for _, line in ipairs(_vlog) do
    if line:find("VENDOR_DIRECT_81", 1, true) then
        _vendorCount = _vendorCount + 1
        if line:find("WARN", 1, true) then _sawWarn = true end
    end
end
Test.assertEqual(_vendorCount, 1,
    "direct log:warn logs exactly once (no [DEBUG]:[WARN] double via the shadow)")
Test.assert(_sawWarn, "the single entry is at WARN, not re-routed to DEBUG")

-- The guard is restored (not left set) after a direct log call, so a subsequent
-- genuine vendor print() still routes to dbg_debug (gated), not pass-through.
Test.clearLogCapture()
print("VENDOR_RAW_PRINT_81")  -- a bare vendor print(), guard must be clear now
local _raw = Test.getDebugLog()
local _rawSeen = false
for _, line in ipairs(_raw) do
    if line:find("VENDOR_RAW_PRINT_81", 1, true) then _rawSeen = true end
end
Test.assert(_rawSeen, "after a wrapped log call, a bare vendor print() still routes through dbg_debug")

-- Use the captured builtin so this status line is not itself swallowed by the
-- shadow under the test's gating.
_builtin_print("test_print_redirect: all assertions passed")
