---@diagnostic disable: undefined-global
-- Test whether the Vp metric (graded against ref-derived producible set) has any
-- RESOLUTION among non-ref approaches, or only separates "ref" from "everyone else".
-- ref is the lexicographic argmin of (T,Vp,Vf,Vc,M) under exactly the P/C sets used
-- to grade (solve_reference stages 2a/2b/2c), so Vp_ref~0 is tautological. The open
-- question: on problems where ref avoids producible import (Vp_ref small) but there
-- IS producible-import pressure, do lp / qp / amt differ from each other, or do they
-- all eat the same defeat? No labels -- raw counts and ratio distributions.
--
--   lua tests/research/aggregate_metric_bias.lua S:\tmp\amt_spectrum.tsv

local path = arg[1] or "S:/tmp/amt_spectrum.tsv"
local DUST = 1e-3 -- neutral technical floor for "is there producible import here"

local function parse(line)
    local t = {}
    for k, v in line:gmatch("([%w_]+)=([^\t]*)") do t[k] = tonumber(v) or v end
    return t
end
local rows = {}
for line in io.lines(path) do if line:match("^RESULT") then rows[#rows + 1] = parse(line) end end
local function usable(r)
    return r.ref_state == "finished" and r.lp_state == "finished"
        and r.qp_state == "finished" and r.amt_state == "finished"
end
local function median(t)
    if #t == 0 then return 0 end
    table.sort(t); local m = (#t + 1) / 2
    if m == math.floor(m) then return t[m] end
    return 0.5 * (t[math.floor(m)] + t[math.ceil(m)])
end

local n_use = 0
local ref_clean, ref_dirty = 0, 0          -- Vp_ref <= DUST or not
local pressure = 0                          -- ref clean AND some non-ref has Vp > DUST
local eat = { lp = 0, qp = 0, amt = 0 }     -- of those, how many leave Vp > DUST
local r_amt_lp, r_amt_qp = {}, {}           -- Vp_amt/Vp_lp, Vp_amt/Vp_qp on pressure files
local close_to_lp, half_of_lp = 0, 0        -- amt within 10% of lp's Vp / below half of lp's Vp
local both_lp = 0

for _, r in ipairs(rows) do
    if usable(r) then
        n_use = n_use + 1
        local vpr, vpl, vpq, vpa = r.Vp_ref or 0, r.Vp_lp or 0, r.Vp_qp or 0, r.Vp_amt or 0
        if vpr <= DUST then
            ref_clean = ref_clean + 1
            if vpl > DUST or vpq > DUST or vpa > DUST then
                pressure = pressure + 1
                if vpl > DUST then eat.lp = eat.lp + 1 end
                if vpq > DUST then eat.qp = eat.qp + 1 end
                if vpa > DUST then eat.amt = eat.amt + 1 end
                if vpl > DUST and vpa > DUST then
                    both_lp = both_lp + 1
                    local ratio = vpa / vpl
                    r_amt_lp[#r_amt_lp + 1] = ratio
                    if ratio >= 0.9 and ratio <= 1.1 then close_to_lp = close_to_lp + 1 end
                    if ratio < 0.5 then half_of_lp = half_of_lp + 1 end
                end
                if vpq > DUST and vpa > DUST then r_amt_qp[#r_amt_qp + 1] = vpa / vpq end
            end
        else
            ref_dirty = ref_dirty + 1
        end
    end
end

io.write(string.format("metric-bias check on Vp: %d usable\n\n", n_use))
io.write(string.format("ref Vp <= dust(%.0e): %d files (clean)   ref Vp > dust: %d files (ref itself imports producible)\n",
    DUST, ref_clean, ref_dirty))
io.write(string.format("\nof the ref-clean files, %d have producible-import PRESSURE (some non-ref Vp > dust):\n", pressure))
io.write(string.format("  leave Vp > dust:  lp=%d  qp=%d  amt=%d   (out of %d)\n", eat.lp, eat.qp, eat.amt, pressure))
io.write(string.format("\namt vs lp (the pure cheat) on the %d files where BOTH leave Vp > dust:\n", both_lp))
io.write(string.format("  Vp_amt / Vp_lp  median=%.4g   (==1 means amt eats exactly what the cheat eats)\n", median(r_amt_lp)))
io.write(string.format("  within 10%% of lp = %d    below half of lp = %d    (of %d)\n", close_to_lp, half_of_lp, both_lp))
io.write(string.format("\namt vs qp on files where both leave Vp > dust (n=%d):\n", #r_amt_qp))
io.write(string.format("  Vp_amt / Vp_qp  median=%.4g\n", median(r_amt_qp)))
