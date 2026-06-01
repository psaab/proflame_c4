-- Slim persistence wrapper for the Proflame Control4 driver.
--
-- Wraps C4:PersistSetValue / C4:PersistGetValue / C4:PersistDeleteValue with
-- JSON serialization so callers can store and retrieve arbitrary
-- JSON-encodable values (strings, numbers, booleans, flat tables) under a
-- key namespace.
--
-- This is intentionally narrower than the upstream lib/persist.lua from
-- the control4-driver-template: no migration system, no read-through
-- cache, no TableDeepCopy semantics. The trade-off is that callers must
-- treat values returned by :get() as immutable snapshots and call :set()
-- explicitly to update.
--
-- Encrypted storage is NOT supported here. The template's :get(key, default,
-- encrypted) and :set(key, value, encrypted) signatures take a third boolean
-- argument that selects C4's encrypted persist store. This module always
-- stores values unencrypted (`false` is passed to C4:PersistGet/SetValue).
-- Don't call :get or :set with a third argument expecting encryption — it
-- will be silently ignored. Add encryption support before storing anything
-- sensitive (tokens, credentials, etc.).
--
-- Returned via the bundler as the global `persist`.

local Persist = {}
Persist.__index = Persist

function Persist:new()
    return setmetatable({}, self)
end

--- Retrieve a value, returning `default` if the key is missing or corrupt.
--- @param key string Persistence key.
--- @param default any Value returned when no record exists.
--- @return any
function Persist:get(key, default)
    if type(key) ~= "string" or key == "" then return default end
    local raw
    if C4 and C4.PersistGetValue then
        raw = C4:PersistGetValue(key, false)
    end
    if raw == nil or raw == "" then return default end
    local ok, decoded = pcall(JSON.decode, JSON, raw)
    if not ok or decoded == nil then return default end
    return decoded
end

--- Store a JSON-encodable value at `key`. Passing nil deletes the record.
--- @param key string Persistence key.
--- @param value any JSON-encodable value, or nil to delete.
function Persist:set(key, value)
    if type(key) ~= "string" or key == "" then return end
    if value == nil then
        self:delete(key)
        return
    end
    local ok, encoded = pcall(JSON.encode, JSON, value)
    if not ok or type(encoded) ~= "string" then return end
    if C4 and C4.PersistSetValue then
        C4:PersistSetValue(key, encoded, false)
    end
end

--- Remove a key from the persistence store.
--- @param key string Persistence key.
function Persist:delete(key)
    if type(key) ~= "string" or key == "" then return end
    if C4 and C4.PersistDeleteValue then
        C4:PersistDeleteValue(key)
    elseif C4 and C4.PersistSetValue then
        C4:PersistSetValue(key, "", false)
    end
end

return Persist:new()
