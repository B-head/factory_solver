---@diagnostic disable: undefined-global
-- After an L2 (QP) solve, REMOVE one active violation-elastic (set_quad -> 0 AND
-- force its value to 0 via a fresh "= 0" row) and re-solve COLD, then read which
-- variables moved -- tagging every moved recipe / material by the cyclic SCC of
-- the material graph it touches. The question this answers: is the change-set
-- localized to a cycle (the removed boundary flow reroutes around a loop), or does
-- it leak to OTHER boundary elastics (import/dump shuffles to another channel)?
--
-- Conventions this corpus demands (CLAUDE.local.md):
--   * every cited number is labelled variable-space (xvar) vs physical (phys/s) --
--     a recipe activity and an escape |x| are xvar; coefficient*x and the
--     produced/consumed totals are phys;
--   * the raw change-set is DUMPED and SCC membership is ATTACHED, not graded --
--     no good/bad label is invented here (no_bias_in_research);
--   * QP must NOT warm-start (the L2 warm-start divergence bug) -- every solve
--     here is an independent COLD solve of a freshly built problem;
--   * a no-perturbation CONTROL solve establishes the determinism noise floor, so
--     a reported change is known to be causal, not IPM face-shuffle.
--
--   lua tests/research/probe_l2_elastic_cycle.lua [dump] [topN]

require "tests/headless_env"
local R = require "tests/research/research_lib"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local D = R.dissect

-- Shipped L2 knobs (manage/pre_solve.lua: VIOLATION_QUAD / VIOLATION_FLOOR / L2_RECIPE_EPS).
local VIOLATION_QUAD, VIOLATION_FLOOR, L2_RECIPE_EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10

local PATH = arg[1] or
    "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local TOPN = tonumber(arg[2]) or 6
-- Perturbation mode:
--   "free"   -- zero ONLY the quad on the chosen elastic; leave its value free.
--             The L2 linear floor (2^-8) stays, so the column becomes the CHEAPEST
--             channel (no quadratic magnitude penalty), and the optimum CONCENTRATES
--             imbalance onto it, pulling it off the still-quadratic siblings.
--   "remove" -- zero the quad AND pin the value to 0 (the original removal probe).
local MODE = arg[3] or "free"
local prob = assert(problem_dump.load_problem(PATH))

---Build a fresh shipped-L2 problem (un-gated baseline + shape_l2).
---@return Problem
local function build_l2()
    local problem = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, {
        reachability_gating = false,
        deficit_seeding = false,
        catalyst_closure = false,
        surplus_sink_gating = false,
        recipe_epsilon = L2_RECIPE_EPS,
    })
    create_problem.shape_l2(problem, VIOLATION_QUAD, VIOLATION_FLOOR)
    return problem
end

---Perturb one violation-elastic. "free": drop ONLY its quad curvature (value left
---free -- it becomes the cheapest channel and the optimum concentrates onto it).
---"remove": also pin the value to 0 with a fresh `v + pos_slack = 0` row (v >= 0,
---slack >= 0 => v == 0). Mutates the research-owned problem only.
---@param problem Problem
---@param v string
---@param mode "free"|"remove"
local function perturb_elastic(problem, v, mode)
    problem:set_quad(v, 0)
    if mode == "remove" then
        local dual = "|probe_fix0|" .. v
        problem:add_upper_limit_constraint(dual, 0)
        problem:add_subject_term(v, dual, 1)
    end
end

---|coefficient * x| physical magnitude of an escape/elastic on its OWN material row.
local function phys(problem, key, x)
    local p = problem.primals[key]
    local t = problem.subject_terms[key]
    local c = (p and p.material and t and t[p.material]) or 1
    return math.abs(c * (x[key] or 0))
end

---Largest recipe activity (xvar), for a recipe-relative change threshold.
local function max_recipe(problem, x)
    local m = 0
    for k, p in pairs(problem.primals) do
        if p.kind == "recipe" then
            local a = math.abs(x[k] or 0)
            if a > m then m = a end
        end
    end
    return m
end

