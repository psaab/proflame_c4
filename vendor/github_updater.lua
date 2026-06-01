-- GitHub Releases polling client for the Proflame driver.
--
-- Fires an async HTTP GET against the GitHub Releases API for the configured
-- repo, parses the `tag_name` of the latest release, and invokes a callback
-- with the parse result. Designed for log-only notification, NOT auto-install:
-- the callback receives the new version string and the driver decides what
-- to do with it (currently: dbg_err it).
--
-- Async wiring: C4:urlGet returns a "ticket" identifier; the response arrives
-- via the global `ReceivedAsync(ticket, body, responseCode, headers, err)`
-- handler. We register the per-ticket callback in a module-local table so
-- multiple in-flight requests don't collide.
--
-- Returned via the bundler as the global `github_updater`.

local Updater = {}
Updater.__index = Updater

-- ticket -> callback. Module-local so multiple updaters share dispatch.
local _pending = {}

function Updater:new(repo)
    return setmetatable({ repo = repo or "" }, self)
end

--- Dispatch table entry for an async fetch result. Returns true if the
--- ticket was ours and was handled; false if it belongs to someone else.
function Updater.handleAsyncResponse(ticket, body, responseCode, headers, err)
    local entry = _pending[ticket]
    if not entry then return false end
    _pending[ticket] = nil
    if entry.watchdog and C4 and C4.KillTimer and entry.watchdog ~= nil then
        pcall(C4.KillTimer, C4, entry.watchdog)
    end
    local ok, callErr = pcall(entry.cb, body, responseCode, err)
    if not ok then
        if dbg_err then dbg_err("github_updater callback error: " .. tostring(callErr)) end
    end
    return true
end

--- Number of seconds to wait for a response before garbage-collecting a
--- ticket whose callback never fired. Bounds memory growth across many
--- driver restarts where C4:urlGet hands out a ticket but the network
--- request never completes.
local TICKET_WATCHDOG_SEC = 60

--- Fetch the latest release tag from GitHub and invoke `callback` with one of:
---   { available = true,  current = "X", latest = "Y" }   -- newer version found
---   { available = false, current = "X", latest = "Y" }   -- already up-to-date
---   { available = false, err = "..." }                    -- fetch/parse failure
function Updater:check(callback)
    if type(callback) ~= "function" then return end
    if self.repo == "" then
        callback({ available = false, err = "no repo configured" })
        return
    end
    if not C4 or type(C4.urlGet) ~= "function" then
        callback({ available = false, err = "C4:urlGet not available" })
        return
    end

    local url = "https://api.github.com/repos/" .. self.repo .. "/releases/latest"
    local headers = {
        Accept = "application/vnd.github.v3+json",
        ["User-Agent"] = "proflame_c4",
    }

    local current = DRIVER_VERSION or ""

    local ok, ticket = pcall(function()
        return C4:urlGet(url, headers)
    end)
    if not ok or ticket == nil then
        callback({ available = false, err = "urlGet failed: " .. tostring(ticket) })
        return
    end

    local cb = function(body, responseCode, err)
        if err and err ~= "" then
            callback({ available = false, err = "http error: " .. tostring(err) })
            return
        end
        if responseCode and tonumber(responseCode) and tonumber(responseCode) >= 400 then
            local snippet = (body and tostring(body):sub(1, 200)) or ""
            callback({ available = false, err = "http " .. tostring(responseCode) .. ": " .. snippet })
            return
        end
        if not body or body == "" then
            callback({ available = false, err = "empty response (code=" .. tostring(responseCode) .. ")" })
            return
        end
        local decodeOk, data = pcall(JSON.decode, JSON, body)
        if not decodeOk or type(data) ~= "table" or type(data.tag_name) ~= "string" then
            callback({ available = false, err = "invalid JSON response" })
            return
        end
        -- Tag scheme: v2026053101 -> 2026053101. Strip optional leading 'v'.
        local latest = data.tag_name:gsub("^v", "")
        -- DRIVER_VERSION is a date-stamp like "2026060103"; lexicographic
        -- ordering matches chronological ordering for fixed-width date stamps,
        -- so string comparison is correct here.
        local available = latest > current
        callback({ available = available, current = current, latest = latest })
    end

    -- Schedule a watchdog so a ticket that never receives a ReceivedAsync
    -- response gets cleared from _pending after TICKET_WATCHDOG_SEC. Uses
    -- C4:SetTimer if available; falls back to no-cleanup (memory leak is
    -- bounded by driver-load cadence, which is infrequent).
    local watchdog
    if C4 and type(C4.SetTimer) == "function" then
        local ok, t = pcall(C4.SetTimer, C4, TICKET_WATCHDOG_SEC * 1000, function()
            local stale = _pending[ticket]
            if stale then
                _pending[ticket] = nil
                pcall(stale.cb, nil, 0, "watchdog: no response after " .. TICKET_WATCHDOG_SEC .. "s")
            end
        end, false)
        if ok then watchdog = t end
    end

    _pending[ticket] = { cb = cb, watchdog = watchdog }
end

return Updater:new("psaab/proflame_c4")
