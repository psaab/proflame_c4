-- Verify the B3 periodic-status-refresh timer.
--
-- Motivated by tools/probes/FINDINGS.md §8: the device pushes 0 frames in a
-- 10-second silent window — no spontaneous status updates. If someone
-- presses a button on the physical fireplace panel, the driver never sees
-- the change until the next user command or reconnect. The Status Refresh
-- Interval re-sends PROFLAMECONNECTION on a slow timer so local-panel
-- changes don't go unnoticed forever.

require("c4_shim")
dofile("driver.lua")

--------------------------------------------------------------------------------
-- 1. StartStatusRefreshTimer schedules a repeating C4:SetTimer at minutes×60s.
--------------------------------------------------------------------------------
-- Per-test timer log. Each fake timer handle carries its own `cancelled`
-- flag rather than indexing back into a shared table, because the test
-- replaces `_timers` between sections — a Cancel closure that captured
-- `_timers[id]` would dangle.
local _timers
local original_SetTimer = C4.SetTimer
function C4:SetTimer(delay_ms, fn, repeating)
    local handle = { delay_ms = delay_ms, fn = fn, repeating = repeating, cancelled = false }
    handle.Cancel = function(self) self.cancelled = true end
    table.insert(_timers, handle)
    return handle
end

_timers = {}

-- Default to 5 minute interval (driver.xml default).
Properties["Status Refresh Interval (minutes)"] = "5"

StartStatusRefreshTimer()
Test.assertEqual(#_timers, 1, "one timer scheduled")
Test.assertEqual(_timers[1].delay_ms, 5 * 60 * 1000, "interval is 5 minutes in ms")
Test.assertEqual(_timers[1].repeating, true, "timer is repeating")

--------------------------------------------------------------------------------
-- 2. Setting interval to 0 disables (no timer scheduled, existing timer stopped).
--------------------------------------------------------------------------------
_timers = {}
gStatusRefreshTimerId = nil
Properties["Status Refresh Interval (minutes)"] = "0"
StartStatusRefreshTimer()
Test.assertEqual(#_timers, 0, "interval=0 schedules no timer")
Test.assertEqual(gStatusRefreshTimerId, nil, "timer id stays nil when disabled")

--------------------------------------------------------------------------------
-- 3. Restart cancels any previous timer before scheduling a new one. The
--    OnPropertyChanged handler calls StartStatusRefreshTimer to re-arm with a
--    new interval; if we didn't cancel first, intervals would compound.
--------------------------------------------------------------------------------
_timers = {}
Properties["Status Refresh Interval (minutes)"] = "5"
StartStatusRefreshTimer()
local first_handle = gStatusRefreshTimerId
Properties["Status Refresh Interval (minutes)"] = "10"
StartStatusRefreshTimer()
Test.assertEqual(#_timers, 2, "two SetTimer calls total")
Test.assert(first_handle.cancelled, "previous timer cancelled before re-scheduling")
Test.assertEqual(_timers[2].delay_ms, 10 * 60 * 1000, "new interval is 10 minutes in ms")
Test.assert(gStatusRefreshTimerId ~= first_handle, "timer handle changed after restart")

--------------------------------------------------------------------------------
-- 4. StopStatusRefreshTimer cancels and clears the handle.
--------------------------------------------------------------------------------
StopStatusRefreshTimer()
Test.assertEqual(gStatusRefreshTimerId, nil, "timer id cleared after Stop")

-- StopStatusRefreshTimer when no timer is set must be a no-op (called from
-- Disconnect even if we never connected).
StopStatusRefreshTimer()
Test.assertEqual(gStatusRefreshTimerId, nil, "Stop is idempotent on nil")

--------------------------------------------------------------------------------
-- 5. Non-numeric interval falls back to the 5-minute default rather than
--    nil-erroring. A user typing garbage in Composer shouldn't crash the
--    timer system.
--------------------------------------------------------------------------------
_timers = {}
gStatusRefreshTimerId = nil
Properties["Status Refresh Interval (minutes)"] = "abc"
StartStatusRefreshTimer()
Test.assertEqual(#_timers, 1, "garbage interval falls back to default")
Test.assertEqual(_timers[1].delay_ms, 5 * 60 * 1000, "default is 5 minutes")

--------------------------------------------------------------------------------
-- 6. The timer's fire callback only requests status when the connection is
--    fully up. Firing while disconnected must not call RequestAllStatus —
--    the request would just be discarded by SendText and the log spam
--    would be unhelpful.
--------------------------------------------------------------------------------
local _request_calls = 0
local original_RequestAllStatus = RequestAllStatus
RequestAllStatus = function() _request_calls = _request_calls + 1 end

gConnected = false
gHandshakeComplete = false
_timers = {}
Properties["Status Refresh Interval (minutes)"] = "5"
StartStatusRefreshTimer()
_timers[1].fn()
Test.assertEqual(_request_calls, 0, "timer fire while disconnected: no request")

gConnected = true
gHandshakeComplete = false
_timers[1].fn()
Test.assertEqual(_request_calls, 0, "timer fire after TCP but pre-handshake: no request")

gConnected = true
gHandshakeComplete = true
_timers[1].fn()
Test.assertEqual(_request_calls, 1, "timer fire when fully connected: one request")

RequestAllStatus = original_RequestAllStatus

--------------------------------------------------------------------------------
-- 7. OFFLINE network-status branch stops the status-refresh timer alongside
--    the ping timer. Codex flagged this — without it, a repeating timer
--    would keep firing through an arbitrarily long outage. The gating in
--    the fire callback makes it a no-op, but leaving a live timer running
--    is sloppy and inconsistent with Disconnect()'s behavior.
--------------------------------------------------------------------------------
_timers = {}
Properties["Status Refresh Interval (minutes)"] = "5"
StartStatusRefreshTimer()
local offline_handle = gStatusRefreshTimerId
Test.assert(offline_handle ~= nil, "timer scheduled before OFFLINE")

-- Stub HandleConnectionEvent / C4:UpdateProperty / ScheduleReconnect so the
-- OFFLINE branch can run without exercising the rest of the connection
-- lifecycle.
local original_HandleConnectionEvent = HandleConnectionEvent
local original_ScheduleReconnect = ScheduleReconnect
HandleConnectionEvent = function() end
ScheduleReconnect = function() end

-- OnConnectionStatusChanged signature: (idBinding, nPort, strStatus). The
-- function ignores binding+port in the OFFLINE branch — only strStatus
-- routes the if/elseif.
OnConnectionStatusChanged(NETWORK_BINDING_ID, tonumber(Properties["Port"]) or 88, "OFFLINE")

Test.assert(offline_handle.cancelled, "OFFLINE branch cancelled the status-refresh timer")
Test.assertEqual(gStatusRefreshTimerId, nil, "OFFLINE branch cleared timer handle")

HandleConnectionEvent = original_HandleConnectionEvent
ScheduleReconnect = original_ScheduleReconnect
C4.SetTimer = original_SetTimer

print("test_status_refresh_timer: all assertions passed")
