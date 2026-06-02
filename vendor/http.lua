-- Slim HTTP client wrapping C4:urlGet/urlPost/urlPut/urlDelete with deferred
-- promises. Replaces the template's lib/http.lua (which depends on the much
-- larger drivers-common-public/global/url.lua) for the narrow set of calls
-- github-updater.lua makes.
--
-- Async wiring: C4:urlGet(url, headers, encrypted, callback, flags) returns a
-- ticket; the global ReceivedAsync(ticket, body, code, headers, err) handler
-- delivers the response. We register a per-ticket callback in a module-local
-- table so concurrent in-flight requests dispatch correctly. The top-level
-- ReceivedAsync dispatcher in src/driver.lua calls our
-- handleAsyncResponse(ticket, ...) for each incoming response.
--
-- Returned via the bundler as the global `http_client`.

local Http = {}
Http.__index = Http

local _pending = {}

function Http:new()
    return setmetatable({}, self)
end

--- Dispatch table entry for an async response. Returns true if the ticket
--- belongs to us and was handled; false otherwise (so the dispatcher can try
--- other consumers).
function Http.handleAsyncResponse(ticket, body, responseCode, headers, err)
    local entry = _pending[ticket]
    if not entry then return false end
    _pending[ticket] = nil
    local ok, callErr = pcall(entry.cb, body, responseCode, headers, err)
    if not ok and dbg_err then
        dbg_err("http_client callback error: " .. tostring(callErr))
    end
    return true
end

local function build_result(url, code, body, headers)
    return { url = url, code = code, body = body, headers = headers or {} }
end

function Http:request(method, url, data, headers, options)
    local d = deferred.new()
    headers = headers or {}
    options = options or {}

    if not C4 or type(C4.urlGet) ~= "function" then
        d:reject({ error = "C4 url* APIs not available", url = url })
        return d
    end

    local cb = function(body, responseCode, respHeaders, err)
        local code = tonumber(responseCode) or 0
        -- Match the template's behavior: when the body parses as JSON,
        -- surface the decoded value rather than the raw string. Callers
        -- (e.g. github-updater) iterate response.body with pairs() and
        -- expect a table for JSON endpoints.
        local decoded_body = body
        if type(body) == "string" and body ~= "" then
            local ok, parsed = pcall(JSON.decode, JSON, body)
            if ok and type(parsed) == "table" then
                decoded_body = parsed
            end
        end
        local result = build_result(url, code, decoded_body, respHeaders)
        if err and err ~= "" then
            result.error = string.format("HTTP %s %s failed: %s", method, url, tostring(err))
            d:reject(result)
        elseif code < 200 or code >= 300 then
            result.error = string.format("HTTP %s %s status %d", method, url, code)
            d:reject(result)
        else
            d:resolve(result)
        end
    end

    local ok, ticket = pcall(function()
        if method == "GET" then
            return C4:urlGet(url, headers, false, ReceivedAsync, {})
        elseif method == "POST" then
            return C4:urlPost(url, data or "", headers, false, ReceivedAsync, {})
        elseif method == "PUT" then
            return C4:urlPut(url, data or "", headers, false, ReceivedAsync, {})
        elseif method == "DELETE" then
            return C4:urlDelete(url, headers, false, ReceivedAsync, {})
        else
            error("unsupported HTTP method: " .. tostring(method))
        end
    end)

    if not ok or ticket == nil then
        d:reject({ error = "url request failed: " .. tostring(ticket), url = url })
        return d
    end

    _pending[ticket] = { cb = cb }
    return d
end

function Http:get(url, headers, options)
    return self:request("GET", url, nil, headers, options)
end

function Http:post(url, data, headers, options)
    return self:request("POST", url, data, headers, options)
end

function Http:put(url, data, headers, options)
    return self:request("PUT", url, data, headers, options)
end

function Http:delete(url, headers, options)
    return self:request("DELETE", url, headers, options)
end

return Http:new()
