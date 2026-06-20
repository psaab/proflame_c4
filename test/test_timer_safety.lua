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
--------------------------------------------------------------------------------
reset_sent()
gSuppressTimerUpdates = false
gTurnOffInProgress = false
gTimerExpired = false
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

print("test_timer_safety OK")
