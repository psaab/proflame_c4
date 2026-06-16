-- Helper functions extracted from the control4-driver-template's
-- src/lib/utils.lua and vendor/drivers-common-public/global/lib.lua. Only the
-- helpers actually referenced by github-updater.lua + http.lua + version.lua
-- (transitively) live here, hand-trimmed to avoid pulling in the full
-- ~1,500-line drivers-common-public/global/lib.lua plus its url/handlers
-- cascade.
--
-- Sources (template paths, copied/adapted verbatim where possible):
--   - utils.lua: IsEmpty, Select (utils.lua uses lib.lua's), TableReverse,
--                TableKeys, InRange, toboolean, reject, resolve
--   - lib.lua:   Select, XMLEncode, XMLTag (simplified), FileRead, FileWrite
--
-- Returned via the bundler as a sentinel table (`lib_helpers`); the file
-- assigns its functions as Lua GLOBALS so callers (github-updater.lua, etc.)
-- can reference them without aliasing.

--------------------------------------------------------------------------------
-- Selection / nil-safety
--------------------------------------------------------------------------------

function Select(data, ...)
    if type(data) ~= "table" then return nil end
    local args = { ... }
    local n = select("#", ...)
    local ret = data
    local i = 1
    while ret ~= nil and i <= n do
        if args[i] == nil then return nil end
        ret = ret[args[i]]
        i = i + 1
    end
    return ret
end

function IsEmpty(value)
    if value == nil then return true end
    local t = type(value)
    if t == "string" then return value == "" end
    if t == "table" then return next(value) == nil end
    if t == "number" then return value == 0 end
    if t == "boolean" then return not value end
    return false
end

--------------------------------------------------------------------------------
-- Table helpers
--------------------------------------------------------------------------------

function TableKeys(t)
    if type(t) ~= "table" then return {} end
    local keys = {}
    for k, _ in pairs(t) do table.insert(keys, k) end
    return keys
end

function TableReverse(t)
    local r = {}
    for k, v in pairs(t) do r[v] = k end
    return r
end

--------------------------------------------------------------------------------
-- Coercions
--------------------------------------------------------------------------------

function toboolean(val)
    if type(val) == "string" then
        local lv = string.lower(val)
        return lv == "true" or lv == "yes" or val == "1" or lv == "on"
    elseif type(val) == "number" then
        return val ~= 0
    elseif type(val) == "boolean" then
        return val
    end
    return false
end

function InRange(n, min, max)
    if n == nil then return nil end
    if min ~= nil then n = math.max(min, n) end
    if max ~= nil then n = math.min(max, n) end
    return n
end

--------------------------------------------------------------------------------
-- Deferred convenience constructors. Require the `deferred` global to be in
-- scope already (bundle.sh splices vendor/deferred.lua before lib_helpers).
--------------------------------------------------------------------------------

function reject(err)
    return deferred.new():reject(err)
end

function resolve(value)
    return deferred.new():resolve(value)
end

--------------------------------------------------------------------------------
-- File ops (wraps the C4 file API the github-updater uses for writing the
-- downloaded .c4z payload). Lifted from drivers-common-public/global/lib.lua.
--------------------------------------------------------------------------------

function FileRead(filename)
    local content = ""
    if C4:FileExists(filename) then
        local file = C4:FileOpen(filename)
        local length = C4:FileGetSize(file)
        C4:FileSetPos(file, 0)
        content = C4:FileRead(file, length)
        C4:FileClose(file)
    end
    return content
end

-- NOTE: this lib_helpers FileWrite is SHADOWED at runtime by the
-- drivers-common-public global/lib.lua FileWrite (bundled later), which
-- discards C4:FileWrite's result and returns nothing. So the updater must not
-- trust FileWrite's return value to detect a failed write — github_updater.lua
-- verifies the write landed by re-reading instead (#87 / Codex review).
function FileWrite(filename, content, overwrite)
    content = tostring(content) or ""
    local pos = 0
    if overwrite and C4:FileExists(filename) then
        C4:FileDelete(filename)
    end
    local file = C4:FileOpen(filename)
    if not overwrite then
        pos = C4:FileGetSize(file)
    end
    C4:FileSetPos(file, pos)
    C4:FileWrite(file, content:len(), content)
    C4:FileClose(file)
end

--------------------------------------------------------------------------------
-- Driver-version lookup. The template's GetDriverVersion(filename) parses the
-- target driver's XML via xml2lua. We have a single driver and the value is
-- already in DRIVER_VERSION, so this short-circuits to that.
--------------------------------------------------------------------------------

function GetDriverVersion(filename)
    return DRIVER_VERSION
end

--------------------------------------------------------------------------------
-- XML helpers — just enough to build the c4soap UpdateProjectC4i SOAP packet
-- the updater sends to Composer (127.0.0.1:5020).
--------------------------------------------------------------------------------

function XMLEncode(value)
    if value == nil then return "" end
    value = tostring(value)
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub('"', "&quot;")
    value = value:gsub("'", "&apos;")
    return value
end

-- Trimmed XMLTag: handles the github-updater's exact call shape. Supports
-- string content + attribute table. Falls back to template behavior for the
-- nested call.
--
-- Call shapes the updater uses:
--   XMLTag("param", "filename.c4i", nil, nil, { name = "name", type = "string" })
--     -> <param name="name" type="string">filename.c4i</param>
--   XMLTag("c4soap", "<param.../>", false, false, { name="UpdateProjectC4i", ... })
--     -> <c4soap name="UpdateProjectC4i" ...><param.../></c4soap>
function XMLTag(strName, content, tagSubTables, xmlEncodeElements, tAttribs)
    local parts = { "<", strName }
    if type(tAttribs) == "table" then
        local keys = TableKeys(tAttribs)
        table.sort(keys)
        for _, k in ipairs(keys) do
            table.insert(parts, " ")
            table.insert(parts, tostring(k))
            table.insert(parts, '="')
            table.insert(parts, XMLEncode(tostring(tAttribs[k])))
            table.insert(parts, '"')
        end
    end
    table.insert(parts, ">")
    if type(content) == "string" then
        if xmlEncodeElements == false then
            table.insert(parts, content)
        else
            table.insert(parts, XMLEncode(content))
        end
    end
    table.insert(parts, "</")
    table.insert(parts, strName)
    table.insert(parts, ">")
    return table.concat(parts)
end

-- (The old `C4Z_ROOT` global was removed — it was the dead FileSetDir token
-- restricted away in OS 3.3.0; the updater now uses the allowed "C4Z" alias.)

-- The bundler expects the file to end with a `return` statement and an
-- assignment global. We don't have a singleton to return; provide an empty
-- marker table so the bundler succeeds.
return {}
