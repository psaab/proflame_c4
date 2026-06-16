-- C1 Phase 2: vendored WebSocket integration test.
--
-- This test has two halves:
--
-- 1. Probe-transcript replay. The 2026-06-03 device characterize run
--    (tools/probes/evidence/characterize-20260603T024355Z.json) captured
--    the actual application-level frames the Proflame device emits during
--    handshake completion: 1 PROFLAMECONNECTIONOPEN ack followed by 4 JSON
--    frames containing 79 status keys total (the unique set; some keys
--    appear repeated in later frames). The vendored
--    drivers-common-public/module/websocket.lua hands us those payloads
--    via :SetProcessMessageFunction AFTER stripping RFC 6455 framing and
--    masking. So we feed the captured text frames straight into our
--    OnWebSocketMessage callback and assert that every key from the
--    probe lands somewhere downstream (gState / gFirmwareVersions /
--    gTemperatureUnit / WARN-key gating).
--
-- 2. OCS binding-dispatch routing. Our top-level OnConnectionStatusChanged
--    must delegate to OCS[idBinding] when the call is for the vendored
--    WebSocket's binding (gWebSocket.netBinding). Same shape for
--    ReceivedFromNetwork -> RFN. This is the smallest unit of behavior
--    that proves the binding-dispatch wiring works in isolation — without
--    it, the vendored WebSocket's parseHTTPPacket / parseWSPacket never
--    get to run.

require("c4_shim")
dofile("driver.lua")

--------------------------------------------------------------------------------
-- Test 1: Probe-transcript replay
--------------------------------------------------------------------------------

-- Hand-typed transcription of raw_first_5_frames from the probe evidence file.
-- We intentionally inline the strings rather than parsing the JSON-encoded
-- transcript at test time so this test doesn't depend on a particular Lua
-- JSON parser being available (the bundled JSON.lua works, but inlining
-- removes the parser from the test's contract and makes the captured
-- payload directly auditable). The strings below are byte-for-byte copies
-- of tools/probes/evidence/characterize-20260603T024355Z.json.
local probe_frames = {
    "PROFLAMECONNECTIONOPEN",
    [[{"status0":"fw_revision","value0":"FW: 625.04.673","status1":"fw_ifc_c","value1":"FW: 0.0.0","status2":"fw_ifc_s","value2":"FW: 0.0.0","status3":"fw_ble","value3":"FW: 0.0.0","status4":"fw_rc","value4":"FW: 0.0.0.0","status5":"dongle_name","value5":"ADU Fireplace","status6":"wifi_signal_str","value6":"67","status7":"free_heap","value7":"32767","status8":"min_free_heap","value8":"32767","status9":"burner_status","value9":"32672","status10":"temperature_unit","value10":"1","status11":"lamp_control","value11":"0","status12":"pilot_mode","value12":"0","status13":"flame_control","value13":"6","status14":"auxiliary_out","value14":"0","status15":"fan_control","value15":"0","status16":"split_flow","value16":"0","status17":"temperature_set","value17":"770","status18":"room_temperature","value18":"720","status19":"scenario_name","value19":"0","status20":"rgbw_0_code","value20":"2768240640","status21":"rgb_0_intensity","value21":"4294944165","status22":"rgbw_1_code","value22":"10855680","status23":"rgb_1_intensity","value23":"0","status24":"rgbw_2_code","value24":"0","status25":"rgb_2_intensity","value25":"0","status26":"rgbw_3_code","value26":"0","status27":"rgb_3_intensity","value27":"0","status28":"color_period","value28":"0","status29":"sequence_rgb","value29":"1","status30":"timer_status","value30":"0","status31":"timer_count","value31":"10800000","status32":"remote_control","value32":"0","status33":"dongle_type","value33":"1","status34":"modbus_ifc","value34":"0","status35":"reset_dongle","value35":"0","status36":"data_to_server","value36":"0","status37":"true_white","value37":"1"}]],
    [[{"status0":"index_weekly","value0":"0","status1":"p_day_1","value1":"0","status2":"p_day_2","value2":"0","status3":"p_day_3","value3":"0","status4":"p_day_4","value4":"0","status5":"p_day_5","value5":"0","status6":"p_day_6","value6":"0","status7":"p_day_7","value7":"0","status8":"child_lock","value8":"0","status9":"led_p_1","value9":"0","status10":"led_p_2","value10":"0","status11":"led_p_3","value11":"0","status12":"en_lamp","value12":"1","status13":"en_pilot","value13":"1","status14":"en_flame","value14":"1","status15":"en_aux","value15":"1","status16":"en_fan","value16":"1","status17":"en_spl","value17":"1","status18":"en_set","value18":"1","status19":"en_room","value19":"1","status20":"en_weekly","value20":"0","status21":"en_timer","value21":"1","status22":"en_ls_oem","value22":"1","status23":"en_ls","value23":"0","status24":"en_sth","value24":"1","status25":"en_th","value25":"1","status26":"en_man","value26":"1","status27":"index_aux","value27":"0","status28":"led_main","value28":"0","status29":"num_cascade","value29":"0","status30":"en_bit_csc","value30":"0","status31":"idx_room","value31":"0"}]],
    [[{"status0":"idx_room","value0":"0","status1":"idx_room","value1":"0","status2":"idx_room","value2":"0","status3":"idx_room","value3":"0","status4":"idx_room","value4":"0","status5":"idx_room","value5":"0","status6":"label_aux","value6":"4276568","status7":"en_scene","value7":"1","status8":"led_conf","value8":"0","status9":"not_keep_ls","value9":"0","status10":"timer_set","value10":"10800000","status11":"loads_conf","value11":"0"}]],
    [[{"status0":"ota_touch","value0":"0","status1":"ota_dongle","value1":"0","status2":"main_mode","value2":"0"}]],
}

