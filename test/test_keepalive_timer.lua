-- Verify the app-level PROFLAMEPING keepalive (B4/#86).
--
-- C1 Phase 2 (#68) replaced the hand-rolled 5s PROFLAMEPING text-frame
-- keepalive with the vendored 30s RFC 6455 WS-level ping. On-device that
-- regressed: the Proflame dongle closes the socket ~30s after every connect,
-- in lock-step with the WS ping (it enforces an inbound-idle session timeout
-- and does not treat the control-frame ping as activity). The fix disables
-- the WS ping and restores the app-level keepalive on a "Keepalive Interval
-- (seconds)" property, with gMissedKeepalives as a half-open-link watchdog.

require("c4_shim")
dofile("driver.lua")

local _timers
local original_SetTimer = C4.SetTimer
function C4:SetTimer(delay_ms, fn, repeating)
    local handle = { delay_ms = delay_ms, fn = fn, repeating = repeating, cancelled = false }
    handle.Cancel = function(self) self.cancelled = true end
    table.insert(_timers, handle)
    return handle
end

_timers = {}

--------------------------------------------------------------------------------
-- 1. StartKeepaliveTimer schedules a repeating C4:SetTimer at seconds×1000.
--------------------------------------------------------------------------------
Properties["Keepalive Interval (seconds)"] = "15"
StartKeepaliveTimer()
Test.assertEqual(#_timers, 1, "one timer scheduled")
Test.assertEqual(_timers[1].delay_ms, 15 * 1000, "interval is 15 seconds in ms")
Test.assertEqual(_timers[1].repeating, true, "timer is repeating")
Test.assertEqual(gMissedKeepalives, 0, "StartKeepaliveTimer resets the miss counter")

--------------------------------------------------------------------------------
-- 2. Setting interval to 0 disables (no timer; existing handle cleared).
--------------------------------------------------------------------------------
_timers = {}
gKeepaliveTimerId = nil
Properties["Keepalive Interval (seconds)"] = "0"
StartKeepaliveTimer()
Test.assertEqual(#_timers, 0, "interval=0 schedules no timer")
Test.assertEqual(gKeepaliveTimerId, nil, "timer id stays nil when disabled")

--------------------------------------------------------------------------------
-- 3. Restart cancels any previous timer before scheduling a new one.
--------------------------------------------------------------------------------
_timers = {}
Properties["Keepalive Interval (seconds)"] = "15"
StartKeepaliveTimer()
local first_handle = gKeepaliveTimerId
Properties["Keepalive Interval (seconds)"] = "30"
StartKeepaliveTimer()
Test.assertEqual(#_timers, 2, "two SetTimer calls total")
Test.assert(first_handle.cancelled, "previous timer cancelled before re-scheduling")
Test.assertEqual(_timers[2].delay_ms, 30 * 1000, "new interval is 30 seconds in ms")
Test.assert(gKeepaliveTimerId ~= first_handle, "timer handle changed after restart")

--------------------------------------------------------------------------------
-- 4. StopKeepaliveTimer cancels and clears the handle; idempotent on nil.
--------------------------------------------------------------------------------
StopKeepaliveTimer()
Test.assertEqual(gKeepaliveTimerId, nil, "timer id cleared after Stop")
StopKeepaliveTimer()
Test.assertEqual(gKeepaliveTimerId, nil, "Stop is idempotent on nil")

--------------------------------------------------------------------------------
-- 5. Non-numeric interval falls back to the 15-second default.
--------------------------------------------------------------------------------
_timers = {}
gKeepaliveTimerId = nil
Properties["Keepalive Interval (seconds)"] = "abc"
StartKeepaliveTimer()
Test.assertEqual(#_timers, 1, "garbage interval falls back to default")
Test.assertEqual(_timers[1].delay_ms, 15 * 1000, "default is 15 seconds")

--------------------------------------------------------------------------------
-- 6. OnKeepaliveTimer sends PROFLAMEPING only when fully connected, and the
--    watchdog forces a reconnect after three silent intervals. Any inbound
--    frame resets the miss counter.
--------------------------------------------------------------------------------
local _ping_calls = 0
local original_SendWebSocketMessage = SendWebSocketMessage
SendWebSocketMessage = function(msg)
    if msg == "PROFLAMEPING" then _ping_calls = _ping_calls + 1 end
    return true
end
local _reconnects = 0
local original_Reconnect = Reconnect
Reconnect = function() _reconnects = _reconnects + 1 end

-- Disconnected / pre-handshake: no ping, no counter movement.
gConnected = false
gHandshakeComplete = false
gMissedKeepalives = 0
OnKeepaliveTimer()
Test.assertEqual(_ping_calls, 0, "no ping while disconnected")
Test.assertEqual(gMissedKeepalives, 0, "miss counter untouched while disconnected")

gConnected = true
gHandshakeComplete = false
OnKeepaliveTimer()
Test.assertEqual(_ping_calls, 0, "no ping after TCP but pre-handshake")

-- Fully connected: each silent fire sends a ping and increments the counter.
gConnected = true
gHandshakeComplete = true
gMissedKeepalives = 0
OnKeepaliveTimer()
Test.assertEqual(_ping_calls, 1, "fire 1 sends a ping")
Test.assertEqual(gMissedKeepalives, 1, "fire 1 increments miss counter")
OnKeepaliveTimer()
Test.assertEqual(_ping_calls, 2, "fire 2 sends a ping")
Test.assertEqual(gMissedKeepalives, 2, "fire 2 increments miss counter")

-- Third consecutive silent fire trips the watchdog: reconnect, no ping.
OnKeepaliveTimer()
Test.assertEqual(_reconnects, 1, "fire 3 forces a reconnect")
Test.assertEqual(_ping_calls, 2, "watchdog fire does not also send a ping")
Test.assertEqual(gMissedKeepalives, 0, "watchdog resets the miss counter")

-- Inbound traffic resets the counter so a live device never trips the watchdog.
gMissedKeepalives = 2
OnWebSocketMessage(nil, "PROFLAMEPONG")
Test.assertEqual(gMissedKeepalives, 0, "any inbound frame resets the miss counter")

SendWebSocketMessage = original_SendWebSocketMessage
Reconnect = original_Reconnect

--------------------------------------------------------------------------------
-- 7. OnWebSocketOffline stops the keepalive timer (mirrors the status-refresh
--    timer teardown — a leftover repeating timer through an outage is sloppy).
--------------------------------------------------------------------------------
_timers = {}
Properties["Keepalive Interval (seconds)"] = "15"
StartKeepaliveTimer()
local offline_handle = gKeepaliveTimerId
Test.assert(offline_handle ~= nil, "timer scheduled before Offline")

local original_HandleConnectionEvent = HandleConnectionEvent
local original_ScheduleReconnect = ScheduleReconnect
HandleConnectionEvent = function() end
ScheduleReconnect = function() end

OnWebSocketOffline({})

Test.assert(offline_handle.cancelled, "Offline callback cancelled the keepalive timer")
Test.assertEqual(gKeepaliveTimerId, nil, "Offline callback cleared timer handle")

HandleConnectionEvent = original_HandleConnectionEvent
ScheduleReconnect = original_ScheduleReconnect
C4.SetTimer = original_SetTimer

print("test_keepalive_timer: all assertions passed")
