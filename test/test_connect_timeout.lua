-- Verify the connect-attempt watchdog (issue #71).
--
-- After the C1 Phase 2 cutover to the vendored WebSocket, the window between
-- ws:Start() and the first vendored callback had no liveness timer: the
-- vendored ping/pong watchdog only arms after the binding goes ONLINE, and
-- the one-shot reconnect timer refuses to fire while gConnecting is true. So
-- a Connect() against an unreachable device whose C4:NetConnect never produced
-- an OFFLINE ConnectionChanged left gConnecting stuck true forever — UI pinned
-- at "Connecting..." with no retry. StartConnectTimeoutTimer guarantees
-- forward progress.

require("c4_shim")
dofile("driver.lua")

-- Per-test timer log. Each fake timer handle carries its own `cancelled`
-- flag (see test_status_refresh_timer.lua for why we don't index back into a
-- shared table).
local _timers
local original_SetTimer = C4.SetTimer
function C4:SetTimer(delay_ms, fn, repeating)
    local handle = { delay_ms = delay_ms, fn = fn, repeating = repeating, cancelled = false }
    handle.Cancel = function(self) self.cancelled = true end
    table.insert(_timers, handle)
    return handle
end

-- A stub vendored WebSocket that Connect() can drive without a network.
-- WebSocket:new returns it; the four setters and Start are no-ops, and
-- netBinding is populated so Connect() doesn't take the "all bindings busy"
-- early-return branch.
local function makeStubWebSocketFactory(netBinding)
    local ws = {
        netBinding = netBinding,
        port = 88,
        url = "ws://192.0.2.50:88/",
        started = 0,
    }
    function ws:SetEstablishedFunction(f) self._est = f end
    function ws:SetProcessMessageFunction(f) self._msg = f end
    function ws:SetOfflineFunction(f) self._off = f end
    function ws:SetClosedByRemoteFunction(f) self._cbr = f end
    function ws:Start() self.started = self.started + 1 end
    return {
        Sockets = {},
        new = function(self, url) ws.url = url; return ws end,
    }, ws
end

--------------------------------------------------------------------------------
-- 1. Connect() arms a one-shot connect-timeout timer at Connect Timeout seconds.
--------------------------------------------------------------------------------
_timers = {}
Properties["IP Address"] = "192.0.2.50"
Properties["Port"] = "88"
Properties["Connect Timeout (seconds)"] = "30"
gWebSocket = nil
gConnected = false
gConnecting = false

local factory
factory, _ = makeStubWebSocketFactory(6100)
WebSocket = factory

Connect()
Test.assertEqual(gConnecting, true, "Connect sets gConnecting")
Test.assert(gConnectTimeoutTimerId ~= nil, "Connect armed the connect-timeout watchdog")
-- The status-refresh timer is NOT armed by Connect (only by Established), so
-- the only timer scheduled here is the connect watchdog.
local watchdog = nil
for _, t in ipairs(_timers) do
    if t.delay_ms == 30 * 1000 and t.repeating == false then watchdog = t end
end
Test.assert(watchdog ~= nil, "watchdog scheduled at 30s, one-shot")
Test.assertEqual(gConnectTimeoutTimerId, watchdog, "gConnectTimeoutTimerId points at the watchdog handle")

--------------------------------------------------------------------------------
-- 2. Defensive guard: a non-positive timeout arms no timer rather than
--    scheduling a pathological 0ms one-shot. This value is NOT reachable from
--    the UI (the property is RANGED_INTEGER min 5 per Codex review of #72 —
--    the watchdog must not be disablable), but the code guards against a
--    nil/garbage Properties value slipping past the `or 30` fallback.
--------------------------------------------------------------------------------
_timers = {}
gWebSocket = nil
gConnected = false
gConnecting = false
gConnectTimeoutTimerId = nil
Properties["Connect Timeout (seconds)"] = "0"
factory, _ = makeStubWebSocketFactory(6101)
WebSocket = factory

Connect()
Test.assertEqual(gConnectTimeoutTimerId, nil, "Connect Timeout=0 arms no watchdog")
local any_watchdog = false
for _, t in ipairs(_timers) do
    if t.repeating == false then any_watchdog = true end
end
Test.assertEqual(any_watchdog, false, "no one-shot timer scheduled when disabled")

--------------------------------------------------------------------------------
-- 3. Non-numeric Connect Timeout falls back to the 30s default.
--------------------------------------------------------------------------------
_timers = {}
gWebSocket = nil
gConnected = false
gConnecting = false
gConnectTimeoutTimerId = nil
Properties["Connect Timeout (seconds)"] = "garbage"
factory, _ = makeStubWebSocketFactory(6102)
WebSocket = factory

Connect()
Test.assert(gConnectTimeoutTimerId ~= nil, "garbage timeout falls back to a watchdog")
Test.assertEqual(gConnectTimeoutTimerId.delay_ms, 30 * 1000, "fallback default is 30s")

--------------------------------------------------------------------------------
-- 4. OnWebSocketEstablished cancels the watchdog.
--------------------------------------------------------------------------------
-- Stub the established side effects so we exercise only the timer-cancel path.
local _orig_HandleConnectionEvent = HandleConnectionEvent
local _orig_StartStatusRefreshTimer = StartStatusRefreshTimer
local _orig_RequestAllStatus = RequestAllStatus
local _orig_UpdateAllProxies = UpdateAllProxies
local _orig_SetupExtras = SetupExtras
HandleConnectionEvent = function() end
StartStatusRefreshTimer = function() end
RequestAllStatus = function() end
UpdateAllProxies = function() end
SetupExtras = function() end

_timers = {}
gConnectTimeoutTimerId = nil
Properties["Connect Timeout (seconds)"] = "30"
StartConnectTimeoutTimer()
local est_watchdog = gConnectTimeoutTimerId
Test.assert(est_watchdog ~= nil, "watchdog armed before Established")

OnWebSocketEstablished({ netBinding = 6100, port = 88, url = "ws://192.0.2.50:88/" })
Test.assert(est_watchdog.cancelled, "Established cancelled the watchdog")
Test.assertEqual(gConnectTimeoutTimerId, nil, "Established cleared the watchdog handle")

HandleConnectionEvent = _orig_HandleConnectionEvent
StartStatusRefreshTimer = _orig_StartStatusRefreshTimer
RequestAllStatus = _orig_RequestAllStatus
UpdateAllProxies = _orig_UpdateAllProxies
SetupExtras = _orig_SetupExtras

--------------------------------------------------------------------------------
-- 5. OnWebSocketOffline cancels the watchdog.
--------------------------------------------------------------------------------
local _orig_ScheduleReconnect = ScheduleReconnect
_orig_HandleConnectionEvent = HandleConnectionEvent
local _orig_StopStatusRefreshTimer = StopStatusRefreshTimer
ScheduleReconnect = function() end
HandleConnectionEvent = function() end
StopStatusRefreshTimer = function() end

_timers = {}
gConnectTimeoutTimerId = nil
gWebSocket = nil  -- TeardownWebSocket short-circuits on nil
StartConnectTimeoutTimer()
local off_watchdog = gConnectTimeoutTimerId
Test.assert(off_watchdog ~= nil, "watchdog armed before Offline")

OnWebSocketOffline({})
Test.assert(off_watchdog.cancelled, "Offline cancelled the watchdog")
Test.assertEqual(gConnectTimeoutTimerId, nil, "Offline cleared the watchdog handle")

ScheduleReconnect = _orig_ScheduleReconnect
HandleConnectionEvent = _orig_HandleConnectionEvent
StopStatusRefreshTimer = _orig_StopStatusRefreshTimer

--------------------------------------------------------------------------------
-- 6. OnConnectTimeout firing mid-connect tears down and reschedules.
--------------------------------------------------------------------------------
local _teardown_calls = {}
local _orig_TeardownWebSocket = TeardownWebSocket
TeardownWebSocket = function(send) table.insert(_teardown_calls, send) end
local _reconnect_scheduled = 0
_orig_ScheduleReconnect = ScheduleReconnect
ScheduleReconnect = function() _reconnect_scheduled = _reconnect_scheduled + 1 end
Test.clearPropertyUpdates()

gConnected = false
gConnecting = true
gHandshakeComplete = false
gConnectTimeoutTimerId = { Cancel = function() end }  -- pretend the timer is live

OnConnectTimeout()
Test.assertEqual(gConnectTimeoutTimerId, nil, "OnConnectTimeout clears its own handle")
Test.assertEqual(#_teardown_calls, 1, "mid-connect timeout tears down the socket")
Test.assertEqual(_teardown_calls[1], false, "teardown does NOT send a close frame (TCP never came up)")
Test.assertEqual(gConnecting, false, "mid-connect timeout clears gConnecting")
Test.assertEqual(gHandshakeComplete, false, "mid-connect timeout clears gHandshakeComplete")
Test.assertEqual(_reconnect_scheduled, 1, "mid-connect timeout schedules a reconnect")
local updates = Test.getPropertyUpdates()
Test.assertEqual(updates["Connection Status"], "Disconnected",
    "mid-connect timeout sets Connection Status to Disconnected")

--------------------------------------------------------------------------------
-- 7. OnConnectTimeout firing after a successful connect is a no-op.
--    (A late timer that Established's Stop somehow missed must not nuke a live
--     connection.)
--------------------------------------------------------------------------------
_teardown_calls = {}
_reconnect_scheduled = 0
gConnected = true
gConnecting = false
gConnectTimeoutTimerId = { Cancel = function() end }

OnConnectTimeout()
Test.assertEqual(#_teardown_calls, 0, "no teardown when already connected")
Test.assertEqual(_reconnect_scheduled, 0, "no reschedule when already connected")
Test.assertEqual(gConnected, true, "connected state untouched by a stale timeout")

TeardownWebSocket = _orig_TeardownWebSocket
ScheduleReconnect = _orig_ScheduleReconnect

--------------------------------------------------------------------------------
-- 8. Disconnect stops the watchdog.
--------------------------------------------------------------------------------
_orig_StopStatusRefreshTimer = StopStatusRefreshTimer
local _orig_CancelPendingTimerCommandTimers = CancelPendingTimerCommandTimers
local _orig_CancelTurnOffConfirmTimer = CancelTurnOffConfirmTimer
local _orig_SetTimerSuppression = SetTimerSuppression
local _orig_ClearTurnOffInProgress = ClearTurnOffInProgress
_orig_TeardownWebSocket = TeardownWebSocket
_orig_HandleConnectionEvent = HandleConnectionEvent
StopStatusRefreshTimer = function() end
CancelPendingTimerCommandTimers = function() end
CancelTurnOffConfirmTimer = function() end
SetTimerSuppression = function() end
ClearTurnOffInProgress = function() end
TeardownWebSocket = function() end
HandleConnectionEvent = function() end

local disc_watchdog = { cancelled = false }
disc_watchdog.Cancel = function(self) self.cancelled = true end
gConnectTimeoutTimerId = disc_watchdog
gSuppressTimerUpdates = false

Disconnect()
Test.assert(disc_watchdog.cancelled, "Disconnect cancelled the watchdog")
Test.assertEqual(gConnectTimeoutTimerId, nil, "Disconnect cleared the watchdog handle")

StopStatusRefreshTimer = _orig_StopStatusRefreshTimer
CancelPendingTimerCommandTimers = _orig_CancelPendingTimerCommandTimers
CancelTurnOffConfirmTimer = _orig_CancelTurnOffConfirmTimer
SetTimerSuppression = _orig_SetTimerSuppression
ClearTurnOffInProgress = _orig_ClearTurnOffInProgress
TeardownWebSocket = _orig_TeardownWebSocket
HandleConnectionEvent = _orig_HandleConnectionEvent

C4.SetTimer = original_SetTimer

print("test_connect_timeout: all assertions passed")
