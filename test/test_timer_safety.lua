-- Timer-required safety policy (Spec §6.9).
--
-- When the fireplace is in an on-state without a running auto-off timer, the
-- driver must keep it bounded. There are two cases:
--
--   * No timer was ever armed (e.g. the physical remote turned the fireplace
--     on): arm the configured Default Timer and let the device keep running.
--     The driver must NOT force the fireplace off — doing so produced an
--     on/off war with the remote (the device re-asserts on, the driver slams
--     it off, repeat).
--   * The auto-off timer expired: honor it and turn the fireplace off.

require("c4_shim")
dofile("driver.lua")

-- Pretend we're connected so device commands actually go out, and capture
-- every outbound WebSocket payload.
local sent = {}
gConnected = true
gHandshakeComplete = true
gWebSocket = { Send = function(_, msg) table.insert(sent, msg) end }

local function reset_sent() sent = {} end
local function any_sent(needle)
    for _, m in ipairs(sent) do
        if m:find(needle, 1, true) then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- 1. On without a timer -> arm the default timer, do NOT turn off.
--    Reproduces the real device flow: the status dump carries timer_status="0",
--    which sets gTimerExpired=true *before* main_mode reaches an on-state. The
--    arm decision must key off gTimerCountExpired (genuine count-down), NOT
--    gTimerExpired, or the remote turn-on is force-offed (the original bug).
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerExpired = true            -- set by the device's timer_status=0 (NOT a count-down)
gTimerCountExpired = false      -- the timer never counted down to zero
gTimerSafetyOffPending = false
gState.main_mode = "6"          -- High flame == on
gState.timer_status = "0"       -- no running timer
gStatusSeen["timer_status"] = true

EnforceTimerRequiredForOnState("test: remote turned on without timer", false)

Test.assert(any_sent('"timer_set"'), "arms a timer (timer_set sent) when on without a timer")
Test.assertEqual(gState.timer_status, "1", "optimistic timer_status flips to running")
Test.assert(
    not any_sent('"main_mode","value0":"0"') and not any_sent('"main_mode":"0"'),
    "does NOT force the fireplace off when on without a timer"
)
Test.assertEqual(gTimerSafetyOffPending, false, "no pending force-off recorded on the arm path")

--------------------------------------------------------------------------------
-- 2. Timer expired -> force off (auto-off still works).
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerSafetyOffPending = false
gTimerExpired = true            -- timer ran down to 0
gTimerCountExpired = true       -- genuine count-down expiry
gState.main_mode = "6"
gState.timer_status = "0"
gStatusSeen["timer_status"] = true

EnforceTimerRequiredForOnState("test: timer expired", false)

Test.assert(any_sent('"main_mode"'), "expired timer turns the fireplace off (main_mode sent)")
Test.assertEqual(gTurnOffInProgress, true, "expired-timer path runs the Turn Off sequence")

--------------------------------------------------------------------------------
-- 3. Arm send fails -> no unbounded recursion, falls back to force-off.
--    (A failed timer_set send re-enters enforcement via SetTimerSuppression(false);
--    without the re-entrancy latch this recursed without bound.)
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerExpired = false
gTimerCountExpired = false
gTimerSafetyOffPending = false
gTimerSafetyArming = false
gState.main_mode = "6"
gState.timer_status = "0"
gStatusSeen["timer_status"] = true

-- Force every outbound send to fail *while the device still reports ready*, so
-- SetTimerValueAndArm's timer_set send returns false and takes its
-- SetTimerSuppression(false) failure path — the exact re-entry that recursed.
local real_send = SendWebSocketMessage
SendWebSocketMessage = function(_) return false end

EnforceTimerRequiredForOnState("test: arm send fails", false)  -- must return, not hang

SendWebSocketMessage = real_send

Test.assertEqual(gTimerSafetyArming, false, "arming latch is released after a failed arm")
Test.assertEqual(gTimerSafetyOffPending, true, "failed arm falls back to the force-off path")

--------------------------------------------------------------------------------
-- 4. Off-state -> policy is a no-op.
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerExpired = false
gTimerSafetyOffPending = false
gState.main_mode = "0"          -- off
gState.timer_status = "0"
gStatusSeen["timer_status"] = true

EnforceTimerRequiredForOnState("test: off state", false)

Test.assertEqual(#sent, 0, "no commands sent when the fireplace is already off")

--------------------------------------------------------------------------------
-- 5. End-to-end through the real status pipeline (ProcessStatusUpdate).
--    The device's status dump delivers timer_status="0" (which sets
--    gTimerExpired) BEFORE main_mode reaches an on-state — exactly the on-device
--    sequence that made the original fix a no-op. The remote turn-on must still
--    ARM, not force off.
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerExpired = false
gTimerCountExpired = false
gTimerSafetyOffPending = false
gTimerSafetyArming = false
gState.main_mode = "0"
gState.timer_status = "1"
gStatusSeen = {}

ProcessStatusUpdate("timer_status", "0")   -- device reports no timer
Test.assertEqual(gTimerExpired, true, "timer_status=0 sets gTimerExpired (stale-count guard)")
Test.assertEqual(gTimerCountExpired, false, "timer_status=0 alone is NOT a genuine count-down expiry")

reset_sent()
ProcessStatusUpdate("main_mode", "6")      -- remote turns the fireplace on
Test.assert(any_sent('"timer_set"'), "remote turn-on (with gTimerExpired set) still ARMS the default timer")
Test.assert(
    not any_sent('"main_mode","value0":"0"'),
    "remote turn-on is NOT force-offed end-to-end (regression guard for the gTimerExpired-vs-count-down bug)"
)

print("test_timer_safety OK")
