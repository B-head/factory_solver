---@diagnostic disable: undefined-global
-- Aggregate probe_amount_spectrum.lua's per-file RESULT lines into the cheat->ideal
-- direction picture. Two scale-free axes (per the probe): Nv (escape count) and the
-- defeat fraction f = Vp/(Vp+Vf+Vc). Anchors: lp (cheat), qp (amt's start), ref
-- (ideal). The amount-bake (amt) sits between. We report, per axis:
--   * mean value across the four approaches
--   * gap-closure of amt from qp toward ref: (qp - amt)/(qp - ref), capped, only
--     where the qp->ref gap is meaningful (so it measures DIRECTION, not noise)
--   * win/worse counts (amt vs qp), per axis
--
--   lua tests/research/aggregate_amt_spectrum.lua S:\tmp\amt_spectrum.tsv

local path = arg[1] or "S:/tmp/amt_spectrum.tsv"

local function parse(line)
    local t = {}
    for k, v in line:gmatch("([%w_]+)=([^\t]*)") do t[k] = tonumber(v) or v end
    return t
end

local rows = {}
for line in io.lines(path) do
    if line:match("^RESULT") then rows[#rows + 1] = parse(line) end
end

local function frac(vp, vf, vc)
    local d = (vp or 0) + (vf or 0) + (vc or 0)
    if d <= 0 then return nil end
    return (vp or 0) / d
end

-- a row is usable only if every approach finished (so we compare like for like)
local function usable(r)
    return r.ref_state == "finished" and r.lp_state == "finished"
        and r.qp_state == "finished" and r.amt_state == "finished"
        and (tonumber(r.Nv_ref) or -1) >= 0
        and (r.Nv_lp or -1) >= 0 and (r.Nv_qp or -1) >= 0 and (r.Nv_amt or -1) >= 0
end

local n_total, n_use = #rows, 0
local sumNv = { lp = 0, qp = 0, amt = 0, ref = 0 }
local sumF = { lp = 0, qp = 0, amt = 0, ref = 0 }
local nF = { lp = 0, qp = 0, amt = 0, ref = 0 }

-- gap closure accumulators
local clNv_sum, clNv_n = 0, 0
local clF_sum, clF_n = 0, 0
local win = { Nv = 0, F = 0 }
local worse = { Nv = 0, F = 0 }
local same = { Nv = 0, F = 0 }

local GAP_MIN_NV = 1      -- only score Nv closure where qp is >=1 above ref
local GAP_MIN_F = 0.05    -- only score defeat closure where qp fraction is >=0.05 above ref

for _, r in ipairs(rows) do
    if usable(r) then
        n_use = n_use + 1
        sumNv.lp = sumNv.lp + r.Nv_lp; sumNv.qp = sumNv.qp + r.Nv_qp
        sumNv.amt = sumNv.amt + r.Nv_amt; sumNv.ref = sumNv.ref + (tonumber(r.Nv_ref) or 0)

        local fl, fq, fa, fr = frac(r.Vp_lp, r.Vf_lp, r.Vc_lp), frac(r.Vp_qp, r.Vf_qp, r.Vc_qp),
            frac(r.Vp_amt, r.Vf_amt, r.Vc_amt), frac(r.Vp_ref, r.Vf_ref, r.Vc_ref)
        if fl then sumF.lp = sumF.lp + fl; nF.lp = nF.lp + 1 end
        if fq then sumF.qp = sumF.qp + fq; nF.qp = nF.qp + 1 end
        if fa then sumF.amt = sumF.amt + fa; nF.amt = nF.amt + 1 end
        if fr then sumF.ref = sumF.ref + fr; nF.ref = nF.ref + 1 end

        -- Nv gap closure (qp -> amt vs qp -> ref)
        local gapNv = r.Nv_qp - (tonumber(r.Nv_ref) or 0)
        if gapNv >= GAP_MIN_NV then
            local cl = (r.Nv_qp - r.Nv_amt) / gapNv
            if cl > 1 then cl = 1 elseif cl < -1 then cl = -1 end
            clNv_sum = clNv_sum + cl; clNv_n = clNv_n + 1
        end
        -- amt vs qp win/worse on Nv (lower = better)
        if r.Nv_amt < r.Nv_qp - 1e-9 then win.Nv = win.Nv + 1
        elseif r.Nv_amt > r.Nv_qp + 1e-9 then worse.Nv = worse.Nv + 1
        else same.Nv = same.Nv + 1 end

        -- defeat fraction gap closure
        if fq and fr and fa then
            local gapF = fq - fr
            if gapF >= GAP_MIN_F then
                local cl = (fq - fa) / gapF
                if cl > 1 then cl = 1 elseif cl < -1 then cl = -1 end
                clF_sum = clF_sum + cl; clF_n = clF_n + 1
            end
            if fa and fq then
                if fa < fq - 1e-6 then win.F = win.F + 1
                elseif fa > fq + 1e-6 then worse.F = worse.F + 1
                else same.F = same.F + 1 end
            end
        end
    end
end

local function avg(s, n) return n > 0 and s / n or 0 end

io.write(string.format("amt-spectrum aggregate: %d rows, %d usable (all four finished)\n\n", n_total, n_use))

io.write("== escape count Nv (lower = cleaner; ref = ideal) ==\n")
io.write(string.format("  mean Nv:   lp=%.2f   qp=%.2f   amt=%.2f   ref=%.2f\n",
    avg(sumNv.lp, n_use), avg(sumNv.qp, n_use), avg(sumNv.amt, n_use), avg(sumNv.ref, n_use)))
io.write(string.format("  amt gap-closure qp->ref: %.1f%%  (n=%d files with qp-ref gap >= %d)\n",
    100 * avg(clNv_sum, clNv_n), clNv_n, GAP_MIN_NV))
io.write(string.format("  amt vs qp:  win(lower)=%d  worse=%d  same=%d\n\n", win.Nv, worse.Nv, same.Nv))

io.write("== defeat fraction Vp/(Vp+Vf+Vc) (lower = less producible-import cheat; ref = ideal) ==\n")
io.write(string.format("  mean f:    lp=%.3f   qp=%.3f   amt=%.3f   ref=%.3f\n",
    avg(sumF.lp, nF.lp), avg(sumF.qp, nF.qp), avg(sumF.amt, nF.amt), avg(sumF.ref, nF.ref)))
io.write(string.format("  amt gap-closure qp->ref: %.1f%%  (n=%d files with qp-ref gap >= %.2f)\n",
    100 * avg(clF_sum, clF_n), clF_n, GAP_MIN_F))
io.write(string.format("  amt vs qp:  win(lower)=%d  worse=%d  same=%d\n", win.F, worse.F, same.F))
