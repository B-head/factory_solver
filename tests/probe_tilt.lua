-- probe_tilt: iterative escape-cost tilt on ONE explorer-dumped problem. The
-- "adjust a failing case's costs one step at a time and watch the solution move"
-- loop, automated. Two opposite directions:
--
--   --lower (default): each iteration, HALVE the cost of every shortage_source /
--     surplus_sink that is currently ZERO (parked). An escape that has EVER carried
--     flow is frozen forever (never halved again) -- without that freeze, cheapening
--     a zero escape makes it attractive, it gets adopted, then keeps getting cheaper
--     and the solution ping-pongs. (Tests "can making unused escapes cheap pull the
--     LP off the cheat" -- on this corpus it does not; it only sheds recipes.)
--
--   --raise: each iteration, DOUBLE the cost of every ACTIVE escape, capped just
--     below the target-relaxation (|elastic|) cost so an UNAVOIDABLE escape is not
--     driven so high the LP relaxes the target (which collapses the factory). An
--     escape that stays active despite a raise has no recipe alternative -> frozen
--     as unavoidable. (Tests "can penalising import/dump make the LP build real
--     recipes" -- here the load-bearing escapes are price-insensitive, so it can't.)
--
-- GOAL is maximise ACTIVE (non-parked) recipes; cheat (import/dump) is NEUTRAL, not
-- a failure. Stop on: every recipe active / active-count plateau / nothing left to
-- tilt / iteration cap.
--
-- Usage (from repo root):  lua tests/probe_tilt.lua <problem-file> [--raise]

require "tests/headless_env"
local R = require "tests/research_lib"

local MAXIT = 60
local PATIENCE = 8
local COST_FLOOR = 1e-12 -- halving below this is meaningless (--lower)

local path, raise = nil, false
for i = 1, #arg do
    if arg[i] == "--raise" then raise = true
    elseif arg[i] == "--lower" then raise = false
    else path = path or arg[i] end
end
if not path then io.stderr:write("usage: probe_tilt.lua <problem-file> [--raise]\n"); os.exit(2) end
local prob = R.load(path)
local meta = prob.meta

-- Persistent escape-cost overrides (key -> cost), applied to every fresh build so
-- the tilt ACCUMULATES across iterations rather than resetting to the defaults.
local overrides = {}
local function build_solve()
    local problem = R.build(prob)
    for k, c in pairs(overrides) do
        if problem.primals[k] then problem.primals[k].cost = c end
    end
    local state, steps, vars = R.solve(problem, meta)
    return problem, state, steps, vars
end

-- For --raise: cap raises just below the cheapest target-relaxation cost, so a
-- shortage is never made so dear the LP would rather relax the target.
local cap = math.huge
if raise then
    local base = R.build(prob)
    local min_elastic = math.huge
    for _, p in pairs(base.primals) do
        if p.kind == "elastic" and p.cost < min_elastic then min_elastic = p.cost end
    end
    if min_elastic < math.huge then cap = min_elastic / 2 end
end

local ever_used = {}          -- (--lower) escapes that ever carried flow -> frozen
local last_raise_value = {}   -- (--raise) value when last raised, to detect non-response
local frozen = {}             -- (--raise) escapes proven unavoidable -> frozen

print("# problem: " .. path)
print(("# seed=%s tgt=%s   mode=%s%s")
    :format(tostring(meta.seed), tostring(meta.target_label),
        raise and "RAISE active escapes (x2)" or "LOWER zero escapes (/2)",
        raise and ("  cap=" .. string.format("%.4g", cap)) or ""))
print("# GOAL = maximise active (non-parked) recipes; cheat is NEUTRAL.")
print("")
print("iter state      steps  active/total parked  cheat        n_esc tilted frozen")

local best_active, stall, it = -1, 0, 0
local final_reason, final
while true do
    it = it + 1
    local problem, state, steps, vars = build_solve()
    local thresh = R.park_threshold(vars, problem.primals)
    local d = R.detect(vars, problem.primals)

    -- count active escapes (neutral context)
    local n_esc = 0
    for k, v in pairs(R.escape_vec(vars, problem.primals)) do if v > thresh then n_esc = n_esc + 1 end end

    -- choose + apply the tilt for this iteration
    local tilted = 0
    local any_target = false
    for k, p in pairs(problem.primals) do
        if R.is_escape(problem.primals, k) then
            local a = math.abs((vars.x and vars.x[k]) or 0)
            local active = a > thresh
            if raise then
                if active and not frozen[k] then
                    local prev = last_raise_value[k]
                    if (prev and a >= prev * 0.9) or p.cost >= cap then
                        frozen[k] = true -- raising didn't move it (or hit cap) = unavoidable
                    else
                        any_target = true
                        overrides[k] = math.min(p.cost * 2, cap)
                        last_raise_value[k] = a
                        tilted = tilted + 1
                    end
                end
            else
                if active then ever_used[k] = true end
                if not active and not ever_used[k] then
                    any_target = true
                    if p.cost > COST_FLOOR then overrides[k] = p.cost / 2; tilted = tilted + 1 end
                end
            end
        end
    end
    local n_frozen = 0
    for _ in pairs(raise and frozen or ever_used) do n_frozen = n_frozen + 1 end

    print(("%-4d %-10s %-5d %-12s %-7d %-12.6g %-5d %-6d %d")
        :format(it, state, steps, ("%d/%d"):format(d.active, d.recipes), d.near_zero,
            d.cheat, n_esc, tilted, n_frozen))
    final = { it = it, active = d.active, recipes = d.recipes, parked = d.near_zero, cheat = d.cheat }

    if state == "finished" and d.near_zero == 0 then
        final_reason = "GOAL (all placed recipes active)"; break
    end
    if d.active > best_active then best_active = d.active; stall = 0 else stall = stall + 1 end
    if stall >= PATIENCE then
        final_reason = ("NO IMPROVEMENT (active-count plateau %d iters; best=%d)"):format(PATIENCE, best_active); break
    end
    if not any_target or tilted == 0 then
        final_reason = "NOTHING LEFT (no eligible escapes to tilt)"; break
    end
    if it >= MAXIT then final_reason = ("MAXIT (%d); best active=%d"):format(MAXIT, best_active); break end
end

print("")
print("# stop: " .. final_reason)
print(("# final active=%d/%d (parked=%d); best active seen=%d; cheat(neutral)=%.6g")
    :format(final.active, final.recipes, final.parked, math.max(best_active, final.active), final.cheat))
