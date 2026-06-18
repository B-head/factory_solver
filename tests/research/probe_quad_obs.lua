---@diagnostic disable: undefined-global
-- OBSERVATION (not a verdict): solve a corpus problem under a clean QP framing --
--   * every user target -> a NON-elastic hard EQUALITY at a large RHS (the
--     elastic/headroom escape + its inequality slacks are stripped, so the
--     constraint dual becomes "production == BIG" with no relaxation);
--   * every source/sink escape (initial_source, shortage_source, surplus_sink,
--     final_sink) -> a uniform separable convex quadratic cost: linear cost 0,
--     objective contribution (QUAD/2)*x^2 each (QUAD=2 => exactly 1*x^2). Because
--     the coefficient is uniform, the constant factor does not change the argmin.
--
-- Recipe/bridge costs are left untouched (the tiny recipe_epsilon tie-break that
-- canonicalizes degenerate flow routings; negligible next to the quadratic at a
-- large target). We DRIVE the IPM ourselves and retain the last non-nil iterate
-- so the values are observable even when the solve does not converge.
--
--   luajit tests/research/probe_quad_obs.lua [dumpfile] [BIG] [QUAD]

require "tests/headless_env"

local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local tn = require "manage/typed_name"
local vk = require "solver/var_key"
local lp = require "solver/linear_programming"

local PATH = arg[1] or "S:/tmp/explore_problems/seed_143_cycle_scc_vex_sex_p1_noq_trecipe_con_h72_cyconly.lua"
local BIG = tonumber(arg[2]) or 1e6  -- hard-equality target RHS
local QUAD = tonumber(arg[3]) or 2   -- per source/sink objective = (QUAD/2)*x^2; QUAD=2 -> 1*x^2
local MODE = arg[4] or "quad"        -- "quad" => (QUAD/2)*x^2 convex ; "linear" => LIN*x linear
local LIN = tonumber(arg[5]) or 1    -- linear cost coefficient when MODE == "linear"

local SOURCE = { initial_source = true, shortage_source = true }   -- for grouping/report
local SINK = { surplus_sink = true, final_sink = true }            -- for grouping/report
-- Which escape kinds receive the uniform convex quadratic cost.
local QUAD_KINDS = { shortage_source = true, surplus_sink = true }
-- Escape kinds made fully FREE (linear 0 AND quadratic 0). This run zeroes the
-- quadratic on initial_source / final_sink per the follow-up request.
local FREE_KINDS = { initial_source = true, final_sink = true }

local prob = assert(problem_dump.load_problem(PATH), "load failed: " .. PATH)
local problem = create_problem.create_problem("quad_obs", prob.constraints, prob.normalized_lines, nil, nil)

-- (1) Cost the escapes. QUAD_KINDS: MODE "quad" -> uniform convex quadratic
-- (linear 0, quad QUAD); MODE "linear" -> uniform linear cost LIN (quad 0).
-- FREE_KINDS -> fully free (linear 0, quad 0) in both modes.
local nquad, nfree = 0, 0
for key, p in pairs(problem.primals) do
    if QUAD_KINDS[p.kind] then
        if MODE == "linear" then
            p.cost = LIN
        else
            p.cost = 0; problem:set_quad(key, QUAD)
        end
        nquad = nquad + 1
    elseif FREE_KINDS[p.kind] then
        p.cost = 0; problem:set_quad(key, 0); nfree = nfree + 1
    end
end

-- (2) Harden every target into a non-elastic equality at a large RHS.
local to_remove = {}
for _, c in ipairs(prob.constraints) do
    local material = tn.typed_name_to_variable_name(c)
    local dual = vk.limit(material)
    local d = problem.duals[dual]
    if d then d.limit = BIG end
    -- strip the relaxation escape + any inequality slacks on this constraint
    to_remove[vk.elastic(dual)] = true
    to_remove[vk.pos_slack(dual)] = true
    to_remove[vk.neg_slack(dual)] = true
end
-- defensive: catch any remaining target-relaxation primal by kind
for key, p in pairs(problem.primals) do
    if p.kind == "elastic" or p.kind == "headroom" then to_remove[key] = true end
end
local nremoved = 0
for key in pairs(to_remove) do
    if problem.primals[key] then
        problem.primals[key] = nil
        problem.subject_terms[key] = nil
        nremoved = nremoved + 1
    end