---Variables whose value moved between two solved points by more than `thr` (xvar),
---sorted by |delta| descending.
---@return { k: string, a: number, b: number, d: number }[]
local function diff(x0, x1, thr)
    local seen, out = {}, {}
    for k in pairs(x0) do seen[k] = true end
    for k in pairs(x1) do seen[k] = true end
    for k in pairs(seen) do
        local a, b = x0[k] or 0, x1[k] or 0
        if math.abs(b - a) > thr then out[#out + 1] = { k = k, a = a, b = b, d = b - a } end
    end
    table.sort(out, function(p, q) return math.abs(p.d) > math.abs(q.d) end)
    return out
end

-- ---- baseline ---------------------------------------------------------------

local base = build_l2()
local x0, st0 = D and nil, nil
x0, st0 = (function()
    local x, s = R.drive_solve(base, prob.meta)
    return x, s
end)()

local lines = D.all_lines(prob.normalized_lines, base)
local scc = D.cyclic_sccs(lines)         -- { adj, cyclic, tag, members }
local rms = D.recipe_material_sets(lines) -- recipe var -> set of material vars
local maxr = max_recipe(base, x0)
local chg_thr = math.max(1e-9, maxr * 1e-6)

---Set of cyclic-SCC tags ("C##") a recipe touches.
local function recipe_sccs(rk)
    local s = {}
    for m in pairs(rms[rk] or {}) do
        local t = scc.tag[m]
        if t then s[t] = true end
    end
    return s
end

io.write(string.format("L2 ELASTIC->CYCLE  mode=%s  %s  tol=%g\n", MODE, R.fileid(PATH), prob.meta.tolerance))
if MODE == "free" then
    io.write(string.format("  (free: zero ONLY the quad; the L2 linear floor %.4g stays, so the column is cheapest-not-free)\n",
        VIOLATION_FLOOR))
end
io.write(string.format("baseline: state=%s  maxRecipe(xvar)=%.6g  chgThr(xvar)=%.3g\n",
    tostring(st0), maxr, chg_thr))

-- cyclic SCC inventory
io.write(string.format("cyclic SCCs: %d\n", #scc.cyclic))
for i, s in ipairs(scc.cyclic) do
    local id = string.format("C%02d", i)
    if i <= 12 then
        io.write(string.format("  %s size=%-3d  e.g. %s%s\n", id, #s, s[1] or "?",
            s[2] and (", " .. s[2]) or ""))
    end
end

-- ---- control: re-build + re-solve unperturbed, diff vs x0 (noise floor) ------

local ctrl = build_l2()
local xc = R.drive_solve(ctrl, prob.meta)
local ctrl_changed = diff(x0, xc, chg_thr)
local ctrl_max = ctrl_changed[1] and math.abs(ctrl_changed[1].d) or 0
io.write(string.format("\ncontrol (no perturbation): changed=%d  max|Δ|(xvar)=%.3g  <- determinism noise floor\n",
    #ctrl_changed, ctrl_max))

-- ---- enumerate active violation-elastics (the columns L2 puts a quad on) -----

local active = {}
for key, p in pairs(base.primals) do
    if (p.kind == "shortage_source" or p.kind == "surplus_sink") and math.abs(x0[key] or 0) > chg_thr then
        active[#active + 1] = { key = key, kind = p.kind, material = p.material,
            xvar = math.abs(x0[key] or 0), phys = phys(base, key, x0) }
    end
end
table.sort(active, function(a, b) return a.xvar > b.xvar end)
io.write(string.format("active violation-elastics (xvar > %.3g): %d  (probing top %d)\n",
    chg_thr, #active, math.min(TOPN, #active)))

-- Graph topology context: how many recipes touch a cyclic SCC vs none, and how
-- many are active at baseline. Without this, "every moved recipe is cyclic" could
-- just mean "almost every recipe is cyclic" (a property of THIS dump, not the
-- perturbation). Counts let the reader separate the two.
do
    local tot, cyc, cyc01, act, act_cyc = 0, 0, 0, 0, 0
    for rk, p in pairs(base.primals) do
        if p.kind == "recipe" then
            tot = tot + 1
            local s = recipe_sccs(rk)
            local any, c01 = next(s) ~= nil, s.C01 == true
            if any then cyc = cyc + 1 end
            if c01 then cyc01 = cyc01 + 1 end
            if math.abs(x0[rk] or 0) > chg_thr then
                act = act + 1
                if any then act_cyc = act_cyc + 1 end
            end
        end
    end
    io.write(string.format("recipe topology: total=%d  touch-any-cyclic-SCC=%d  touch-C01=%d  |  active=%d (of those cyclic=%d)\n\n",
        tot, cyc, cyc01, act, act_cyc))
end

-- baseline physical flows, reused for per-elastic material-move diffs.
local prod0, cons0 = D.physical_flows(lines, x0, { fuel = true, eps = 1e-9 })

-- ---- per-elastic removal -----------------------------------------------------

---Print the change-set classification + cycle relationship for one removal.
local function report(elt, detailed)
    local problem = build_l2()
    perturb_elastic(problem, elt.key, MODE)
    local x1, st1 = R.drive_solve(problem, prob.meta)
    local changed = diff(x0, x1, chg_thr)

    -- classify the moved columns by kind (kind read from the perturbed problem,
    -- which is a superset -- it also holds the probe's own fix pos_slack).
    local cnt = { recipe = 0, shortage_source = 0, surplus_sink = 0, bridge = 0, elastic = 0, slack = 0, other = 0 }
    local by_scc = {}                      -- "C##"|"none" -> moved-recipe count
    local touch_removed = 0                -- moved recipes touching the removed material's SCC
    local rem_tag = elt.material and scc.tag[elt.material] or nil
    local d_other_short, d_other_surp = 0, 0 -- phys leak onto OTHER boundary elastics
    for _, c in ipairs(changed) do
        local p = problem.primals[c.k] or base.primals[c.k]
        local kind = p and p.kind or "other"
        cnt[kind] = (cnt[kind] or 0) + 1
        if kind == "recipe" then
            local tags = recipe_sccs(c.k)
            local any = false
            for t in pairs(tags) do
                by_scc[t] = (by_scc[t] or 0) + 1; any = true
                if rem_tag and t == rem_tag then touch_removed = touch_removed + 1 end
            end
            if not any then by_scc.none = (by_scc.none or 0) + 1 end
        elseif kind == "shortage_source" and c.k ~= elt.key then
            d_other_short = d_other_short + math.abs((problem.subject_terms[c.k]
                and p.material and problem.subject_terms[c.k][p.material] or 1) * c.d)
        elseif kind == "surplus_sink" and c.k ~= elt.key then
            d_other_surp = d_other_surp + math.abs((problem.subject_terms[c.k]
                and p.material and problem.subject_terms[c.k][p.material] or 1) * c.d)
        end
    end

    -- the perturbed elastic's OWN move (in "free" mode it GROWS as it concentrates).
    local self_phys0 = phys(base, elt.key, x0)
    local self_phys1 = phys(problem, elt.key, x1)
    io.write(string.format("== %s %s [%s]  baseline xvar=%.6g phys=%.6g  matSCC=%s ==\n",
        MODE, elt.material or elt.key, elt.kind, elt.xvar, elt.phys, rem_tag or "-"))
    io.write(string.format("   re-solve: state=%s   this elastic phys %.6g -> %.6g (Δ=%+.6g)\n",
        tostring(st1), self_phys0, self_phys1, self_phys1 - self_phys0))
    io.write(string.format("   moved cols=%d  (recipe=%d short=%d surp=%d bridge=%d elastic=%d slack=%d)\n",
        #changed, cnt.recipe, cnt.shortage_source, cnt.surplus_sink, cnt.bridge, cnt.elastic, cnt.slack))
    -- moved recipes grouped by the cyclic SCC they touch
    local parts = {}
    for t, n in pairs(by_scc) do parts[#parts + 1] = string.format("%s:%d", t, n) end
    table.sort(parts)
    io.write(string.format("   moved recipes by cyclic SCC: %s\n", #parts > 0 and table.concat(parts, "  ") or "(none moved)"))
    if rem_tag then
        io.write(string.format("   removed material is in %s; moved recipes touching %s = %d / %d recipe-moves\n",
            rem_tag, rem_tag, touch_removed, cnt.recipe))
    else
        io.write("   removed material is in NO cyclic SCC (acyclic boundary)\n")
    end
    io.write(string.format("   other-elastic redistribution (phys, |Δ| sum excl. this one): shortage=%.6g  surplus=%.6g\n",
        d_other_short, d_other_surp))

    -- ---- METHOD 1: circulation vs net-throughput decomposition of Δx ----------
    -- Per material, the part of produced & consumed that moves the SAME direction
    -- (a wash adds production AND consumption equally) is the CIRCULATION component
    -- circ_m = min(|Δprod|,|Δcons|); the residual net_m = |Δprod - Δcons| is the
    -- net-throughput change that must be balanced at the boundary. Aggregating circ
    -- by cyclic-SCC tag separates a TRUE cycle wash (circ on a cyclic material) from
    -- a mere intermediate throughput rise (circ on an acyclic material) -- both look
    -- like Δprod≈Δcons; only the SCC tag tells them apart. This is the physical proxy
    -- for projecting Δx onto null(S) (the cycle space); net_m == (S·Δx_recipe)[m].
    local prod1, cons1 = D.physical_flows(lines, x1, { fuel = true, eps = 1e-9 })
    local mats, seenm = {}, {}
    for m in pairs(prod0) do seenm[m] = true end
    for m in pairs(prod1) do seenm[m] = true end
    for m in pairs(cons0) do seenm[m] = true end
    for m in pairs(cons1) do seenm[m] = true end
    local circ_by_scc, circ_acyc, net_total = {}, 0, 0
    local circ_list = {}
    for m in pairs(seenm) do
        local dp = (prod1[m] or 0) - (prod0[m] or 0)
        local dc = (cons1[m] or 0) - (cons0[m] or 0)
        if math.abs(dp) + math.abs(dc) > chg_thr then
            mats[#mats + 1] = { m = m, dp = dp, dc = dc, mag = math.abs(dp) + math.abs(dc) }
            local circ = ((dp > 0) == (dc > 0)) and math.min(math.abs(dp), math.abs(dc)) or 0
            net_total = net_total + math.abs(dp - dc)
            if circ > chg_thr then
                local tg = scc.tag[m]
                if tg then circ_by_scc[tg] = (circ_by_scc[tg] or 0) + circ else circ_acyc = circ_acyc + circ end
                circ_list[#circ_list + 1] = { m = m, circ = circ, tg = tg }
            end
        end
    end
    local cyc_circ = 0
    for _, v in pairs(circ_by_scc) do cyc_circ = cyc_circ + v end
    local flux = cyc_circ + circ_acyc + net_total
    io.write(string.format("   [M1] circulation(phys): cyclic=%.5g  acyclic=%.5g  net-throughput=%.5g  | cyclic-share=%.3f\n",
        cyc_circ, circ_acyc, net_total, flux > 0 and cyc_circ / flux or 0))
    local cparts = {}
    for t, v in pairs(circ_by_scc) do cparts[#cparts + 1] = string.format("%s:%.4g", t, v) end
    table.sort(cparts)
    io.write(string.format("   [M1] cyclic circulation by SCC: %s\n", #cparts > 0 and table.concat(cparts, "  ") or "(none)"))
    table.sort(circ_list, function(a, b) return a.circ > b.circ end)
    io.write("   [M1] top circulating materials (phys/s, matched Δprod≈Δcons):\n")
    for i = 1, math.min(5, #circ_list) do
        local cm = circ_list[i]
        io.write(string.format("     %-28s %-4s circ=%.5g\n", cm.m, cm.tg or "ACYC", cm.circ))
    end

    table.sort(mats, function(a, b) return a.mag > b.mag end)
    io.write("   physical material moves (top 6, phys/s):\n")
    for i = 1, math.min(6, #mats) do
        local mm = mats[i]
        io.write(string.format("     %-28s %-4s Δprod=%+.6g Δcons=%+.6g\n",
            mm.m, scc.tag[mm.m] or "-", mm.dp, mm.dc))
    end

    if detailed then
        io.write("   --- full moved-column listing (xvar, sorted by |Δ|) ---\n")
        for _, c in ipairs(changed) do
            local p = problem.primals[c.k] or base.primals[c.k]
            local kind = p and p.kind or "?"
            local mat = p and p.material or ""
            local tg = (kind == "recipe") and (function()
                local ts = {}; for t in pairs(recipe_sccs(c.k)) do ts[#ts + 1] = t end
                table.sort(ts); return table.concat(ts, ",")
            end)() or (mat ~= "" and (scc.tag[mat] or "") or "")
            io.write(string.format("     %-14s %-16s %8.5g -> %8.5g  Δ=%+.5g  %s\n",
                kind, tg ~= "" and tg or "-", c.a, c.b, c.d, mat ~= "" and mat or c.k))
        end
    end
    io.write("\n")
end

local last = math.min(TOPN, #active)
for i = 1, last do
    report(active[i], i == 1 or i == last)
end
