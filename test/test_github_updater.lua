-- Full vendored github_updater + http_client + ReceivedAsync dispatcher +
-- Install Latest Release Composer-command wiring.

require("c4_shim")

-- Capture C4:urlGet calls + property updates
local _urlgets = {}
function C4:urlGet(url, headers, encrypted, callback, flags)
    table.insert(_urlgets, { url = url, headers = headers })
    return #_urlgets -- ticket
end
function C4:UpdateProperty(name, value)
    -- Forward to shim's existing capture mechanism
end

-- Make GetDevicesByC4iName return a non-empty result so updateAll's
-- "only update installed drivers" filter doesn't drop our entry.
function C4:GetDevicesByC4iName(name)
    return { 12345 } -- pretend our driver is installed at device id 12345
end

dofile("driver.lua")

--------------------------------------------------------------------------------
-- 1. http_client wires through ReceivedAsync dispatcher
--------------------------------------------------------------------------------
local d_test = http_client:get("https://example.com/foo", { ["X-Test"] = "1" })
Test.assertEqual(#_urlgets, 1, "http_client:get fired one C4:urlGet")
Test.assertEqual(_urlgets[1].url, "https://example.com/foo", "url passed through")
Test.assertEqual(_urlgets[1].headers["X-Test"], "1", "custom header passed through")

local resolved
d_test:next(function(r) resolved = r end, function(e) resolved = { error = e.error } end)
ReceivedAsync(1, "OK", 200, {}, nil)
Test.assertEqual(resolved.body, "OK", "deferred resolved with body")
Test.assertEqual(resolved.code, 200, "deferred resolved with code")

--------------------------------------------------------------------------------
-- 2. http_client rejects deferred on 4xx/5xx
--------------------------------------------------------------------------------
local d2 = http_client:get("https://example.com/bad")
local rejected
d2:next(function() rejected = "RESOLVED" end, function(e) rejected = e end)
ReceivedAsync(2, "nope", 404, {}, nil)
Test.assertEqual(rejected.code, 404, "4xx rejects with code")
Test.assert(rejected.error:find("404"), "err includes 404")

--------------------------------------------------------------------------------
-- 3. ReceivedAsync for an unregistered ticket is a no-op
--------------------------------------------------------------------------------
ReceivedAsync(9999, "stray", 200, {}, nil)  -- no callback registered

--------------------------------------------------------------------------------
-- 4. Install Latest Release happy path: latest tag matches current -> "Already up to date"
--------------------------------------------------------------------------------
gUpdateInProgress = false  -- reset
local install_result_property
local original_UpdateUpdateStatusProperty = UpdateUpdateStatusProperty
UpdateUpdateStatusProperty = function(text) install_result_property = text end

InstallLatestReleaseNow()
Test.assertEqual(install_result_property, "Checking GitHub for the latest release...", "initial status set")

-- Find the urlGet from the updater (it queries /releases path)
local releases_ticket
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then releases_ticket = i; break end
end
Test.assert(releases_ticket, "updater fired GET against /releases")

-- Deliver a response with only the current version as latest
ReceivedAsync(releases_ticket, JsonEncode({
    { tag_name = DRIVER_VERSION, draft = false, prerelease = false, assets = {} }
}), 200, {}, nil)

Test.assert(install_result_property:find("No install applied"), "up-to-date resolves to 'No install applied' message")
Test.assert(install_result_property:find(DRIVER_VERSION), "message includes current version")
Test.assertEqual(gUpdateInProgress, false, "gUpdateInProgress cleared after success")

--------------------------------------------------------------------------------
-- 5. Install Latest Release second-trigger guard
--------------------------------------------------------------------------------
gUpdateInProgress = true
install_result_property = "(unchanged)"
InstallLatestReleaseNow()
Test.assertEqual(install_result_property, "Install already running", "second trigger ignored with explanation")
gUpdateInProgress = false

UpdateUpdateStatusProperty = original_UpdateUpdateStatusProperty

--------------------------------------------------------------------------------
-- 6. http_client watchdog regression guard. After T2d+ replaced the slim
--    updater with vendor/http.lua, the 60s ticket-watchdog was lost; the
--    review-cleanup PR restored it. Verify a SetTimer fires for each
--    outstanding ticket so a stuck request can self-recover.
--------------------------------------------------------------------------------
local _timers = {}
local original_SetTimer = C4.SetTimer
function C4:SetTimer(delay_ms, fn, repeating)
    table.insert(_timers, { delay_ms = delay_ms, fn = fn })
    return #_timers
end

local watchdog_test_resolved
local d_wd = http_client:get("https://example.com/will-time-out")
d_wd:next(
    function(r) watchdog_test_resolved = { ok = true, body = r.body } end,
    function(e) watchdog_test_resolved = { ok = false, error = e.error or "(no err)" } end
)
Test.assert(#_timers >= 1, "watchdog SetTimer scheduled for outstanding ticket")
Test.assertEqual(_timers[#_timers].delay_ms, 60000, "watchdog scheduled for 60s")

-- Fire the watchdog without first delivering a real response. This simulates
-- C4:urlGet handing out a ticket but ReceivedAsync never arriving.
_timers[#_timers].fn()
Test.assertEqual(watchdog_test_resolved.ok, false, "watchdog rejects the deferred")
Test.assert(watchdog_test_resolved.error:find("watchdog"), "watchdog err mentions watchdog")

C4.SetTimer = original_SetTimer

--------------------------------------------------------------------------------
-- 7. The empty-resolve path now surfaces a useful message rather than
--    the misleading "Already up to date". P0 fix from the review-cleanup PR.
--------------------------------------------------------------------------------
gUpdateInProgress = false
install_result_property = nil
UpdateUpdateStatusProperty = function(text) install_result_property = text end

-- Fake updateAll that resolves with an empty list (simulating any of: same
-- version, no matching asset, no installed driver).
local original_updateAll = github_updater.updateAll
github_updater.updateAll = function(self) return deferred.new():resolve({}) end
InstallLatestReleaseNow()
Test.assert(
    install_result_property:find("No install applied"),
    "empty-resolve produces 'No install applied' not 'Already up to date'"
)
Test.assert(
    install_result_property:find(DRIVER_VERSION),
    "empty-resolve message includes the current driver version"
)
Test.assert(
    install_result_property:find("proflame_wifi_connect.c4z"),
    "empty-resolve message names the expected asset filename"
)
github_updater.updateAll = original_updateAll
UpdateUpdateStatusProperty = original_UpdateUpdateStatusProperty

--------------------------------------------------------------------------------
-- 8. Check for Update (report-only): newer release tag -> "Update available".
--    Drives the real getLatestRelease deferred via a faked /releases response,
--    so it exercises the version-compare path end to end without installing.
--------------------------------------------------------------------------------
local check_status
UpdateUpdateStatusProperty = function(text) check_status = text end

-- Compose a release tag strictly newer than the running DRIVER_VERSION by
-- bumping the trailing 2-digit sequence (the version scheme is YYYYMMDDss).
local newer_tag = "v" .. tostring(tonumber(DRIVER_VERSION) + 1)

CheckForUpdateNow()
Test.assertEqual(check_status, "Checking GitHub for the latest release...", "check sets initial status")
local check_ticket
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then check_ticket = i end  -- last /releases GET
end
Test.assert(check_ticket, "Check for Update fired GET against /releases")
ReceivedAsync(check_ticket, JsonEncode({
    { tag_name = newer_tag, draft = false, prerelease = false, assets = {} }
}), 200, {}, nil)
Test.assert(check_status:find("Update available"), "newer release -> 'Update available'")
Test.assert(check_status:find(newer_tag, 1, true), "message names the newer tag")
Test.assert(check_status:find(DRIVER_VERSION, 1, true), "message names the current version")

--------------------------------------------------------------------------------
-- 9. Check for Update: latest tag == current -> "Up to date" (no install).
--------------------------------------------------------------------------------
check_status = nil
CheckForUpdateNow()
local check_ticket2
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then check_ticket2 = i end
end
ReceivedAsync(check_ticket2, JsonEncode({
    { tag_name = "v" .. DRIVER_VERSION, draft = false, prerelease = false, assets = {} }
}), 200, {}, nil)
Test.assert(check_status:find("Up to date"), "equal tag -> 'Up to date'")
Test.assert(check_status:find(DRIVER_VERSION, 1, true), "up-to-date message names the version")

--------------------------------------------------------------------------------
-- 10. Check for Update failure surfaces a check-specific message (and never
--     claims an install happened).
--------------------------------------------------------------------------------
check_status = nil
CheckForUpdateNow()
local check_ticket3
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then check_ticket3 = i end
end
ReceivedAsync(check_ticket3, "boom", 500, {}, nil)
Test.assert(check_status:find("Update check failed"), "5xx -> 'Update check failed'")
Test.assert(not check_status:find("Installed"), "failed check never reports an install")

UpdateUpdateStatusProperty = original_UpdateUpdateStatusProperty

--------------------------------------------------------------------------------
-- 11. Force Reinstall passes forceUpdate=true to updateAll.
--------------------------------------------------------------------------------
gUpdateInProgress = false
local forced_args
local orig_updateAll2 = github_updater.updateAll
github_updater.updateAll = function(self, repo, files, pre, force)
    forced_args = { repo = repo, pre = pre, force = force }
    return deferred.new():resolve({ "proflame_wifi_connect.c4z" })
end
local force_status
local orig_status_fn = UpdateUpdateStatusProperty
UpdateUpdateStatusProperty = function(text) force_status = text end

ForceReinstallLatestRelease()
Test.assertEqual(forced_args.force, true, "Force Reinstall passes forceUpdate=true")
Test.assertEqual(forced_args.repo, GITHUB_UPDATER_REPO, "force install targets the configured repo")
Test.assert(force_status:find("Installed"), "force install resolves to an Installed message")

github_updater.updateAll = orig_updateAll2
UpdateUpdateStatusProperty = orig_status_fn

--------------------------------------------------------------------------------
-- 12. Periodic update-check timer: interval>0 schedules a repeating timer at
--     hours*3600s; 0 disables; Stop cancels.
--------------------------------------------------------------------------------
local _utimers
local orig_SetTimer2 = C4.SetTimer
function C4:SetTimer(delay_ms, fn, repeating)
    local handle = { delay_ms = delay_ms, fn = fn, repeating = repeating, cancelled = false }
    handle.Cancel = function(self) self.cancelled = true end
    table.insert(_utimers, handle)
    return handle
end

_utimers = {}
gUpdateCheckTimerId = nil
Properties["Update Check Interval (hours)"] = "24"
StartUpdateCheckTimer()
Test.assertEqual(#_utimers, 1, "interval=24 schedules one timer")
Test.assertEqual(_utimers[1].delay_ms, 24 * 60 * 60 * 1000, "interval is 24h in ms")
Test.assertEqual(_utimers[1].repeating, true, "update-check timer repeats")

-- 0 disables and stops any existing timer.
_utimers = {}
local prev = gUpdateCheckTimerId
Properties["Update Check Interval (hours)"] = "0"
StartUpdateCheckTimer()
Test.assertEqual(#_utimers, 0, "interval=0 schedules no timer")
Test.assert(prev.cancelled, "switching to 0 cancels the previous timer")
Test.assertEqual(gUpdateCheckTimerId, nil, "handle cleared when disabled")

-- StopUpdateCheckTimer is idempotent on nil.
StopUpdateCheckTimer()
Test.assertEqual(gUpdateCheckTimerId, nil, "Stop idempotent on nil")

C4.SetTimer = orig_SetTimer2

--------------------------------------------------------------------------------
-- 13. ExecuteCommand dispatch wiring for the three update commands. Guards the
--     elseif/return-true control flow (each must invoke its function AND return
--     true, not fall through to the "Unhandled ExecuteCommand" error path).
--------------------------------------------------------------------------------
local dispatched
local orig_install = InstallLatestReleaseNow
local orig_check = CheckForUpdateNow
local orig_force = ForceReinstallLatestRelease
InstallLatestReleaseNow = function() dispatched = "install" end
CheckForUpdateNow = function() dispatched = "check" end
ForceReinstallLatestRelease = function() dispatched = "force" end

dispatched = nil
Test.assertEqual(ExecuteCommand("Install Latest Release", {}), true, "Install Latest Release returns true")
Test.assertEqual(dispatched, "install", "Install Latest Release dispatched")

dispatched = nil
Test.assertEqual(ExecuteCommand("Check for Update", {}), true, "Check for Update returns true")
Test.assertEqual(dispatched, "check", "Check for Update dispatched")

dispatched = nil
Test.assertEqual(ExecuteCommand("Force Reinstall Latest Release", {}), true, "Force Reinstall returns true")
Test.assertEqual(dispatched, "force", "Force Reinstall dispatched")

-- Actions-tab BUTTON clicks: Control4 sends strCommand="LUA_ACTION" with the
-- action's <name> in tParams.ACTION (NOT the command name). These must dispatch
-- to the same handlers and return true (regression guard for the "Unhandled
-- ExecuteCommand: LUA_ACTION" bug). The ACTION strings must match driver.xml's
-- <action><name> values.
dispatched = nil
Test.assertEqual(ExecuteCommand("LUA_ACTION", { ACTION = "Check for Update" }), true,
    "LUA_ACTION 'Check for Update' returns true")
Test.assertEqual(dispatched, "check", "LUA_ACTION 'Check for Update' dispatched")

dispatched = nil
Test.assertEqual(ExecuteCommand("LUA_ACTION", { ACTION = "Install Latest Release" }), true,
    "LUA_ACTION 'Install Latest Release' returns true")
Test.assertEqual(dispatched, "install", "LUA_ACTION 'Install Latest Release' dispatched")

dispatched = nil
Test.assertEqual(ExecuteCommand("LUA_ACTION", { ACTION = "Force Reinstall Latest Release (Recovery)" }), true,
    "LUA_ACTION 'Force Reinstall (Recovery)' returns true")
Test.assertEqual(dispatched, "force", "LUA_ACTION 'Force Reinstall (Recovery)' dispatched")

-- An unrecognized action must NOT crash and must return false (the diagnostic
-- branch dumps tParams).
dispatched = nil
Test.assertEqual(ExecuteCommand("LUA_ACTION", { ACTION = "No Such Action" }), false,
    "unrecognized LUA_ACTION returns false")
Test.assertEqual(dispatched, nil, "unrecognized LUA_ACTION dispatches nothing")

-- Missing tParams/ACTION must be handled gracefully (no crash, returns false).
Test.assertEqual(ExecuteCommand("LUA_ACTION", nil), false, "LUA_ACTION with nil tParams returns false")

InstallLatestReleaseNow = orig_install
CheckForUpdateNow = orig_check
ForceReinstallLatestRelease = orig_force

--------------------------------------------------------------------------------
-- 14. getLatestRelease picks the HIGHEST-versioned release, not the first array
--     entry (Codex HIGH). Deliver releases out of creation order and assert the
--     newest tag wins, surfaced through CheckForUpdateNow.
--------------------------------------------------------------------------------
local maxver_status
UpdateUpdateStatusProperty = function(text) maxver_status = text end
local base = tonumber(DRIVER_VERSION)
local older_tag  = "v" .. tostring(base - 1)
local newest_tag = "v" .. tostring(base + 5)
local middle_tag = "v" .. tostring(base + 2)

CheckForUpdateNow()
local mv_ticket
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then mv_ticket = i end
end
-- Newest is deliberately NOT first in the array.
ReceivedAsync(mv_ticket, JsonEncode({
    { tag_name = older_tag,  draft = false, prerelease = false, assets = {} },
    { tag_name = newest_tag, draft = false, prerelease = false, assets = {} },
    { tag_name = middle_tag, draft = false, prerelease = false, assets = {} },
}), 200, {}, nil)
Test.assert(maxver_status:find("Update available"), "out-of-order array still finds an update")
Test.assert(maxver_status:find(newest_tag, 1, true),
    "highest-versioned tag (" .. newest_tag .. ") selected, not array-first")
Test.assert(not maxver_status:find(older_tag, 1, true), "did not report the older first-in-array tag")

-- A draft/prerelease newest must be ignored in favor of the highest stable.
maxver_status = nil
CheckForUpdateNow()
local mv_ticket2
for i, g in ipairs(_urlgets) do
    if g.url:find("/releases$") then mv_ticket2 = i end
end
ReceivedAsync(mv_ticket2, JsonEncode({
    { tag_name = "v" .. tostring(base + 9), draft = true,  prerelease = false, assets = {} },
    { tag_name = "v" .. tostring(base + 8), draft = false, prerelease = true,  assets = {} },
    { tag_name = newest_tag,                draft = false, prerelease = false, assets = {} },
}), 200, {}, nil)
Test.assert(maxver_status:find(newest_tag, 1, true),
    "draft/prerelease higher tags ignored; highest STABLE selected")

UpdateUpdateStatusProperty = original_UpdateUpdateStatusProperty

--------------------------------------------------------------------------------
-- 15. CheckForUpdateNow is a no-op while an install is in progress (Codex
--     MEDIUM): it must not fire a request or overwrite the install's status.
--------------------------------------------------------------------------------
local guard_status = "(install message)"
UpdateUpdateStatusProperty = function(text) guard_status = text end
local urlgets_before = #_urlgets
gUpdateInProgress = true
CheckForUpdateNow()
Test.assertEqual(#_urlgets, urlgets_before, "in-progress check fires no GitHub request")
Test.assertEqual(guard_status, "(install message)", "in-progress check does not overwrite Update Status")
gUpdateInProgress = false
UpdateUpdateStatusProperty = original_UpdateUpdateStatusProperty

--------------------------------------------------------------------------------
-- 16. http_client follows 3xx redirects (C4:urlGet does not). GitHub release
--     asset URLs 302-redirect to storage; without following, the download fails
--     with "status 302" and the install reports "unknown error".
--------------------------------------------------------------------------------
local rdir = http_client:get("https://example.com/releases/download/asset.c4z")
local t1 = #_urlgets
Test.assertEqual(_urlgets[t1].url, "https://example.com/releases/download/asset.c4z", "initial request fired")
-- Deliver a 302 with a Location header; the client must auto-issue a 2nd GET.
ReceivedAsync(t1, "", 302, { Location = "https://storage.example.com/real-asset.c4z" }, nil)
local t2 = #_urlgets
Test.assertEqual(t2, t1 + 1, "302 triggered a follow-up request")
Test.assertEqual(_urlgets[t2].url, "https://storage.example.com/real-asset.c4z", "followed the Location URL")
local rdir_result
rdir:next(function(r) rdir_result = r end, function(e) rdir_result = { error = e and e.error } end)
ReceivedAsync(t2, "REAL_ASSET_BYTES", 200, {}, nil)
Test.assert(rdir_result ~= nil, "redirect chain settled")
Test.assertEqual(rdir_result.body, "REAL_ASSET_BYTES", "resolved with the final (post-redirect) body")

-- Lower-case header key must also be honored.
local rdir2 = http_client:get("https://example.com/a")
local u1 = #_urlgets
ReceivedAsync(u1, "", 301, { location = "https://example.com/b" }, nil)
Test.assertEqual(_urlgets[#_urlgets].url, "https://example.com/b", "case-insensitive Location header followed")
local rdir2_result
rdir2:next(function(r) rdir2_result = r end, function(e) rdir2_result = { error = e and e.error } end)
ReceivedAsync(#_urlgets, "B", 200, {}, nil)
Test.assertEqual(rdir2_result.body, "B", "lowercase-location redirect resolved")

-- A 3xx with no Location header must reject with a clear reason (not hang).
local rdir3 = http_client:get("https://example.com/noloc")
local n1 = #_urlgets
local rdir3_result
rdir3:next(function(r) rdir3_result = { body = r.body } end, function(e) rdir3_result = { error = e.error } end)
ReceivedAsync(n1, "", 302, {}, nil)
Test.assert(rdir3_result and rdir3_result.error, "3xx without Location rejects")
Test.assert(rdir3_result.error:find("no Location header"), "reason names the missing Location header")

--------------------------------------------------------------------------------
-- 17. DescribeUpdaterError flattens every rejection shape so the real cause is
--     never lost as "unknown error" (the deferred.all numeric-table case was
--     what produced the user's "InstallLatestReleaseNow: failed - unknown error").
--------------------------------------------------------------------------------
Test.assertEqual(DescribeUpdaterError("boom"), "boom", "string passes through")
Test.assertEqual(DescribeUpdaterError({ error = "oops" }), "oops", "{error=...} table unwrapped")
Test.assertEqual(
    DescribeUpdaterError({ [1] = "HTTP GET x status 302" }),
    "HTTP GET x status 302",
    "numeric-indexed (deferred.all) table flattened")
local joined = DescribeUpdaterError({ [1] = { error = "a" }, [2] = { error = "b" } })
Test.assert(joined:find("a", 1, true) and joined:find("b", 1, true),
    "numeric table of {error=...} entries joined")
Test.assert(DescribeUpdaterError(nil):find("unknown error", 1, true),
    "nil falls back to a non-crashing 'unknown error'")

print("test_github_updater OK")
