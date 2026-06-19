-- Physical SINGLE-SOLUTION dissection for headless solver RESEARCH drivers (NOT
-- the pass/fail suite).
--
-- research_lib.lua factors the BUILD / SOLVE / perturb / SCC-aggregate layer. This
-- module is its sibling on the other side: it READS a solved point -- (problem, x)
-- -- back into physical factory terms. Every "dump this solution" / "drill one
-- recipe or material" probe re-implemented the same handful of reads inline:
--   * merge the real recipe lines with create_problem's temperature bridges;
--   * label each cyclic SCC of the material graph C01.. (size desc) and tag a
--     material by it;
--   * turn solved activities x into PHYSICAL produced / consumed totals per
--     material (x * amount_per_second -- NOT the variable-space x itself, the
--     confusion CLAUDE.local.md warns about: amt_xvar 1.33 vs amt_phys 19.13);
--   * read a material's boundary escapes (import / dump / raw / final) by kind.
-- Those reads live here, once, so a new inspector is a few lines of intent.
--
-- It is a PURE READ layer: nothing here solves, and nothing mutates the Problem or
-- the shipped solver. The caller owns the (problem, x) it passes in. Like
-- research_lib these are SCREENING reads for a human, not verdicts -- a physical
-- total is what flowed in ONE solved point, not a statement about practicality
-- (which lives in the formulation, see the research_lib header caveat).
--
-- The CALLER must `require "tests/headless_env"` first (sets package.path). Reached
-- either directly (`require "tests/research/dissect"`) or via research_lib, which
-- re-exports it as `research_lib.dissect`.
--
-- Conventions matched: single M table, LuaCATS annotations referencing meta.lua.

require "tests/headless_env"

local mc = require "solver/material_cycles"
local tn = require "manage/typed_name"

local M = {}

local function vname(typed) return tn.typed_name_to_variable_name(typed) end

---The recipe-flow variable name of a production line (its key in `x` / primals).
---@param line NormalizedProductionLine
---@return string
function M.recipe_key(line)
    return vname(line.recipe_typed_name)
end

