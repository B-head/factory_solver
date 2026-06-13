-- Minimal JSON encoder in pure Lua, used only by the YAFC export path.
--
-- Factorio's helpers.table_to_json cannot express two shapes YAFC's
-- deserializer requires: an empty JSON array (it emits `{}`, an object, for any
-- empty Lua table) and an explicit `null` (a nil value just drops its key). YAFC
-- expects e.g. `"modules":{"beacon":null,"list":[],"beaconList":[]}`, so the
-- export builds its payload with M.array(...) to force `[...]` (even when empty)
-- and M.null to force `null`, then serializes it here. Dependency-free (no
-- `helpers`, no Factorio globals) so the headless suite covers it directly.
--
-- Decoding stays on helpers.json_to_table: standard JSON parses fine, and this
-- encoder only adds the [] / null shapes the round-trip needs.
local M = {}

-- Sentinel value that serializes to JSON `null` (distinct from Lua nil, which
-- would simply drop the key from its containing object).
M.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MT = {}

---Tag a table as a JSON array so it serializes as `[...]` — including `[]` when
---empty, which a bare Lua table cannot express. Returns the same table.
---@param t table?
---@return table
function M.array(t)
    return setmetatable(t or {}, ARRAY_MT)
end

local ESCAPES = {
    ['"'] = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

---@param s string
---@return string
local function encode_string(s)
    local body = string.gsub(s, '[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. body .. '"'
end

---@param n number
---@return string
local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        -- JSON has no NaN / Infinity; emit 0 defensively rather than invalid JSON.
        return "0"
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    -- 17 significant digits round-trips an IEEE-754 double losslessly.
    return string.format("%.17g", n)
end

local encode_value

---@param t table
---@param out string[]
local function encode_array(t, out)
    out[#out + 1] = "["
    for i = 1, #t do
        if i > 1 then out[#out + 1] = "," end
        encode_value(t[i], out)
    end
    out[#out + 1] = "]"
end

---@param t table
---@param out string[]
local function encode_object(t, out)
    -- Sort keys so output is deterministic across runs / clients (object key
    -- order is irrelevant to YAFC, which reads properties by name).
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)

    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encode_string(tostring(k))
        out[#out + 1] = ":"
        encode_value(t[k], out)
    end
    out[#out + 1] = "}"
end

---@param v any
---@param out string[]
function encode_value(v, out)
    if v == M.null or v == nil then
        out[#out + 1] = "null"
        return
    end
    local tv = type(v)
    if tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        out[#out + 1] = encode_number(v)
    elseif tv == "string" then
        out[#out + 1] = encode_string(v)
    elseif tv == "table" then
        if getmetatable(v) == ARRAY_MT then
            encode_array(v, out)
        else
            encode_object(v, out)
        end
    else
        out[#out + 1] = "null"
    end
end

---Serialize a Lua value to a JSON string. Tables are objects unless tagged with
---M.array; M.null serializes to `null`.
---@param value any
---@return string
function M.encode(value)
    local out = {}
    encode_value(value, out)
    return table.concat(out)
end

return M
