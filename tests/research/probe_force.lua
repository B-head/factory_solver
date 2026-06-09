-- probe_force: for ONE explorer-dumped problem, force each PARKED recipe active
-- (one at a time) and report every signal that bears on "would using this recipe
-- help" -- net escape mass, its split into baseline-active vs newly-opened, the
-- Delta-objective, and the change in active-recipe count.
--
-- This consolidates three throwaway probes from the same investigation:
--   * force_recipe_probe  (does forcing it stay feasible / raise the active count),
--   * force_recipe_relate (does it move the target boundary, and which way),
--   * check_objective     (is forcing it free (degenerate) or strictly worse).
--
-- HOW TO READ (the corpus taught these the hard way -- see research_lib header):
--   * verdict is by NET TOTAL escape mass (shortage_source + surplus_sink), the
--     only honest single number: USEFUL = net drops, WASTE = net rises, NEUTRAL =
--     ~0 (no-move or a temperature-form reshuffle that nets out).
--   * net_active (baseline-active escapes only) is shown too, because it can read
--     useful (one boundary escape down) while net_total is WASTE -- the recipe
--     relieved one import but opened bigger ones elsewhere.
--   * dObj is the LP's own yardstick. Forcing adds a constraint, so dObj >= 0
--     always: dObj~0 = a degenerate free alternative optimum (genuinely "could use
--     this recipe at no cost"), dObj>0 = correctly parked (using it costs more).
--     dObj says nothing about practicality on its own.
--   * EVERYTHING here is single-recipe = COORDINATION-BLIND. A recipe that looks
--     WASTE alone may pay off in a coalition with the parked recipes that consume
--     its by-products / supply its inputs. Treat output as a screen, not a verdict.
--
-- Usage (from repo root):  lua tests/research/probe_force.lua <problem-file>
-- Emits a human table then a machine-readable "RESULT\t..." line for run_corpus.ps1.

require "tests/headless_env"
local R = require "tests/research/research_lib"

local EPS = 0.1       -- forced minimum flow (well above a typical ~0.008 park floor)
local NET_TOL = 1e-4  -- |net total escape mass| below this = NEUTRAL (reshuffle/noise)
local MOVE_TOL = 1e-5 -- a single escape "moved" if |delta| exceeds this

local path = arg[1]
if not path then io.stderr:write("usage: probe_force.lua <problem-file>\n"); os.exit(2) end
local prob = R.load(path)

-- ---- baseline ---------------------------------------------------------------
local bproblem, bstate, _, bvars = R.build_solve(prob)
local bthresh = R.park_threshold(bvars, bproblem.primals)
local bd = R.detect(bvars, bproblem.primals)
local bobj = R.objective(bproblem, bvars)
local bvec = R.escape_vec(bvars, bproblem.primals)
local bmass = R.escape_mass(bvars, bproblem.primals, bthresh)
local base_active_esc = {} -- escapes active at baseline = the target boundary
for k, v in pairs(bvec) do if v > bthresh then base_active_esc[k] = true end end
local _, parked = R.recipe_partition(bvars, bproblem, bthresh)

print("# problem: " .. path)
print(("# seed=%s tgt=%s"):format(tostring(prob.meta.seed), tostring(prob.meta.target_label)))
print(("# baseline: state=%s active=%d/%d  obj=%.6g  escape_mass=%.6g  (force eps=%.3g)")
    :format(bstate, bd.active, bd.recipes, bobj, bmass, EPS))
print(("# parked recipes: %d   (verdict by NET TOTAL escape mass; single-recipe = coordination-blind)")
    :format(#parked))
print("")
print("parked recipe forced active                            verdict  rel? dActive net_total  net_active dObj       detail")

-- ---- per parked recipe ------------------------------------------------------
local rows = {}
for _, rk in ipairs(parked) do
    local p = R.build(prob)
    R.force_recipe(p, rk, EPS)
    local _, _, v = R.solve(p, prob.meta)
    local d = R.detect(v, p.primals)
    local vec = R.escape_vec(v, p.primals)

    local net_total, net_active = 0, 0
    local touched_active = false
    local moved_active, moved_new = {}, {}
    for k in pairs(p.primals) do
        if R.is_escape(p.primals, k) then
            local was, now = bvec[k] or 0, vec[k] or 0
            local diff = now - was
            net_total = net_total + diff
            if base_active_esc[k] then net_active = net_active + diff end
            if math.abs(diff) > MOVE_TOL then
                local label = (k:gsub("^|", ""):gsub("|", " "))
                if base_active_esc[k] then
                    touched_active = true
                    moved_active[#moved_active + 1] =
                        ("%s %s(%.3g->%.3g)"):format(diff < 0 and "DOWN" or "UP", label, was, now)
                else
                    moved_new[#moved_new + 1] = ("%s(0->%.3g)"):format(label, now)
                end
            end
        end
    end

    local verdict = (net_total < -NET_TOL and "USEFUL")
        or (net_total > NET_TOL and "WASTE") or "NEUTRAL"
    local detail = (#moved_active > 0) and table.concat(moved_active, ", ")
        or (#moved_new > 0 and table.concat(moved_new, ", ") or "(nothing moved)")
    rows[#rows + 1] = {
        rk = rk, verdict = verdict, related = touched_active,
        d_active = d.active - bd.active, net_total = net_total, net_active = net_active,
        d_obj = R.objective(p, v) - bobj, detail = detail,
    }
end

-- USEFUL first, then WASTE, then NEUTRAL; ties by name.
local order = { USEFUL = 1, WASTE = 2, NEUTRAL = 3 }
table.sort(rows, function(a, b)
    if order[a.verdict] ~= order[b.verdict] then return order[a.verdict] < order[b.verdict] end
    return a.rk < b.rk
end)
for _, r in ipairs(rows) do
    print(("%-54s %-8s %-4s %+-7d %+-10.4g %+-10.4g %+-10.4g %s")
        :format(r.rk:gsub("^recipe/", ""):gsub("^virtual_recipe/", "v:"),
            r.verdict, r.related and "R" or "-", r.d_active,
            r.net_total, r.net_active, r.d_obj, r.detail))
end

-- ---- summary + machine-readable RESULT line ---------------------------------
local cnt = { USEFUL = 0, WASTE = 0, NEUTRAL = 0 }
local useful_names = {}
for _, r in ipairs(rows) do
    cnt[r.verdict] = cnt[r.verdict] + 1
    if r.verdict == "USEFUL" then
        useful_names[#useful_names + 1] = r.rk:gsub("^recipe/", ""):gsub("^virtual_recipe/", "v:")
    end
end
print("")
print(("# summary (net-total escape mass): %d USEFUL, %d WASTE, %d NEUTRAL of %d parked")
    :format(cnt.USEFUL, cnt.WASTE, cnt.NEUTRAL, #parked))
print(("RESULT\t%s\tbaseline_active=%d\tparked=%d\tuseful=%d\twaste=%d\tneutral=%d\tuseful_recipes=%s")
    :format(R.fileid(path), bd.active, #parked, cnt.USEFUL, cnt.WASTE, cnt.NEUTRAL,
        (#useful_names > 0) and table.concat(useful_names, ",") or "-"))
