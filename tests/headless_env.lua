-- Shared headless bootstrap for the standalone (non-Factorio) Lua hosts:
-- tests/run.lua (the solver test suite) and tests/solve_problem.lua (the
-- chain-explorer worker). Both `require "tests/headless_env"` FIRST, before
-- requiring any solver/manage module, so the search path and the one Factorio
-- stub the pure path touches are set up identically. Single-sourcing this keeps
-- the two hosts from drifting.
--
-- Must be required from the repo root so the relative require paths resolve.

-- Make `require "solver/foo"` and `require "manage/foo"` resolve against the
-- repo root. The trailing semicolons keep the standard search path as a
-- fallback (so `require "tests/harness"` also works).
package.path = "./?.lua;./?/init.lua;" .. package.path

-- manage/typed_name pulls in __flib__/format for temperature label formatting.
-- flib ships as a separate Factorio mod and is not on the standalone search
-- path, so stub the one function the headless path touches (number) with a
-- faithful copy of flib's implementation, keeping in-game and headless output
-- identical for any future formatting assertions.
package.preload["__flib__/format"] = function()
    local suffix_list = {
        { "Q", 1e30 }, { "R", 1e27 }, { "Y", 1e24 }, { "Z", 1e21 }, { "E", 1e18 },
        { "P", 1e15 }, { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 },
    }
    local fmt = {}
    function fmt.number(amount, append_suffix, fixed_precision)
        local suffix = ""
        if append_suffix then
            for _, data in ipairs(suffix_list) do
                if math.abs(amount) >= data[2] then
                    amount = amount / data[2]
                    suffix = " " .. data[1]
                    break
                end
            end
            if not fixed_precision then
                amount = math.floor(amount * 10) / 10
            end
        end
        local formatted, k = tostring(amount), nil
        if fixed_precision then
            local len_before = #tostring(math.floor(amount))
            local len_after = math.max(0, fixed_precision - len_before - 1)
            formatted = string.format("%." .. len_after .. "f", amount)
        end
        while true do
            formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
            if k == 0 then break end
        end
        return formatted .. suffix
    end
    return fmt
end
