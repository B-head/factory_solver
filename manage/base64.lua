-- Standard RFC 4648 base64 encode / decode in pure Lua.
--
-- LibDeflate ships its own 6-bit "EncodeForPrint" codec, but that is a custom
-- alphabet, not standard base64. YAFC's shared string is produced by C#
-- `Convert.ToBase64String`, so the codec layer needs canonical base64 (A-Z a-z
-- 0-9 + / with '=' padding) to interoperate. Kept dependency-free (no `helpers`,
-- no Factorio globals) so the headless suite can exercise it directly.
local M = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- enc[0..63] -> output character ; dec[byte] -> 0..63
local enc = {}
local dec = {}
for i = 1, 64 do
    local c = string.sub(ALPHABET, i, i)
    enc[i - 1] = c
    dec[string.byte(c)] = i - 1
end

---Encode a byte string to standard base64 (with '=' padding).
---@param data string
---@return string
function M.encode(data)
    local out = {}
    local n = #data
    local i = 1
    while i <= n do
        local b1 = string.byte(data, i)
        local b2 = string.byte(data, i + 1)
        local b3 = string.byte(data, i + 2)

        local c1 = enc[math.floor(b1 / 4)]
        local c2 = enc[(b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)]
        local c3 = b2 and enc[(b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)] or "="
        local c4 = b3 and enc[b3 % 64] or "="

        out[#out + 1] = c1 .. c2 .. c3 .. c4
        i = i + 3
    end
    return table.concat(out)
end

---Decode a standard base64 string back to a byte string. Non-alphabet bytes
---(whitespace, newlines) are skipped; decoding stops at the first '=' padding.
---The accumulator is reduced to its low `nbits` after each emitted byte so it
---never grows past float precision on long inputs.
---@param s string
---@return string
function M.decode(s)
    local out = {}
    local bits, nbits = 0, 0
    for i = 1, #s do
        local c = string.byte(s, i)
        if c == 61 then -- '='
            break
        end
        local v = dec[c]
        if v then
            bits = bits * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local divisor = 2 ^ nbits
                local byte = math.floor(bits / divisor)
                out[#out + 1] = string.char(byte)
                bits = bits - byte * divisor
            end
        end
    end
    return table.concat(out)
end

return M
