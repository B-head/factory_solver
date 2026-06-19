---@diagnostic disable: undefined-global
-- Re-read amt_spectrum.tsv WITHOUT a verdict: report the absolute boundary
-- components (Vp producible import, Vf non-producible makeup, Vc consumable dump)
-- and Nv for each approach, plus per-file amt-vs-qp direction on each component.
-- No good/bad labels, no derived "defeat fraction" -- just the numbers, so the
-- denominator-collapse artifact in the fraction can't hide what each component did.
--
--   lua tests/research/aggregate_amt_components.lua S:\tmp\amt_spectrum.tsv

local path = arg[1] or "S:/tmp/amt_spectrum.tsv"
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
        and (tonumber(r.Nv_ref) or -1) >= 0
end

local function median(t)
    if #t == 0 then return 0 end
    table.sort(t)
    local m = (#t + 1) / 2
    if m == math.floor(m) then return t[m] end
    return 0.5 * (t[math.floor(m)] + t[math.ceil(m)])
end
local function quart(t, q)
    if #t == 0 then return 0 end
    table.sort(t); local i = math.max(1, math.min(#t, math.floor(q * #t + 0.5))); return t[i]
end

-- per-approach accumulators
local apps = { "lp", "qp", "amt", "ref" }
local sum = {}; local med = {}
for _, a in ipairs(apps) do sum[a] = { Vp = 0, Vc = 0, Vf = 0, Nv = 0 }; med[a] = { Vp = {}, Vc = {}, Vf = {}, Nv = {} } end

-- amt-vs-qp per-file direction on each component (only where qp component > eps)
local EPS = 1e-6
local dir = { Vp = { down = 0, same = 0, up = 0, n = 0, ratio = {} },
    Vc = { down = 0, same = 0, up = 0, n = 0, ratio = {} },
    Vf = { down = 0, same = 0, up = 0, n = 0, ratio = {} } }
-- the artifact test: among files where the defeat fraction rose, did Vp actually rise?
local frac_rose, frac_rose_Vp_not_up = 0, 0
local n_use = 0

local function fr(r, suf)
    local vp, vc, vf = r["Vp_" .. suf] or 0, r["Vc_" .. suf] or 0, r["Vf_" .. suf] or 0
    local d = vp + vc + vf; return d > 0 and vp / d or nil
end

for _, r in ipairs(rows) do
    if usable(r) then
        n_use = n_use + 1
        for _, a in ipairs(apps) do
            for _, c in ipairs({ "Vp", "Vc", "Vf", "Nv" }) do
                local v = tonumber(r[c .. "_" .. a]) or 0
                sum[a][c] = sum[a][c] + v
                med[a][c][#med[a][c] + 1] = v
            end
        end
        for _, c in ipairs({ "Vp", "Vc", "Vf" }) do
            local q, am = r[c .. "_qp"] or 0, r[c .. "_amt"] or 0
            if q > EPS then
                dir[c].n = dir[c].n + 1
                if am < q * (1 - 1e-4) then dir[c].down = dir[c].down + 1
                elseif am > q * (1 + 1e-4) then dir[c].up = dir[c].up + 1
                else dir[c].same = dir[c].same + 1 end
                dir[c].ratio[#dir[c].ratio + 1] = am / q
            end
        end
        local fq, fa = fr(r, "qp"), fr(r, "amt")
        if fq and fa and fa > fq + 1e-6 then
            frac_rose = frac_rose + 1
            if (r.Vp_amt or 0) <= (r.Vp_qp or 0) * (1 + 1e-4) then
                frac_rose_Vp_not_up = frac_rose_Vp_not_up + 1
            end
        end
    end
end

io.write(string.format("amt components: %d usable (all four finished)\n\n", n_use))

io.write("== mean (sum/N) -- dominated by huge-Vp outliers like seed_117 ==\n")
io.write(string.format("  %-5s %-12s %-12s %-12s %-8s\n", "", "Vp", "Vc", "Vf", "Nv"))
for _, a in ipairs(apps) do
    io.write(string.format("  %-5s %-12.4g %-12.4g %-12.4g %-8.2f\n",
        a, sum[a].Vp / n_use, sum[a].Vc / n_use, sum[a].Vf / n_use, sum[a].Nv / n_use))
end

io.write("\n== median ==\n")
io.write(string.format("  %-5s %-12s %-12s %-12s %-8s\n", "", "Vp", "Vc", "Vf", "Nv"))
for _, a in ipairs(apps) do
    io.write(string.format("  %-5s %-12.4g %-12.4g %-12.4g %-8.4g\n",
        a, median(med[a].Vp), median(med[a].Vc), median(med[a].Vf), median(med[a].Nv)))
end

io.write("\n== amt vs qp, per file, on each component (only where Vp_qp/Vc_qp/Vf_qp > 1e-6) ==\n")
for _, c in ipairs({ "Vp", "Vc", "Vf" }) do
    local d = dir[c]
    io.write(string.format("  %s: files=%d  down=%d  same=%d  up=%d   ratio amt/qp  median=%.4g  q25=%.4g  q75=%.4g\n",
        c, d.n, d.down, d.same, d.up, median(d.ratio), quart(d.ratio, 0.25), quart(d.ratio, 0.75)))
end

io.write(string.format("\n== fraction-artifact check ==\n  defeat fraction f rose (amt>qp) in %d files; of those, Vp did NOT rise in %d (%.0f%%)\n",
    frac_rose, frac_rose_Vp_not_up, frac_rose > 0 and 100 * frac_rose_Vp_not_up / frac_rose or 0))
io.write("  (high % => the f-rise I called 'cheat' was the Vc+Vf denominator collapsing, not Vp growing)\n")
