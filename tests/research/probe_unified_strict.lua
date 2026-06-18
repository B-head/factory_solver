---@diagnostic disable: undefined-global
-- (B), corrected: STRICT reference as the base (no symmetric over-trade, so the
-- clean/anchor cases stay exactly as the reference), with a justification fixpoint
-- ON TOP: exempt a producible material's import from the Vp defeat (solve_reference
-- `exempt` arg => its import becomes free) when that material's fabrication forces a
-- dump and importing it lowers total violation without collapsing the factory.
--
-- total here counts ALL producible imports as Vp (including justified ones), so a
-- justification is only accepted when the dump it removes outweighs the import it
-- adds -- the genuine import-vs-dump comparison, applied selectively.
--
--   luajit tests/research/probe_unified_strict.lua [file ...]

require "tests/headless_env"
local ref = require "tests/research/reference_solver"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"

local CORPUS = "S:/tmp/explore_problems/"
local DUST, ROUNDS = 1e-3, 5

local FILES = {}
for i = 1, #arg do FILES[#FILES + 1] = { tag = "arg", path = arg[i], name = arg[i]:gsub(".*/", "") } end
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
        "seed_55_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24.lua",
        "seed_68_cycle_recipe_vex_sex_p1_noq_tnetneg_coff_h24.lua",
        "seed_80_cycle_recipe_vex_sex_p1_noq_ttrapdown_coff_h48.lua",
        "seed_93_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua",
    }
    for _, f in ipairs(anchors) do FILES[#FILES + 1] = { tag = "ANCHOR", path = CORPUS .. f, name = f } end
    for _, f in ipairs(sample) do FILES[#FILES + 1] = { tag = "sample", path = CORPUS .. f, name = f } end
end

local function strip_temp(mat) return (tostring(mat):gsub("@%[.-%]", "")) end

local function analyze(prob)
    local constraints, lines0 = prob.constraints, prob.normalized_lines
    local producible = ref.producible_set(constraints, lines0)
    local consumable = ref.consumable_set(constraints, lines0)
    local intermediates = ref.intermediates(lines0)
    local function is_import(p) return p.kind == "shortage_source" or (p.kind == "initial_source" and p.material and intermediates[p.material]) end

    local p0 = create_problem.create_problem("u", constraints, lines0, nil, ref.OPTS)
    local lines = {}
    for _, l in ipairs(lines0) do lines[#lines + 1] = l end
    for _, l in ipairs(p0.bridges) do lines[#lines + 1] = l end
    local function rkey(line) return tn.typed_name_to_variable_name(line.recipe_typed_name) end

    -- measure a solved reference result (Vp counts ALL producible imports)
    local function measure(r)
        local problem, x = r.problem, r.x
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
                elseif (p.kind == "surplus_sink" or p.kind == "final_sink") and consumable[p.material] then Vc = Vc + v; dumps[#dumps + 1] = { m = p.material, v = v } end
            end
        end
        table.sort(dumps, function(a, b) return a.v > b.v end)
        return { Vp = Vp, Vf = Vf, Vc = Vc, T = T, nrec = nrec, dumps = dumps, thr = thr, total = Vp + Vf + Vc, x = x, problem = problem }
    end

    -- producible co-products of running recipes that ALSO dump (the dump-forcing fabrications)
    local function candidates(m, justified)
        local consumed = {}
        for _, line in ipairs(lines) do
            local xr = m.x[rkey(line)] or 0
            if xr > 1e-9 then for _, ing in ipairs(line.ingredients or {}) do local mm = tn.typed_name_to_variable_name(ing); consumed[mm] = (consumed[mm] or 0) + xr * (ing.amount_per_second or 0) end end
        end
        local set = {}
        for _, d in ipairs(m.dumps) do
            for _, line in ipairs(lines) do
                local xr = m.x[rkey(line)] or 0
                if xr > m.thr then
                    local makes_d = false
                    for _, pr in ipairs(line.products or {}) do if tn.typed_name_to_variable_name(pr) == d.m then makes_d = true end end
                    if makes_d then for _, pr in ipairs(line.products or {}) do
                        local mm = tn.typed_name_to_variable_name(pr); local bm = strip_temp(mm)
                        if mm ~= d.m and producible[mm] and (consumed[mm] or 0) > 0 and not justified[bm] then set[bm] = true end
                    end end
                end
            end
        end
        return set
    end

    return { constraints = constraints, lines0 = lines0, measure = measure, candidates = candidates }
end

io.write("======= UNIFIED on STRICT base (justify dump-forcing producible imports) =======\n")
io.write(string.format("%-48s | strict-ref(Vp/Vc tot rec) | unified(Vp/Vc tot rec) justified | verdict\n", "case"))
local n_improve, n_same, n_worse, n_collapse = 0, 0, 0, 0
for _, f in ipairs(FILES) do
    local ok, err = pcall(function()
        local prob = assert(problem_dump.load_problem(f.path))
        local A = analyze(prob)
        local base_r = ref.solve_reference(A.constraints, A.lines0, {})
        if base_r.state ~= "finished" then io.write(string.format("%-48s | ref state=%s -- skip\n", f.name:gsub("%.lua$", ""), base_r.state)); return end
        local base = A.measure(base_r)
        local justified, names = {}, {}
        local cur = base
        for _ = 1, ROUNDS do
            local cands = A.candidates(cur, justified)
            local best
            for bm in pairs(cands) do
                local trial = {}; for k in pairs(justified) do trial[k] = true end; trial[bm] = true
                local r = ref.solve_reference(A.constraints, A.lines0, trial)
                if r.state == "finished" then
                    local m = A.measure(r)
                    if m.total < cur.total - 1e-6 and m.nrec >= 0.5 * base.nrec and m.T <= DUST then
                        if not best or m.total < best.m.total then best = { bm = bm, m = m } end
                    end
                end
            end
            if not best then break end
            justified[best.bm] = true; names[#names + 1] = best.bm; cur = best.m
        end
        local gt = cur.total < DUST and 0 or cur.total
        local rt = base.total < DUST and 0 or base.total
        local collapsed = (cur.T > DUST and base.T <= DUST) or (base.nrec > 0 and cur.nrec < 0.5 * base.nrec)
        local verdict
        if collapsed then verdict = "COLLAPSE"; n_collapse = n_collapse + 1
        elseif #names == 0 then verdict = "same(no justify)"; n_same = n_same + 1
        elseif gt < rt - DUST then verdict = string.format("IMPROVE %.3gx", rt / math.max(gt, DUST)); n_improve = n_improve + 1
        elseif gt > rt + DUST then verdict = "WORSE"; n_worse = n_worse + 1
        else verdict = "same"; n_same = n_same + 1 end
        io.write(string.format("%-48s | %6.4g/%-8.5g %-8.5g r%-2d | %6.4g/%-8.5g %-8.5g r%-2d {%s} | %s\n",
            (f.tag == "ANCHOR" and "* " or "  ") .. f.name:gsub("%.lua$", ""):gsub("_p1_noq", ""),
            base.Vp, base.Vc, base.total, base.nrec,
            cur.Vp, cur.Vc, cur.total, cur.nrec, table.concat(names, ","), verdict))
    end)
    if not ok then io.write(string.format("%-48s | ERROR %s\n", f.name, tostring(err):sub(1, 70))) end
end
io.write(string.format("\nsummary: improve=%d same=%d worse=%d collapse=%d (base = strict reference)\n", n_improve, n_same, n_worse, n_collapse))
