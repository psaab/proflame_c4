-- vendor/github_updater.lua + ReceivedAsync dispatcher + CheckForUpdatesIfDue
-- rate-limit logic. Stubs C4:urlGet to deliver a synchronous fake response.

require("c4_shim")

-- Fake C4:urlGet: returns a fixed ticket and stashes the headers for inspection.
local _next_ticket = 1
local _last_url, _last_headers
function C4:urlGet(url, headers)
    _last_url = url
    _last_headers = headers
    local ticket = _next_ticket
    _next_ticket = _next_ticket + 1
    return ticket
end

dofile("driver.lua")

--------------------------------------------------------------------------------
-- 1. github_updater:check happy path -> "available" callback on newer tag
--------------------------------------------------------------------------------
local result
github_updater:check(function(r) result = r end)
Test.assert(_last_url:find("psaab/proflame_c4/releases/latest"), "url targets the repo")
Test.assertEqual(_last_headers["User-Agent"], "proflame_c4", "User-Agent header set")

-- Simulate response delivered async via ReceivedAsync
local body = JsonEncode({ tag_name = "v9999999999" })
ReceivedAsync(1, body, 200, {}, nil)
Test.assertEqual(result.available, true, "newer version detected as available")
Test.assertEqual(result.latest, "9999999999", "'v' prefix stripped from tag")
Test.assertEqual(result.current, DRIVER_VERSION, "current matches DRIVER_VERSION")

--------------------------------------------------------------------------------
-- 2. Same-version response -> available=false
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(2, JsonEncode({ tag_name = DRIVER_VERSION }), 200, {}, nil)
Test.assertEqual(result.available, false, "same version -> not available")

--------------------------------------------------------------------------------
-- 3. Older-version response -> available=false (downgrade tag should not alert)
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(3, JsonEncode({ tag_name = "v0000000000" }), 200, {}, nil)
Test.assertEqual(result.available, false, "older version -> not available")

--------------------------------------------------------------------------------
-- 4. Invalid JSON response -> err
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(4, "not valid json {{{", 200, {}, nil)
Test.assertEqual(result.available, false, "bad JSON -> not available")
Test.assert(result.err, "bad JSON -> err set")

--------------------------------------------------------------------------------
-- 5. Empty body -> err
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(5, "", 500, {}, nil)
Test.assertEqual(result.available, false, "empty body -> not available")
Test.assert(result.err, "empty body -> err set")

--------------------------------------------------------------------------------
-- 6. HTTP error string -> err
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(6, nil, 0, nil, "timeout")
Test.assertEqual(result.available, false, "http error -> not available")
Test.assert(result.err:find("timeout"), "err includes underlying message")

--------------------------------------------------------------------------------
-- 7. ReceivedAsync for an unregistered ticket is a no-op (not a crash)
--------------------------------------------------------------------------------
ReceivedAsync(9999, "stray response", 200, {}, nil)  -- no callback registered

--------------------------------------------------------------------------------
-- 7b. 4xx/5xx response with valid JSON body produces an http-code err, not a
--     misleading "invalid JSON" message.
--------------------------------------------------------------------------------
result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(7, JsonEncode({ message = "Not Found" }), 404, {}, nil)
Test.assertEqual(result.available, false, "4xx -> not available")
Test.assert(result.err:find("http 404"), "err mentions http 404")

result = nil
github_updater:check(function(r) result = r end)
ReceivedAsync(8, "server crashed", 500, {}, nil)
Test.assert(result.err:find("http 500"), "err mentions http 500 (5xx)")

--------------------------------------------------------------------------------
-- 8. CheckForUpdatesIfDue rate-limit: second call within 24h is a no-op
--------------------------------------------------------------------------------
Test.resetPersist()
local check_calls = 0
local original_check = github_updater.check
github_updater.check = function(self, cb) check_calls = check_calls + 1; cb({ available = false, current = "x", latest = "x" }) end

CheckForUpdatesIfDue()
Test.assertEqual(check_calls, 1, "first call invokes the updater")

CheckForUpdatesIfDue()
Test.assertEqual(check_calls, 1, "second call within 24h is rate-limited")

-- Advance the persisted timestamp far enough into the past
local store = Test.getPersistStore()
store[PERSIST_KEY_LAST_UPDATE_CHECK] = JsonEncode(os.time() - (UPDATE_CHECK_INTERVAL_SEC + 1))
CheckForUpdatesIfDue()
Test.assertEqual(check_calls, 2, "call after interval expires invokes again")

github_updater.check = original_check

print("test_github_updater OK")