end
-- reindex primals contiguously (insertion-order indices now have gaps)
local keys = {}
for k in pairs(problem.primals) do keys[#keys + 1] = k end
table.sort(keys)
for i, k in ipairs(keys) do problem.primals[k].index = i end
problem.primal_length = #keys

-- ---- SCC identification -----------------------------------------------------
-- Strongly-connected components of the material flow graph (bridges INCLUDED,
-- since a temperature bridge is a real routing edge the LP uses). Each cyclic
-- SCC gets an id C01.. (sorted by size desc); acyclic singletons are "-".
-- Every variable is then tagged with the SCC(s) of the material(s) it touches:
-- an escape -> the SCC of its one material; a recipe/bridge -> the set of SCCs
-- of all its ingredients+products.
local mc = require "solver/material_cycles"
local scc_lines = {}
for _, l in ipairs(prob.normalized_lines) do scc_lines[#scc_lines + 1] = l end
for _, l in ipairs(problem.bridges) do scc_lines[#scc_lines + 1] = l end
local adj = mc.build_material_graph(scc_lines)
local sccs = mc.find_sccs(adj)
local cyclic = {}
for _, s in ipairs(sccs) do if mc.is_cyclic_scc(s, adj) then cyclic[#cyclic + 1] = s end end
table.sort(cyclic, function(a, b) if #a ~= #b then return #a > #b end return a[1] < b[1] end)
local mat_scc = {}   -- material var -> tag string
local scc_members = {}  -- id -> sorted member list
for i, s in ipairs(cyclic) do
    local id = string.format("C%02d", i)
    scc_members[id] = s
    for _, m in ipairs(s) do mat_scc[m] = id end
end
local function tag_of_material(m) return mat_scc[m] or "-" end
-- recipe/bridge var -> set of material vars it touches
local recipe_mats = {}
for _, l in ipairs(scc_lines) do
    local rv = tn.typed_name_to_variable_name(l.recipe_typed_name)
    local set = recipe_mats[rv] or {}
    recipe_mats[rv] = set
    for _, a in ipairs(l.ingredients) do set[tn.typed_name_to_variable_name(a)] = true end
    for _, a in ipairs(l.products) do set[tn.typed_name_to_variable_name(a)] = true end
    if l.fuel_ingredient then set[tn.typed_name_to_variable_name(l.fuel_ingredient)] = true end
    if l.fuel_burnt_result then set[tn.typed_name_to_variable_name(l.fuel_burnt_result)] = true end
end
local function tag_of_primal(key, p)
    if p.material then return tag_of_material(p.material) end  -- escape: one material
    local mats = recipe_mats[key]
    if mats then
        local seen, list = {}, {}
        for m in pairs(mats) do
            local t = tag_of_material(m)
            if not seen[t] then seen[t] = true; list[#list + 1] = t end
        end
        table.sort(list)
        return table.concat(list, ",")
    end
    return "?"
end

-- ---- drive the IPM, retaining the last non-nil iterate ----------------------
local state, iteration, vars = "ready", nil, nil
local last = nil
local steps = 0
repeat
    local ok, s, it, v = pcall(lp.solve, problem, state, iteration, vars,
        prob.meta.tolerance, prob.meta.iterate_limit)
    if not ok then state = "errored:" .. tostring(s); break end
    state, iteration = s, it
    if v ~= nil then vars = v; last = v end
    steps = steps + 1
until (state ~= "ready" and state ~= "calculating") or steps > prob.meta.step_cap

-- ---- report -----------------------------------------------------------------
local x = (last and last.x) or {}

local function group_of(kind)
    if SOURCE[kind] then return "source" end
    if SINK[kind] then return "sink" end
    if kind == "recipe" then return "recipe" end
    if kind == "bridge" then return "bridge" end
    return "other"
end

-- objective: linear (cost*|x|) + quadratic (QUAD/2 * x^2)
local lin_obj, quad_obj = 0, 0
local mass = { source = 0, sink = 0, recipe = 0, bridge = 0, other = 0 }
for key, p in pairs(problem.primals) do
    local v = x[key] or 0
    lin_obj = lin_obj + (p.cost or 0) * math.abs(v)
    if p.quad and p.quad ~= 0 then quad_obj = quad_obj + 0.5 * p.quad * v * v end
    mass[group_of(p.kind)] = mass[group_of(p.kind)] + math.abs(v)
end

io.write("================ QP OBSERVATION ================\n")
io.write(string.format("file              : %s\n", (PATH:match("([^/\\]+)%.lua$") or PATH)))
io.write(string.format("BIG (target RHS)  : %.17g\n", BIG))
if MODE == "linear" then
    io.write(string.format("MODE              : LINEAR   (per escape cost = %g * x)\n", LIN))
else
    io.write(string.format("MODE              : QUAD     (per escape objective = %g * x^2)\n", QUAD / 2))
end
io.write(string.format("costed escapes    : %d (shortage_source+surplus_sink)\n", nquad))
io.write(string.format("made fully free   : %d escapes (initial_source+final_sink, linear=0 quad=0)\n", nfree))
io.write(string.format("target primals stripped (elastic/headroom/slack): %d\n", nremoved))
io.write(string.format("primals=%d duals=%d  has_quad=%s\n",
    problem.primal_length, problem.dual_length, tostring(problem.has_quad)))
io.write(string.format("solve state=%s  steps=%d  (tol=%g iter_limit=%d)\n",
    state, steps, prob.meta.tolerance, prob.meta.iterate_limit))
io.write(string.format("objective         : linear=%.10g  quadratic=%.10g  total=%.10g\n",
    lin_obj, quad_obj, lin_obj + quad_obj))
io.write(string.format("mass by group     : source=%.6g sink=%.6g recipe=%.6g bridge=%.6g other=%.6g\n",
    mass.source, mass.sink, mass.recipe, mass.bridge, mass.other))

-- ---- SCC summary ------------------------------------------------------------
-- Per cyclic SCC: member count + members, and the escape mass attached to it
-- (raw sums; source = initial_source+shortage_source, sink = surplus_sink+
-- final_sink). The "-" row is everything on acyclic singleton materials.
local roll = {}  -- tag -> { src=, sink=, nsrc=, nsink= }
local function bump(tag, kind, v)
    local r = roll[tag]; if not r then r = { src = 0, sink = 0, nsrc = 0, nsink = 0 }; roll[tag] = r end
    if SOURCE[kind] then r.src = r.src + math.abs(v); if math.abs(v) > 1e-9 then r.nsrc = r.nsrc + 1 end
    elseif SINK[kind] then r.sink = r.sink + math.abs(v); if math.abs(v) > 1e-9 then r.nsink = r.nsink + 1 end end
end
for key, p in pairs(problem.primals) do
    if SOURCE[p.kind] or SINK[p.kind] then bump(tag_of_material(p.material), p.kind, x[key] or 0) end
end
io.write("\n================ SCC SUMMARY ================\n")
io.write(string.format("cyclic SCCs=%d (sizes shown), acyclic singletons tagged \"-\"\n", #cyclic))
io.write("  id    size  attached_escapes(active>1e-9)         escape_mass(|x|)\n")
local roll_order = {}
for i = 1, #cyclic do roll_order[#roll_order + 1] = string.format("C%02d", i) end
roll_order[#roll_order + 1] = "-"
for _, id in ipairs(roll_order) do
    local r = roll[id] or { src = 0, sink = 0, nsrc = 0, nsink = 0 }
    local sz = id == "-" and "" or tostring(#scc_members[id])
    io.write(string.format("  %-5s %-5s src:%-3d sink:%-3d                       src:%.6g  sink:%.6g\n",
        id, sz, r.nsrc, r.nsink, r.src, r.sink))
end
io.write("\nSCC members:\n")
for i = 1, #cyclic do
    local id = string.format("C%02d", i)
    io.write(string.format("  %s (%d): %s\n", id, #scc_members[id], table.concat(scc_members[id], ", ")))
end

-- full solution dump, grouped, every variable, full precision, SCC-tagged
local order = { "recipe", "source", "sink", "bridge", "other" }
local buckets = {}
for _, g in ipairs(order) do buckets[g] = {} end
for key, p in pairs(problem.primals) do
    local g = group_of(p.kind)
    buckets[g][#buckets[g] + 1] = { key = key, kind = p.kind, v = x[key] or 0, scc = tag_of_primal(key, p) }
end
for _, g in ipairs(order) do
    local b = buckets[g]
    table.sort(b, function(a, c) return math.abs(a.v) > math.abs(c.v) end)
    io.write(string.format("\n---- %s (%d) ----  [SCC | kind | key = value], sorted by |value| desc\n", g, #b))
    for _, e in ipairs(b) do
        io.write(string.format("  {%-10s} [%-16s] %-58s = %.17g\n", e.scc, e.kind, e.key, e.v))
    end
end

-- the target dual(s)
io.write("\n---- target constraint dual(s) ----\n")
for _, c in ipairs(prob.constraints) do
    local dual = vk.limit(tn.typed_name_to_variable_name(c))
    local d = problem.duals[dual]
    io.write(string.format("  %s  RHS=%.17g  (y=%.17g)\n", dual,
        d and d.limit or 0/0, (last and last.y and last.y[dual]) or 0))
end
