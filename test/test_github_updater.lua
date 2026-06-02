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

Test.assertEqual(install_result_property, "Already up to date (" .. DRIVER_VERSION .. ")", "up-to-date status surfaced")
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

print("test_github_updater OK")