---All lines the LP actually routes flow through: the dump's real recipe lines plus
---the temperature bridges create_problem synthesised. Pass the SAME built Problem
---whose `.bridges` the caller has been using (a fresh create_problem build or the
---working one -- they carry the same bridge set for the same inputs). Returns a
---fresh array; the originals are not mutated.
---@param normalized_lines NormalizedProductionLine[]
---@param problem Problem A built Problem (only its `.bridges` is read).
---@return NormalizedProductionLine[]
function M.all_lines(normalized_lines, problem)
    local lines = {}
    for _, l in ipairs(normalized_lines) do lines[#lines + 1] = l end
    for _, l in ipairs(problem.bridges) do lines[#lines + 1] = l end
    return lines
end

---Per-line PRODUCTION coefficient of one material (sum over products, including a
---fuel_burnt_result); 0 if the line does not make it.
---@param line NormalizedProductionLine
---@param material string Material variable name.
---@return number per_second
function M.line_out(line, material)
    local s = 0
    for _, prod in ipairs(line.products or {}) do
        if vname(prod) == material then s = s + (prod.amount_per_second or 0) end
    end
    if line.fuel_burnt_result and vname(line.fuel_burnt_result) == material then
        s = s + (line.fuel_burnt_result.amount_per_second or 0)
    end
    return s
end

---Per-line CONSUMPTION coefficient of one material (sum over ingredients, including
---a fuel_ingredient); 0 if the line does not take it.
---@param line NormalizedProductionLine
---@param material string Material variable name.
---@return number per_second
function M.line_in(line, material)
    local s = 0
    for _, ing in ipairs(line.ingredients or {}) do
        if vname(ing) == material then s = s + (ing.amount_per_second or 0) end
    end
    if line.fuel_ingredient and vname(line.fuel_ingredient) == material then
        s = s + (line.fuel_ingredient.amount_per_second or 0)
    end
    return s
end

---Physical produced / consumed mass per material across a solved point: for every
---line, activity x[recipe] times each ingredient/product rate. This is the
---PHYSICAL read (flow/s), not the variable-space activities.
---
---`opts`:
---  * `fuel`  (default false) -- also count fuel_ingredient / fuel_burnt_result.
---  * `eps`   (default 0)     -- only accumulate produced/consumed for a line whose
---                              activity exceeds eps (use 1e-9 to skip parked lines).
---  * `consumers` (default false) -- also return `consumers_of[m]` = the list of
---                              { k = recipe_key, per = rate, x = activity } over
---                              EVERY line taking m (regardless of eps), for "who
---                              uses this material" readouts.
---@param lines NormalizedProductionLine[]
---@param x table<string, number> Solved activities.
---@param opts { fuel: boolean?, eps: number?, consumers: boolean? }?
---@return table<string, number> produced
---@return table<string, number> consumed
---@return table<string, { k: string, per: number, x: number }[]> consumers_of
function M.physical_flows(lines, x, opts)
    opts = opts or {}
    local fuel, eps, want_consumers = opts.fuel, opts.eps or 0, opts.consumers
    local produced, consumed, consumers_of = {}, {}, {}
    for _, line in ipairs(lines) do
        local xr = x[M.recipe_key(line)] or 0
        if want_consumers then
            for _, ing in ipairs(line.ingredients or {}) do
                local m = vname(ing)
                consumers_of[m] = consumers_of[m] or {}
                consumers_of[m][#consumers_of[m] + 1] = { k = M.recipe_key(line), per = ing.amount_per_second or 0, x = xr }
            end
        end
        if xr > eps then
            for _, ing in ipairs(line.ingredients or {}) do
                local m = vname(ing); consumed[m] = (consumed[m] or 0) + xr * (ing.amount_per_second or 0)
            end
            if fuel and line.fuel_ingredient then
                local m = vname(line.fuel_ingredient); consumed[m] = (consumed[m] or 0) + xr * (line.fuel_ingredient.amount_per_second or 0)
            end
            for _, prod in ipairs(line.products or {}) do
                local m = vname(prod); produced[m] = (produced[m] or 0) + xr * (prod.amount_per_second or 0)
            end
            if fuel and line.fuel_burnt_result then
                local m = vname(line.fuel_burnt_result); produced[m] = (produced[m] or 0) + xr * (line.fuel_burnt_result.amount_per_second or 0)
            end
        end
    end
    return produced, consumed, consumers_of
end

---Boundary escape mass per material, grouped by kind. `out[material][kind]` is the
---summed |x| of every escape primal of that material+kind whose |x| exceeds
---`thresh` (default 1e-6). Reads Primal.kind / Primal.material, never the key.
---@param primals table<string, Primal>
---@param x table<string, number>
---@param thresh number? Default 1e-6.
---@return table<string, table<string, number>>
function M.escape_by_material(primals, x, thresh)
    thresh = thresh or 1e-6
    local out = {}
    for key, p in pairs(primals) do
        if p.material then
            local v = math.abs(x[key] or 0)
            if v > thresh then
                out[p.material] = out[p.material] or {}
                out[p.material][p.kind] = (out[p.material][p.kind] or 0) + v
            end
        end
    end
    return out
end

---Recipe-relative "is this variable actually carrying flow" threshold: the largest
---recipe activity times 1e-6, floored at 1e-9. The cutoff the dump probes use to
---drop parked variables / interior dust from a listing.
---@param problem Problem
---@param x table<string, number>
---@return number
function M.solved_threshold(problem, x)
    local maxr = 0
    for k, p in pairs(problem.primals) do
        if p.kind == "recipe" then
            local a = math.abs(x[k] or 0)
            if a > maxr then maxr = a end
        end
    end
    return math.max(1e-9, maxr * 1e-6)
end

---Cyclic SCCs of the material flow graph (bridges included -- a temperature bridge
---is a routing edge the LP uses). Each cyclic SCC is labelled C01.. sorted by size
---descending (ties by first member), acyclic singletons untagged.
---
---Returns a table with:
---  * `adj`     -- the material adjacency (mc.build_material_graph), for neighbour reads.
---  * `cyclic`  -- array of member lists, in C01.. order.
---  * `tag`     -- material var -> "C##" (nil for an acyclic / untagged material).
---  * `members` -- "C##" -> member list (same arrays as `cyclic`).
---@param lines NormalizedProductionLine[]
---@return { adj: table, cyclic: string[][], tag: table<string, string>, members: table<string, string[]> }
function M.cyclic_sccs(lines)
    local adj = mc.build_material_graph(lines)
    local sccs = mc.find_sccs(adj)
    local cyclic = {}
    for _, s in ipairs(sccs) do
        if mc.is_cyclic_scc(s, adj) then cyclic[#cyclic + 1] = s end
    end
    table.sort(cyclic, function(a, b)
        if #a ~= #b then return #a > #b end
        return a[1] < b[1]
    end)
    local tag, members = {}, {}
    for i, s in ipairs(cyclic) do
        local id = string.format("C%02d", i)
        members[id] = s
        for _, m in ipairs(s) do tag[m] = id end
    end
    return { adj = adj, cyclic = cyclic, tag = tag, members = members }
end

---Set of material variable names each recipe/bridge line touches (ingredients,
---products, fuel both sides), keyed by recipe variable name. Lets an inspector tag
---a recipe by the SCCs of everything it connects, not just one material.
---@param lines NormalizedProductionLine[]
---@return table<string, table<string, true>>
function M.recipe_material_sets(lines)
    local out = {}
    for _, l in ipairs(lines) do
        local rv = M.recipe_key(l)
        local set = out[rv] or {}
        out[rv] = set
        for _, a in ipairs(l.ingredients) do set[vname(a)] = true end
        for _, a in ipairs(l.products) do set[vname(a)] = true end
        if l.fuel_ingredient then set[vname(l.fuel_ingredient)] = true end
        if l.fuel_burnt_result then set[vname(l.fuel_burnt_result)] = true end
    end
    return out
end

return M
