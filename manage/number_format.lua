-- Display-number helpers shared across the UI. Two concerns live here:
--
--   1. round_for_kind -- pre-round a value before it is assigned to a
--      sprite-button's `number` field. The engine formats that field by
--      SI-abbreviating (>=1000), showing at most one mantissa decimal, and
--      FLOORING (verified in-game 2026-06-01: 59.9999996 -> "59.9",
--      999.9 -> "999", 1234.5 -> "1.2k"). Because the IPM converges to a
--      RELATIVE residual, a true 60 can solve to 59.9999996; pre-rounding onto
--      the engine's one-decimal grid makes the floor a no-op so the slot reads
--      "60", not "59.9". Slot labels elsewhere (machine count, power,
--      pollution) keep flib's fixed-width formatting -- only the slot `number`
--      field needs this pre-round.
--   2. is_negligible -- the totals show/hide cutoff, judged RELATIVE to a
--      material's gross throughput rather than against a fixed absolute pad
--      (which mistook a recycling loop's ~1e-4 noise for a phantom ingredient).
--
-- Pure Lua: no Factorio runtime globals, so the headless suite
-- (tests/cases/number_format.lua) drives it directly. The only require is
-- flib's number formatter (for format_temperature), which tests/run.lua stubs.

local flib_format = require "__flib__/format"

local M = {}

-- SI suffixes, largest-first (mirrors flib / the engine's own list).
local suffix_list = {
    { "Q", 1e30 }, { "R", 1e27 }, { "Y", 1e24 }, { "Z", 1e21 }, { "E", 1e18 },
    { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 },
}

-- Half-up rounding to a fixed number of decimal places, sign-aware.
local function round_to_decimals(value, decimals)
    if value == 0 then return 0 end
    local sign = value < 0 and -1 or 1
    local factor = 10 ^ decimals
    return sign * math.floor(math.abs(value) * factor + 0.5) / factor
end

-- Half-up rounding to `sig` significant figures (relative precision). Used by
-- round_for_kind's non-zero floor; round_to_sig(x, 5) also reproduces the
-- 5-significant-figure rounding the old accessor.round_display did.
local function round_to_sig(value, sig)
    if value == 0 then return 0 end
    local sign = value < 0 and -1 or 1
    local mag = value * sign
    local factor = 10 ^ (sig - 1 - math.floor(math.log(mag, 10)))
    return sign * math.floor(mag * factor + 0.5) / factor
end
M.round_to_sig = round_to_sig

-- Decimal places shown below 1000 for a slot `number`. A per-second rate is a
-- continuous quantity whether the material is an item or a fluid, so every
-- material kind uses one decimal -- an item produced at 30.7/s reads "30.7",
-- not "31" (which would render the same magnitude two ways across columns).
-- The SI mantissa (>=1000) is always one decimal to match the engine. `tunable`.
local DECIMALS_BY_KIND = {
    item    = 1,
    fluid   = 1,
    virtual = 1,
}

---Pre-round `value` for assignment to a sprite-button's `number` field. The
---engine then floors for display, which is a no-op because the value already
---sits on its one-decimal grid -- so a true 60 solved to 59.9999996 reads
---"60". Below 1000 the value is rounded to the kind's decimal places (with a
---non-zero floor so a genuine sub-0.1 rate keeps one significant figure instead
---of collapsing to 0); at/above 1000 the SI mantissa is rounded to one decimal.
---@param value number
---@param kind string
---@return number
function M.round_for_kind(value, kind)
    if value == 0 then return 0 end
    local decimals = DECIMALS_BY_KIND[kind] or 1
    local mag = math.abs(value)
    if mag >= 1000 then
        for _, data in ipairs(suffix_list) do
            if mag >= data[2] then
                return round_to_decimals(value / data[2], 1) * data[2]
            end
        end
    end
    local r = round_to_decimals(value, decimals)
    if r == 0 then
        -- Non-zero floor: never collapse a genuine value to 0.
        return round_to_sig(value, 1)
    end
    return r
end

---Map a material TypedName's type onto a rounding kind.
---@param typed_name TypedName
---@return string
function M.kind_for_material(typed_name)
    local t = typed_name.type
    if t == "item" then
        return "item"
    elseif t == "fluid" then
        return "fluid"
    else
        return "virtual"
    end
end

---Format a fluid temperature for display through flib's number formatter so
---very large values (fusion plasma at 1e6-1e7 °C) get an SI suffix ("1M")
---instead of scientific notation ("1e+06"). flib's third arg is a fixed display
---width that rounds badly (1500 -> "2 k"), so it is omitted; flib then floors to
---one decimal. The suffix carries a leading space ("1.5 k") that is stripped to
---keep slot labels compact ("1.5k"). Shared by the constraint slot labels
---(ui/common) and the fluid tooltip so both render identically.
---@param temperature number
---@return string
function M.format_temperature(temperature)
    return (flib_format.number(temperature, true):gsub(" ", ""))
end

---True when `net` is within the solver's RELATIVE residual of zero, judged
---against the material's gross throughput (`gross` = sum of absolute per-second
---contributions). A net flow is the difference of large opposing flows, so its
---residual noise scales with `rel_tol * gross`, NOT the bare absolute
---tolerance: a factory moving 100/s of a recycled material leaves ~1e-4 of
---numerical noise that a fixed 5e-7 cutoff would mistake for a real "phantom"
---ingredient. Conversely a genuine tiny demand (a trace catalyst) stays above
---`rel_tol * gross` and is kept. gross <= 0 means nothing flowed, so only an
---exact zero is negligible.
---@param net number
---@param gross number
---@param rel_tol number
---@return boolean
function M.is_negligible(net, gross, rel_tol)
    if gross <= 0 then
        return net == 0
    end
    return math.abs(net) <= rel_tol * gross
end

return M
