---@diagnostic disable: undefined-global
-- (B) hypothesis test: "minimize total violation (symmetric), but block CLEAN
-- producible imports; allow importing a producible only when its fabrication
-- forces a dump." Implemented as a fixpoint over a `justified` set, found by
-- STEEPEST descent (each round, try every dump-forcing co-product, commit the one
-- that lowers total the most without collapsing the factory).
--
-- Base = producible import HI (blocked), makeup/dump = 1 (symmetric, allowed),
-- raw/final free, target tier on top. Justifying material M sets its import to LO.
-- Guard: a justification is accepted only if total drops, recipes stay >= 0.5*base,
-- and the target stays met.
--
--   luajit tests/research/probe_unified_fixpoint.lua [HI] [DUMP] [LO] [file ...]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local lp = require "solver/linear_programming"

local CORPUS = "S:/tmp/explore_problems/"
local HI = tonumber(arg[1]) or 1e6
local DUMP = tonumber(arg[2]) or 1
local LO = tonumber(arg[3]) or 1
local DUST, ROUNDS = 1e-3, 6

local FILES = {}
for i = 4, #arg do FILES[#FILES + 1] = { tag = "arg", path = arg[i], name = arg[i]:gsub(".*/", "") } end
if #FILES == 0 then
    local anchors = {
        "seed_24_cycle_recipe_vex_sex_p1_noq_trecipe_con_h48.lua",
        "seed_109_cycle_recipe_vex_sex_p1_noq_trecipe_con_h48.lua",
        "seed_18_cycle_recipe_vex_sex_p1_noq_trecipe_con_h48.lua",
        "seed_16_cycle_recipe_vex_sex_p1_noq_trecipe_con_h48.lua",
        "seed_17_cycle_recipe_vex_sex_p1_noq_trecipe_con_h24.lua",
        "seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua",
    }
    local sample = {
        "seed_100_both_recipe_vin_sin_p1_noq_trecipe_con_h12.lua",
        "seed_113_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24.lua",
        "seed_139_cycle_recipe_vin_sin_p1_noq_trecipe_con_h24.lua",
        "seed_2_both_recipe_vin_sin_p1_noq_trecipe_con_h12.lua",
        "seed_55_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24.lua",
        "seed_68_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24.lua",
        "seed_80_cycle_recipe_vex_sex_p1_noq_ttrapdown_coff_h48.lua",
        "seed_93_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua",
    }
    for _, f in ipairs(anchors) do FILES[#FILES + 1] = { tag = "ANCHOR", path = CORPUS .. f, name = f } end
    for _, f in ipairs(sample) do FILES[#FILES + 1] = { tag = "sample", path = CORPUS .. f, name = f } end
end

local function strip_temp(mat) return (tostring(mat):gsub("@%[.-%]", "")) end
local function solve(pp, meta)
    local state, it, vars, last, steps = "ready", nil, nil, nil, 0
    repeat
        local ok, s, i2, v = pcall(lp.solve, pp, state, it, vars, meta.tolerance, meta.iterate_limit)
        if not ok then state = "errored"; break end
        state, it = s, i2; if v then vars = v; last = v end; steps = steps + 1
    until (state ~= "ready" and state ~= "calculating") or steps > meta.step_cap
    return (last and last.x) or {}, state
end

local function run_unified(prob)
    local constraints, lines0 = prob.constraints, prob.normalized_lines
    local producible = ref.producible_set(constraints, lines0)
    local consumable = ref.consumable_set(constraints, lines0)
    local intermediates = ref.intermediates(lines0)
    local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end

    local p0 = create_problem.create_problem("u", constraints, lines0, nil, nil)
    local lines = {}
    for _, l in ipairs(lines0) do lines[#lines + 1] = l end
    for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
    local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end

    local function build(justified)
        local problem = create_problem.create_problem("u", constraints, lines0, nil, nil)
        for _, p in pairs(problem.primals) do
            if p.kind == "shortage_source" then
                if p.material and justified[strip_temp(p.material)] then p.cost = LO
                elseif producible[p.material] then p.cost = HI
                else p.cost = LO end
            elseif p.kind == "surplus_sink" then p.cost = DUMP
            elseif p.kind == "initial_source" or p.kind == "final_sink" then p.cost = 0 end
        end
        return problem
    end
    local function summarize(problem, x)
        local maxr = 0
        for k, p in pairs(problem.primals) do if p.kind == "recipe" then local a = math.abs(x[k] or 0); if a > maxr then maxr = a end end end
        local thr = math.max(1e-9, maxr * 1e-6)
        local Vp, Vf, Vc, T, nrec = 0, 0, 0, 0, 0
        local dumps = {}
        for k, p in pairs(problem.primals) do
            local v = math.abs(x[k] or 0)
            if p.kind == "recipe" and v > thr then nrec = nrec + 1 end
            if (p.kind == "elastic" or p.kind == "headroom") then T = T + v end
            if v > thr then
                if is_import(p) then if producible[p.material] then Vp = Vp + v else Vf = Vf + v end
                elseif p.kind == "surplus_sink" and consumable[p.material] then Vc = Vc + v; dumps[#dumps + 1] = { m = p.material, v = v } end
            end
        end
        table.sort(dumps, function(a, b) return a.v > b.v end)
        return { Vp = Vp, Vf = Vf, Vc = Vc, T = T, nrec = nrec, dumps = dumps, thr = thr, total = Vp + Vf + Vc }
    end
    local function consumed_of(x)
        local consumed = {}
        for _, line in ipairs(lines) do
            local xr = x[rkey(line)] or 0
            if xr > 1e-9 then for _, ing in ipairs(line.ingredients or {}) do local m = tn.typed_name_to_variable_name(ing); consumed[m] = (consumed[m] or 0) + xr * (ing.amount_per_second or 0) end end
        end
        return consumed
    end
    -- co-product Qs of recipes that produce a dumped material (the dump-forcing fabrications)
    local function cand_set(cur, justified)
        local consumed = consumed_of(cur.x)
        local set = {}
        for _, d in ipairs(cur.dumps) do
            for _, line in ipairs(lines) do
                local xr = cur.x[rkey(line)] or 0
                if xr > cur.thr then
                    local makes_d = false
                    for _, pr in ipairs(line.products or {}) do if tn.typed_name_to_variable_name(pr) == d.m then makes_d = true end end
                    if makes_d then for _, pr in ipairs(line.products or {}) do
                        local m = tn.typed_name_to_variable_name(pr)
                        local bm = strip_temp(m)
                        if m ~= d.m and producible[m] and (consumed[m] or 0) > 0 and not justified[bm] then set[bm] = true end
                    end end
                end
            end
        end
        return set
    end
    local function evaluate(justified)
        local problem = build(justified)
        local x = solve(problem, prob.meta)
        local s = summarize(problem, x); s.x = x
        return s
    end

    local justified, names = {}, {}
    local bsol = evaluate(justified)
    local cur = bsol
    for _ = 1, ROUNDS do
        local cands = cand_set(cur, justified)
        local best
        for bm in pairs(cands) do
            local trial = {}; for k in pairs(justified) do trial[k] = true end; trial[bm] = true
            local res = evaluate(trial)
            if res.total < cur.total - 1e-6 and res.nrec >= 0.5 * bsol.nrec and res.T <= DUST then
                if not best or res.total < best.res.total then best = { bm = bm, res = res } end
            end
        end
        if not best then break end
        justified[best.bm] = true; names[#names + 1] = best.bm; cur = best.res
    end
    cur.base_total, cur.base_nrec = bsol.total, bsol.nrec
    cur.justified = names
    return cur
end

local function ref_recipes(r)
    local maxr = 0
    for k, p in pairs(r.problem.primals) do if p.kind == "recipe" then local a = math.abs(r.x[k] or 0); if a > maxr then maxr = a end end end
    local thr = math.max(1e-9, maxr * 1e-6)
    local n = 0
    for k, p in pairs(r.problem.primals) do if p.kind == "recipe" and math.abs(r.x[k] or 0) > thr then n = n + 1 end end
    return n
end

io.write(string.format("======= UNIFIED FIXPOINT (min total, block clean imports)  HI=%g DUMP=%g LO=%g =======\n", HI, DUMP, LO))
io.write(string.format("%-48s | ref(tot rec) | base(tot rec) | unified(tot rec) justified | verdict\n", "case"))
local n_improve, n_same, n_worse, n_collapse = 0, 0, 0, 0
for _, f in ipairs(FILES) do
    local ok, err = pcall(function()
        local prob = assert(problem_dump.load_problem(f.path))
        local r = ref.solve_reference(prob.constraints, prob.normalized_lines)
        if r.state ~= "finished" then io.write(string.format("%-48s | ref state=%s -- skip\n", f.name:gsub("%.lua$", ""), r.state)); return end
        r.total = r.Vp + r.Vf + r.Vc
        local rrec = ref_recipes(r)
        local g = run_unified(prob)
        local gt = g.total < DUST and 0 or g.total
        local rt = r.total < DUST and 0 or r.total
        local collapsed = (g.T > DUST and r.T <= DUST) or (rrec > 0 and g.nrec < 0.5 * rrec)
        local verdict
        if collapsed then verdict = "COLLAPSE"; n_collapse = n_collapse + 1
        elseif gt == 0 and rt == 0 then verdict = "same(clean)"; n_same = n_same + 1
        elseif gt < rt - DUST then verdict = string.format("IMPROVE %.3gx", rt / math.max(gt, DUST)); n_improve = n_improve + 1
        elseif gt > rt + DUST then verdict = "WORSE"; n_worse = n_worse + 1
        else verdict = "same"; n_same = n_same + 1 end
        io.write(string.format("%-48s | %-9.5g r%-2d | %-9.5g r%-2d | %-9.5g r%-2d {%s} | %s\n",
            (f.tag == "ANCHOR" and "* " or "  ") .. f.name:gsub("%.lua$", ""):gsub("_p1_noq", ""),
            r.total, rrec, g.base_total, g.base_nrec, g.total, g.nrec, table.concat(g.justified, ","), verdict))
    end)
    if not ok then io.write(string.format("%-48s | ERROR %s\n", f.name, tostring(err):sub(1, 70))) end
end
io.write(string.format("\nsummary (dust-floored): improve=%d same=%d worse=%d collapse=%d\n", n_improve, n_same, n_worse, n_collapse))