-- The probe captured these 79 unique status keys (handled + ignored). The set
-- comes from all_keys_seen in the evidence file.
local probe_unique_keys = {
    "auxiliary_out", "burner_status", "child_lock", "color_period",
    "data_to_server", "dongle_name", "dongle_type", "en_aux", "en_bit_csc",
    "en_fan", "en_flame", "en_lamp", "en_ls", "en_ls_oem", "en_man",
    "en_pilot", "en_room", "en_scene", "en_set", "en_spl", "en_sth",
    "en_th", "en_timer", "en_weekly", "fan_control", "flame_control",
    "free_heap", "fw_ble", "fw_ifc_c", "fw_ifc_s", "fw_rc", "fw_revision",
    "idx_room", "index_aux", "index_weekly", "label_aux", "lamp_control",
    "led_conf", "led_main", "led_p_1", "led_p_2", "led_p_3", "loads_conf",
    "main_mode", "min_free_heap", "modbus_ifc", "not_keep_ls", "num_cascade",
    "ota_dongle", "ota_touch", "p_day_1", "p_day_2", "p_day_3", "p_day_4",
    "p_day_5", "p_day_6", "p_day_7", "pilot_mode", "remote_control",
    "reset_dongle", "rgb_0_intensity", "rgb_1_intensity", "rgb_2_intensity",
    "rgb_3_intensity", "rgbw_0_code", "rgbw_1_code", "rgbw_2_code",
    "rgbw_3_code", "room_temperature", "scenario_name", "sequence_rgb",
    "split_flow", "temperature_set", "temperature_unit", "timer_count",
    "timer_set", "timer_status", "true_white", "wifi_signal_str",
}
Test.assertEqual(#probe_unique_keys, 79, "probe captured 79 unique status keys")

-- Capture every key ProcessStatusUpdate sees so we can assert coverage. We
-- wrap rather than replace so any downstream side effects (gState updates,
-- WARN-key gating, fw_* / temperature_unit carve-outs) still execute.
local _keys_seen = {}
local _original_ProcessStatusUpdate = ProcessStatusUpdate
ProcessStatusUpdate = function(status, value)
    _keys_seen[status] = (_keys_seen[status] or 0) + 1
    return _original_ProcessStatusUpdate(status, value)
end

-- Stub SetupExtras / UpdateAllProxies / RequestAllStatus / property events so
-- OnWebSocketEstablished doesn't try to drive the whole proxy lifecycle.
-- We're testing the message-processing path, not the established-callback
-- side effects.
local _setup_extras_called = 0
local _update_proxies_called = 0
local _request_status_called = 0
local _status_refresh_started = 0

local _orig_SetupExtras = SetupExtras
local _orig_UpdateAllProxies = UpdateAllProxies
local _orig_RequestAllStatus = RequestAllStatus
local _orig_StartStatusRefreshTimer = StartStatusRefreshTimer
local _orig_HandleConnectionEvent = HandleConnectionEvent

SetupExtras = function() _setup_extras_called = _setup_extras_called + 1 end
UpdateAllProxies = function() _update_proxies_called = _update_proxies_called + 1 end
RequestAllStatus = function() _request_status_called = _request_status_called + 1 end
StartStatusRefreshTimer = function() _status_refresh_started = _status_refresh_started + 1 end
HandleConnectionEvent = function() end

-- Fresh per-test capture so we observe only what this replay produces.
Test.clearPropertyUpdates()
gState.temperature_set = "0"
gState.room_temperature = "0"
gFirmwareVersions = {
    fw_revision = "",
    fw_ble = "",
    fw_ifc_c = "",
    fw_ifc_s = "",
    fw_rc = "",
}
gTemperatureUnit = "F"  -- baseline so the wire-value "1" -> "F" is a no-op

-- Drive the Established hook with a stub WebSocket object — represents the
-- vendored WebSocket calling our :Established callback after parseHTTPPacket
-- validated the upgrade.
local stub_ws = { netBinding = 6100, port = 88, url = "ws://172.16.1.81:88/" }
OnWebSocketEstablished(stub_ws)
Test.assertEqual(gConnected, true, "Established sets gConnected")
Test.assertEqual(gHandshakeComplete, true, "Established sets gHandshakeComplete")
Test.assertEqual(_request_status_called, 1, "Established triggers RequestAllStatus once")
Test.assertEqual(_update_proxies_called, 1, "Established triggers UpdateAllProxies once")
Test.assertEqual(_setup_extras_called, 1, "Established triggers SetupExtras once")
Test.assertEqual(_status_refresh_started, 1, "Established starts the status-refresh timer")

-- Replay the 5 captured frames through the WS message callback exactly as
-- the vendored module would.
for _, frame in ipairs(probe_frames) do
    OnWebSocketMessage(stub_ws, frame)
end

-- Critical app-protocol fields ended up where downstream code expects.
-- Notes on the ones we intentionally do NOT assert here:
--   - timer_count: gated through gTimerExpired (set when timer_status=0
--     processes before timer_count in the same frame). The probe's
--     timer_status=0 path makes timer_count get suppressed before it can
--     land in gState; that's the intended behavior, not a regression.
--   - timer_set: ApplyDeviceStatus explicitly does NOT mirror device
--     timer_set into gState.timer_set (see the "Don't update gState.timer_set
--     from device responses" comment in driver.lua). We assert below that
--     the key was dispatched, which is what the integration cares about.
--   - main_mode: the probe drives main_mode=0 last; that path triggers
--     timer-clear side effects which may write timer_set/timer_count back
--     to "0". Assert through the main-mode side effect (gLastMainMode
--     baseline established) below rather than direct gState read.
Test.assertEqual(gState.flame_control, "6", "flame_control parsed from frame 2")
Test.assertEqual(gState.fan_control, "0", "fan_control parsed from frame 2")
Test.assertEqual(gState.lamp_control, "0", "lamp_control parsed from frame 2")
Test.assertEqual(gState.temperature_set, "770", "temperature_set parsed from frame 2")
Test.assertEqual(gState.room_temperature, "720", "room_temperature parsed from frame 2")
Test.assertEqual(gState.timer_status, "0", "timer_status parsed from frame 2")
Test.assertEqual(gState.wifi_signal_str, "67", "wifi_signal_str parsed from frame 2")
Test.assertEqual(gState.burner_status, "32672", "burner_status parsed from frame 2")
Test.assertEqual(gState.main_mode, "0", "main_mode parsed from frame 5")

-- fw_* carve-out: gFirmwareVersions populates from the indexed frames.
Test.assertEqual(gFirmwareVersions.fw_revision, "FW: 625.04.673", "fw_revision captured")
Test.assertEqual(gFirmwareVersions.fw_ifc_c, "FW: 0.0.0", "fw_ifc_c captured")
Test.assertEqual(gFirmwareVersions.fw_ifc_s, "FW: 0.0.0", "fw_ifc_s captured")
Test.assertEqual(gFirmwareVersions.fw_ble, "FW: 0.0.0", "fw_ble captured")
Test.assertEqual(gFirmwareVersions.fw_rc, "FW: 0.0.0.0", "fw_rc captured")

-- temperature_unit "1" maps to Fahrenheit (idempotent with gTemperatureUnit
-- baseline above; the key is that the carve-out ran without erroring).
Test.assertEqual(gTemperatureUnit, "F", "temperature_unit wire 1 -> F")

-- Coverage assertion: every unique key from the probe got dispatched into
-- ProcessStatusUpdate at least once. The KNOWN_IGNORED ones still get
-- counted here even though they short-circuit inside — they routed
-- through the function and produced a key visit, which is what we're
-- checking.
local missing = {}
for _, key in ipairs(probe_unique_keys) do
    if not _keys_seen[key] then
        table.insert(missing, key)
    end
end
Test.assertEqual(#missing, 0,
    "all 79 probe keys dispatched into ProcessStatusUpdate (missing: "
        .. table.concat(missing, ", ") .. ")")

-- PROFLAMECONNECTIONOPEN handshake-ack handling: Connection Status flips to
-- "Connected" and HandleConnectionEvent fires. We stubbed
-- HandleConnectionEvent to a no-op above, so just assert the
-- C4:UpdateProperty side effect.
local property_updates = Test.getPropertyUpdates()
Test.assertEqual(property_updates["Connection Status"], "Connected",
    "PROFLAMECONNECTIONOPEN flips Connection Status to Connected")

-- Restore stubs so subsequent test sections see the real driver behavior.
ProcessStatusUpdate = _original_ProcessStatusUpdate
SetupExtras = _orig_SetupExtras
UpdateAllProxies = _orig_UpdateAllProxies
RequestAllStatus = _orig_RequestAllStatus
StartStatusRefreshTimer = _orig_StartStatusRefreshTimer
HandleConnectionEvent = _orig_HandleConnectionEvent

print("test_websocket_integration: probe-replay assertions passed")

--------------------------------------------------------------------------------
-- Test 2: OCS / RFN binding-dispatch routing
--------------------------------------------------------------------------------
-- Our shadowing OnConnectionStatusChanged / ReceivedFromNetwork must
-- delegate to the OCS[idBinding] / RFN[idBinding] entries the vendored
-- WebSocket registers in setupC4Connection. If the dispatch is wrong,
-- the vendored parseHTTPPacket / parseWSPacket never get to run and the
-- whole integration is dead in the water.

-- Make sure OCS/RFN tables exist (vendored handlers.lua initializes them
-- at top-level load; this is a belt-and-braces guard for the standalone
-- test environment).
OCS = OCS or {}
RFN = RFN or {}

-- Register a stub WebSocket object and matching OCS/RFN callbacks against
-- a fixed binding id. The real vendored module would do this from inside
-- wsObject:setupC4Connection; we shortcut by writing the registry
-- directly so the test doesn't depend on the vendored Start() path.
local TEST_BINDING = 6123
local ocs_observed = nil
local rfn_observed = nil
gWebSocket = { netBinding = TEST_BINDING, port = 88, url = "ws://test/" }
OCS[TEST_BINDING] = function(idBinding, nPort, strStatus)
    ocs_observed = { idBinding = idBinding, nPort = nPort, strStatus = strStatus }
end
RFN[TEST_BINDING] = function(idBinding, nPort, strData)
    rfn_observed = { idBinding = idBinding, nPort = nPort, strData = strData }
end

-- Driving our top-level handler with the matching binding must reach the
-- OCS[TEST_BINDING] callback the vendored module owns.
OnConnectionStatusChanged(TEST_BINDING, 88, "ONLINE")
Test.assert(ocs_observed ~= nil,
    "OnConnectionStatusChanged delegated to OCS[netBinding]")
Test.assertEqual(ocs_observed.idBinding, TEST_BINDING,
    "OCS callback received the same binding id")
Test.assertEqual(ocs_observed.strStatus, "ONLINE",
    "OCS callback received the strStatus arg unchanged")

-- A non-matching binding must NOT trigger OCS even if a callback is
-- registered (because gWebSocket.netBinding doesn't match).
ocs_observed = nil
OnConnectionStatusChanged(9999, 88, "ONLINE")
Test.assertEqual(ocs_observed, nil,
    "OnConnectionStatusChanged with foreign binding does NOT delegate")

-- Same shape for ReceivedFromNetwork.
ReceivedFromNetwork(TEST_BINDING, 88, "some raw bytes")
Test.assert(rfn_observed ~= nil,
    "ReceivedFromNetwork delegated to RFN[netBinding]")
Test.assertEqual(rfn_observed.strData, "some raw bytes",
    "RFN callback received the strData arg unchanged")

rfn_observed = nil
ReceivedFromNetwork(9999, 88, "ignored")
Test.assertEqual(rfn_observed, nil,
    "ReceivedFromNetwork with foreign binding does NOT delegate")

-- When gWebSocket is nil (e.g., driver loaded but Connect() hasn't run),
-- the top-level handlers must not crash — they should fall through
-- silently.
gWebSocket = nil
ocs_observed = nil
rfn_observed = nil
OnConnectionStatusChanged(TEST_BINDING, 88, "OFFLINE")
ReceivedFromNetwork(TEST_BINDING, 88, "ignored")
Test.assertEqual(ocs_observed, nil,
    "OnConnectionStatusChanged is a no-op when gWebSocket is nil")
Test.assertEqual(rfn_observed, nil,
    "ReceivedFromNetwork is a no-op when gWebSocket is nil")

-- Clean up the registry so other tests in this Lua process (none today,
-- but defensive) see a clean slate.
OCS[TEST_BINDING] = nil
RFN[TEST_BINDING] = nil

print("test_websocket_integration: binding-dispatch assertions passed")

--------------------------------------------------------------------------------
-- Test 3: Lifecycle paths flagged in Codex review of PR #68
--
-- Three BLOCKER-class bugs were fixed before merge:
--   #1 OnWebSocketOffline left gWebSocket non-nil -> next Connect() bailed,
--      so the driver got stuck Disconnected forever after a network drop.
--   #2 Disconnect's :Close() leaves vendor's Sockets[url] cached for 3s, so
--      a fast Disconnect+Connect (e.g. Port-property edit) reused the dying
--      socket and the old close timer then NetDisconnected the new binding.
--   #4 Vendor's setupC4Connection returns a ws object even when all bindings
--      6100-6199 are busy (netBinding nil). Without the fix, UI sticks at
--      "Connecting..." forever because :Start is a no-op without a binding.
-- These assertions guard the fixes.
--------------------------------------------------------------------------------

-- Set up minimal stubs for the vendor APIs TeardownWebSocket touches so the
-- test runs without a real network. We don't need to verify the vendor
-- module's internal correctness here, only that our teardown calls into the
-- right places.
local netdisconnect_calls = {}
local original_NetDisconnect = C4.NetDisconnect
function C4:NetDisconnect(binding, port)
    table.insert(netdisconnect_calls, { binding = binding, port = port })
end

local original_SetBindingAddress = C4.SetBindingAddress
function C4:SetBindingAddress(binding, addr)
    -- no-op; just don't crash
end

local cancelled_timers = {}
local original_CancelTimer = CancelTimer
CancelTimer = function(name) table.insert(cancelled_timers, name) end

WebSocket = WebSocket or {}
WebSocket.Sockets = WebSocket.Sockets or {}

-- BLOCKER #1 fix: OnWebSocketOffline must clear gWebSocket so Connect()
-- can allocate fresh on the next OnReconnectTimer fire. Stub the vendored
-- WebSocket object enough for TeardownWebSocket to clean up.
local OFFLINE_BINDING = 6101
local OFFLINE_URL = "ws://192.0.2.99:88/"
local offline_ws = {
    netBinding = OFFLINE_BINDING,
    port = 88,
    url = OFFLINE_URL,
    timerPrefix = "WS_test_offline_Timer_",
    connected = true,
    running = true,
}
WebSocket.Sockets[OFFLINE_URL] = offline_ws
WebSocket.Sockets[OFFLINE_BINDING] = offline_ws
gWebSocket = offline_ws

-- Stub the higher-level reconnect to avoid driving real timers.
local reconnect_scheduled = false
local original_ScheduleReconnect = ScheduleReconnect
ScheduleReconnect = function() reconnect_scheduled = true end

-- HandleConnectionEvent dispatches into proxy notifications we don't care
-- about for this test.
local original_HandleConnectionEvent = HandleConnectionEvent
HandleConnectionEvent = function() end

netdisconnect_calls = {}
cancelled_timers = {}
OnWebSocketOffline(offline_ws)

Test.assertEqual(gWebSocket, nil,
    "BLOCKER #1: OnWebSocketOffline clears gWebSocket so reconnect can allocate fresh")
Test.assertEqual(WebSocket.Sockets[OFFLINE_URL], nil,
    "BLOCKER #2: vendor Sockets[url] cache busted on offline")
Test.assertEqual(WebSocket.Sockets[OFFLINE_BINDING], nil,
    "BLOCKER #2: vendor Sockets[binding] cache busted on offline")
Test.assert(#netdisconnect_calls > 0,
    "OnWebSocketOffline triggers C4:NetDisconnect on the old binding")
Test.assertEqual(netdisconnect_calls[1].binding, OFFLINE_BINDING,
    "NetDisconnect targets the right binding")
Test.assert(reconnect_scheduled, "OnWebSocketOffline schedules a reconnect")
local saw_closing_cancel = false
for _, name in ipairs(cancelled_timers) do
    if name == "WS_test_offline_Timer_Closing" then saw_closing_cancel = true end
end
Test.assert(saw_closing_cancel,
    "BLOCKER #2: TeardownWebSocket cancels the 3s Closing timer so it can't kill a future reconnect")

-- BLOCKER #2 fix proven by the cache+timer assertions above. Now also drive
-- Disconnect explicitly to confirm the same synchronous teardown happens
-- via the user-initiated path (and that the close frame IS sent there).
local DISCONNECT_BINDING = 6102
local DISCONNECT_URL = "ws://192.0.2.99:88/"  -- vendor caches by url
local close_frame_sends = {}
local disconnect_ws = {
    netBinding = DISCONNECT_BINDING,
    port = 88,
    url = DISCONNECT_URL,
    timerPrefix = "WS_test_disconnect_Timer_",
    connected = true,
    running = true,
    sendToNetwork = function(self, pkt)
        table.insert(close_frame_sends, pkt)
    end,
}
WebSocket.Sockets[DISCONNECT_URL] = disconnect_ws
WebSocket.Sockets[DISCONNECT_BINDING] = disconnect_ws
gWebSocket = disconnect_ws
gConnected = true
gHandshakeComplete = true

netdisconnect_calls = {}
cancelled_timers = {}

-- The driver Disconnect() calls several module-level helpers; stub them.
local original_StopStatusRefreshTimer = StopStatusRefreshTimer
local original_CancelPendingTimerCommandTimers = CancelPendingTimerCommandTimers
local original_CancelTurnOffConfirmTimer = CancelTurnOffConfirmTimer
local original_SetTimerSuppression = SetTimerSuppression
local original_ClearTurnOffInProgress = ClearTurnOffInProgress
StopStatusRefreshTimer = function() end
CancelPendingTimerCommandTimers = function() end
CancelTurnOffConfirmTimer = function() end
SetTimerSuppression = function() end
ClearTurnOffInProgress = function() end

Disconnect()

Test.assertEqual(gWebSocket, nil, "Disconnect clears gWebSocket")
Test.assert(#close_frame_sends >= 1,
    "Disconnect (sendCloseFrame=true) emits the WS close frame")
-- RFC 6455 close frame = 0x88, 0x82, mask(0,0,0,0), payload(0x03,0xE8) = status 1000
Test.assertEqual(close_frame_sends[1]:sub(1, 2), string.char(0x88, 0x82),
    "Close frame opcode 0x88 and masked-len 0x82 are correct")
Test.assertEqual(close_frame_sends[1]:byte(7), 0x03,
    "Close frame status high byte is 0x03 (1000)")
Test.assertEqual(close_frame_sends[1]:byte(8), 0xE8,
    "Close frame status low byte is 0xE8 (1000)")
Test.assertEqual(WebSocket.Sockets[DISCONNECT_URL], nil,
    "BLOCKER #2: Disconnect busts vendor Sockets[url] cache synchronously")
Test.assert(#netdisconnect_calls > 0,
    "Disconnect triggers C4:NetDisconnect on the old binding")

StopStatusRefreshTimer = original_StopStatusRefreshTimer
CancelPendingTimerCommandTimers = original_CancelPendingTimerCommandTimers
CancelTurnOffConfirmTimer = original_CancelTurnOffConfirmTimer
SetTimerSuppression = original_SetTimerSuppression
ClearTurnOffInProgress = original_ClearTurnOffInProgress

C4.NetDisconnect = original_NetDisconnect
C4.SetBindingAddress = original_SetBindingAddress
CancelTimer = original_CancelTimer
ScheduleReconnect = original_ScheduleReconnect
HandleConnectionEvent = original_HandleConnectionEvent

print("test_websocket_integration: lifecycle teardown assertions passed")

--------------------------------------------------------------------------------
-- Test 4: PROFLAMEPONG updates the "Last Keepalive Response" timestamp (#89)
--
-- B4/#86 restored the app-level PROFLAMEPING keepalive, so the device once
-- again replies PROFLAMEPONG. #89 re-surfaces the round-trip liveness time in
-- Composer as "Last Keepalive Response" (the property #70 removed as dead UI
-- when the keepalive was gone — live again now). ParseStatusMessage must
-- update that timestamp on a PROFLAMEPONG, must NOT touch the old
-- "Last Ping Response" name, and must not error.
--------------------------------------------------------------------------------

Test.clearPropertyUpdates()
-- Should not error.
ParseStatusMessage("PROFLAMEPONG")
local pong_updates = Test.getPropertyUpdates()
Test.assert(pong_updates["Last Keepalive Response"] ~= nil,
    "PROFLAMEPONG stamps the 'Last Keepalive Response' property")
Test.assert(tostring(pong_updates["Last Keepalive Response"]):match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$"),
    "'Last Keepalive Response' is a full YYYY-MM-DD HH:MM:SS timestamp")
Test.assertEqual(pong_updates["Last Ping Response"], nil,
    "PROFLAMEPONG does NOT update the old (removed) 'Last Ping Response' name")

print("test_websocket_integration: PROFLAMEPONG-stamp assertions passed")
