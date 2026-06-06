local tn = require "manage/typed_name"
local problem_generator = require "solver/problem_generator"
local material_cycles = require "solver/material_cycles"
local vk = require "solver/var_key"
local fs_log = require "fs_log"

local log = fs_log.for_module("solver.create_problem")

local slack_cost = 0
-- Small per-unit cost on |initial_source| (external material supply). It sits
-- well below elastic_cost, so it never competes with the shortage/surplus
-- penalties or changes reachability gating, but it breaks ties between
-- recipes that produce the same product at different material efficiency:
-- the LP now prefers the chain that draws less raw input. Without it those
-- optima are degenerate and the IPM splits the flow arbitrarily.
--
-- The per-unit cost is scaled by material kind so the LP weight matches the
-- natural magnitude of one "unit": items are 1 piece, fluids are conventionally
-- 10x denser per recipe slot (vanilla writes 10 water per 1 plate), and <heat>
-- is in joules at ~10 MW scale (a heat exchanger turns 10 MJ/s of heat into
-- ~100 steam/s). Without this scaling, source_cost on <heat> alone would
-- dominate the objective by seven orders of magnitude and the LP collapses
-- to the all-zero solution whenever heat is sourced externally.
local source_cost_item = 1
local source_cost_fluid = 0.1
local source_cost_heat = 100 / 10e6
local elastic_cost = 2 ^ 10
local target_cost = 2 ^ 20

---@param variable_name string
---@return number
local function source_cost_for(variable_name)
    local kind = vk.source_cost_kind(variable_name)
    if kind == "heat" then
        return source_cost_heat
    elseif kind == "fluid" then
        return source_cost_fluid
    else
        return source_cost_item
    end
end

local M = {}

---@param line NormalizedProductionLine
---@return boolean
local function is_bridge_line(line)
    return vk.is_bridge(line.recipe_typed_name.name)
end

---A user-placed infinite source virtual recipe (manage/virtual.lua). It has no
---ingredients and emits one material, so it behaves like a declared external
---input: its recipe variable is priced at source_cost (below elastic_cost) so
---the LP draws on it freely instead of running the producer chain, while the
---zero-ingredient shape seeds reachability and suppresses the automatic
---|shortage_source| for that material. The companion <sink> recipe needs no
---special handling -- it is an ordinary free virtual recipe (slack_cost = 0)
---that consumes a material and emits nothing.
---@param line NormalizedProductionLine
---@return boolean
local function is_source_line(line)
    return vk.is_source_recipe_name(line.recipe_typed_name.name)
end

---Iterate every ingredient consumed by the line: real recipe ingredients first,
---then the burner fuel as a trailing pseudo-ingredient when present. The LP
---treats them uniformly (fuel is just another material flow); the separation
---only exists so the UI / totals can render the fuel slot apart from the
---Ingredients column.
---@param line NormalizedProductionLine
---@return fun(_: any, i: integer): integer?, NormalizedAmount?
---@return any
---@return integer
local function each_ingredient(line)
    local n = #line.ingredients
    return function(_, i)
        i = i + 1
        if i <= n then
            return i, line.ingredients[i]
        elseif i == n + 1 and line.fuel_ingredient then
            return i, line.fuel_ingredient
        end
    end, nil, 0
end

---Iterate every product the line emits: real recipe products first, then the
---fuel's burnt_result (spent fuel cell) as a trailing pseudo-product when
---present. Mirror of each_ingredient on the production side -- the LP treats
---the spent cell as just another produced material; the separation only exists
---so it bypasses quality decomposition and the UI can render it apart from the
---recipe's own products. burnt_result is always an item, so callers that filter
---on `type == "fluid"` (temperature bridges) see it as a no-op.
---@param line NormalizedProductionLine
---@return fun(_: any, i: integer): integer?, NormalizedAmount?
---@return any
---@return integer
local function each_product(line)
    local n = #line.products
    return function(_, i)
        i = i + 1
        if i <= n then
            return i, line.products[i]
        elseif i == n + 1 and line.fuel_burnt_result then
            return i, line.fuel_burnt_result
        end
    end, nil, 0
end

---For every (product_range Rp, ingredient_range Ri) pair found in the production
---line set where Rp is a strict subset of Ri, emit a zero-cost virtual recipe
---that converts the Rp fluid variable into the Ri one. The LP solves the
---otherwise-disconnected variables through these bridges (e.g. steam@[165,165]
---from a boiler feeding a generator that accepts steam@[15,1000]). A point
---temperature is the degenerate range [T,T]; an Rp that equals Ri is the same LP
---variable and needs no bridge.
---@param production_lines NormalizedProductionLine[]
---@return NormalizedProductionLine[]
function M.create_temperature_bridges(production_lines)
    local product_ranges = {}     -- fluid_name -> { "min,max" -> { min, max } }
    local ingredient_ranges = {}  -- fluid_name -> { "min,max" -> { min, max } }

    local function collect(into, name, min, max)
        local r = into[name]
        if not r then
            r = {}
            into[name] = r
        end
        r[string.format("%g,%g", min, max)] = { min, max }
    end

    for _, line in ipairs(production_lines) do
        for _, product in each_product(line) do
            if product.type == "fluid" and product.minimum_temperature then
                collect(product_ranges, product.name,
                    product.minimum_temperature, product.maximum_temperature)
            end
        end
        for _, ingredient in each_ingredient(line) do
            if ingredient.type == "fluid" and ingredient.minimum_temperature then
                collect(ingredient_ranges, ingredient.name,
                    ingredient.minimum_temperature, ingredient.maximum_temperature)
            end
        end
    end

    local fluid_names = {}
    local seen = {}
    for name, _ in pairs(product_ranges) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    for name, _ in pairs(ingredient_ranges) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    table.sort(fluid_names)

    local bridges = {}
    for _, fluid_name in ipairs(fluid_names) do
        local p = product_ranges[fluid_name]
        local i = ingredient_ranges[fluid_name]
        if p and i then
            local p_keys = {}
            for k in pairs(p) do p_keys[#p_keys + 1] = k end
            table.sort(p_keys)

            local i_keys = {}
            for k in pairs(i) do i_keys[#i_keys + 1] = k end
            table.sort(i_keys)

            for _, p_key in ipairs(p_keys) do
                local pr = p[p_key]
                local pmin, pmax = pr[1], pr[2]
                for _, i_key in ipairs(i_keys) do
                    local ir = i[i_key]
                    local imin, imax = ir[1], ir[2]
                    -- Rp strictly inside Ri: producible fluid qualifies for the
                    -- wider acceptance range. Identical ranges are the same
                    -- variable (no bridge).
                    local subset = imin <= pmin and pmax <= imax
                    local same = pmin == imin and pmax == imax
                    if subset and not same then
                        local bridge_name = vk.bridge(fluid_name, pmin, pmax, imin, imax)
                        ---@type NormalizedProductionLine
                        local bridge_line = {
                            recipe_typed_name = {
                                type = "virtual_recipe",
                                name = bridge_name,
                                quality = "normal",
                            },
                            products = { {
                                type = "fluid",
                                name = fluid_name,
                                quality = "normal",
                                minimum_temperature = imin,
                                maximum_temperature = imax,
                                amount_per_second = 1,
                            } },
                            ingredients = { {
                                type = "fluid",
                                name = fluid_name,
                                quality = "normal",
                                minimum_temperature = pmin,
                                maximum_temperature = pmax,
                                amount_per_second = 1,
                            } },
                            power_per_second = 0,
                            pollution_per_second = 0,
                        }
                        bridges[#bridges + 1] = bridge_line
                    end
                end
            end
        end
    end

    return bridges
end

---Compute the set of materials that can be produced from raw inputs
---(materials with no producer recipe in the line set) or from recipes
---with no ingredients. Materials not in this set are stuck in dead-end
---cycles and need a |shortage_source| escape hatch in the LP.
---
---`extra_seeds` lets callers inject additional seed materials (e.g. the
---deficit set from `material_cycles.find_deficit_materials`, which are
---cycle entry points that will receive a `|initial_source|` and therefore
---behave like raw inputs for reachability purposes). Without this, an
---all-in-cycle chain has an empty seed set and the BFS never fires.
---@param production_lines NormalizedProductionLine[]
---@param extra_seeds table<string, true>?
---@return table<string, true> reachable
function M.compute_reachable_materials(production_lines, extra_seeds)
    local has_producer = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, product in each_product(line) do
            has_producer[tn.typed_name_to_variable_name(product)] = true
        end
    end

    local reachable = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, ingredient in each_ingredient(line) do
            local name = tn.typed_name_to_variable_name(ingredient)
            if not has_producer[name] then
                reachable[name] = true
            end
        end
    end
    if extra_seeds then
        for name in pairs(extra_seeds) do
            reachable[name] = true
        end
    end

    local fired = {} ---@type table<integer, true>
    repeat
        local changed = false
        for i, line in ipairs(production_lines) do
            if not fired[i] then
                local all_ingredients_reachable = true
                for _, ingredient in each_ingredient(line) do
                    if not reachable[tn.typed_name_to_variable_name(ingredient)] then
                        all_ingredients_reachable = false
                        break
                    end
                end
                if all_ingredients_reachable then
                    fired[i] = true
                    for _, product in each_product(line) do
                        local name = tn.typed_name_to_variable_name(product)
                        if not reachable[name] then
                            reachable[name] = true
                            changed = true
                        end
                    end
                end
            end
        end
    until not changed

    return reachable
end

---Compute the set of recipes whose LP variables are connected (via shared
---material flows or recipe limit duals) to at least one user Constraint.
---Lines outside this set would only contribute negative-cost slack to the LP
---without any anchor pulling them back, so the IPM would push their
---variables to the clamp ceiling (2^52) and emit nonsense quantities to the
---UI. Pruning them keeps the LP tight and lets the UI gray them out.
---
---The connectivity graph mirrors the subject-term pairs create_problem
---would emit if it built the whole problem unconditionally:
---  - recipe ↔ each product / ingredient material variable
---  - recipe ↔ |limit|<material> for each product (production aggregation)
---  - recipe ↔ |limit|<bare-fluid> for each fluid product variant (only
---    on non-bridge lines, matching the bare_fluid aggregation rule)
---  - recipe ↔ |limit|<recipe> for non-bridge lines (so a Constraint that
---    pins the recipe variable itself anchors the line)
---  - <material> ↔ |limit|<material> and <material> ↔ |limit|<bare-fluid>:
---    `|initial_source|` and `|shortage_source|` always link these in the
---    actual LP (the source slack contributes to both the equivalence dual
---    and the limit aggregation), so a bare-fluid Constraint must be able
---    to reach a consumer-only recipe that has no direct |limit| edge.
---@param all_lines NormalizedProductionLine[]
---@param constraints Constraint[]
---@return table<integer, true> active_line_indices Indices into `all_lines`.
---@return table<string, true> inactive_recipe_variables Recipe variable names of inactive lines (includes bridges).
function M.compute_active_lines(all_lines, constraints)
    local adjacency = {} ---@type table<string, table<string, true>>
    local function link(a, b)
        local sa = adjacency[a]
        if not sa then sa = {}; adjacency[a] = sa end
        sa[b] = true
        local sb = adjacency[b]
        if not sb then sb = {}; adjacency[b] = sb end
        sb[a] = true
    end

    local recipe_vars = {} ---@type string[]
    local seen_materials = {} ---@type table<string, true>
    local function touch_material(material_var)
        if seen_materials[material_var] then return end
        seen_materials[material_var] = true
        link(material_var, vk.limit(material_var))
        local bare_limit = vk.bare_fluid_limit(material_var)
        if bare_limit then
            link(material_var, bare_limit)
        end
    end

    for i, line in ipairs(all_lines) do
        local recipe_var = tn.typed_name_to_variable_name(line.recipe_typed_name)
        recipe_vars[i] = recipe_var
        local bridge = is_bridge_line(line)

        for _, value in each_product(line) do
            local material_var = tn.typed_name_to_variable_name(value)
            link(recipe_var, material_var)
            link(recipe_var, vk.limit(material_var))
            local bare_limit = vk.bare_fluid_limit(material_var)
            if bare_limit and not bridge then
                link(recipe_var, bare_limit)
            end
            touch_material(material_var)
        end
        for _, value in each_ingredient(line) do
            local material_var = tn.typed_name_to_variable_name(value)
            link(recipe_var, material_var)
            touch_material(material_var)
        end
        if not bridge then
            link(recipe_var, vk.limit(recipe_var))
        end
    end

    local visited = {} ---@type table<string, true>
    local queue = {} ---@type string[]
    for _, c in ipairs(constraints) do
        local anchor = vk.limit(tn.typed_name_to_variable_name(c))
        if not visited[anchor] then
            visited[anchor] = true
            queue[#queue + 1] = anchor
        end
    end

    local head = 1
    while head <= #queue do
        local node = queue[head]
        head = head + 1
        local neighbors = adjacency[node]
        if neighbors then
            for n, _ in pairs(neighbors) do
                if not visited[n] then
                    visited[n] = true
                    queue[#queue + 1] = n
                end
            end
        end
    end

    local active = {} ---@type table<integer, true>
    local inactive_vars = {} ---@type table<string, true>
    for i, recipe_var in ipairs(recipe_vars) do
        if visited[recipe_var] then
            active[i] = true
        else
            inactive_vars[recipe_var] = true
        end
    end
    return active, inactive_vars
end

-- Serializers below emit loadable Lua so an in-game solve can be captured
-- verbatim and dropped into a headless test fixture. `load()`-ing the string
-- reconstructs the exact NormalizedProductionLine[] / Constraint[] create_problem
-- received, which matters for reachability work where the active/inactive line
-- split and the precise per-second amounts decide the LP shape. %.17g keeps the
-- round-trip lossless; %q keeps names/qualities valid under any future escaping.

---@param n number
---@return string
local function num_literal(n)
    return string.format("%.17g", n)
end

---@param amount NormalizedAmount
---@return string
local function amount_literal(amount)
    local parts = {
        string.format("type = %q", amount.type),
        string.format("name = %q", amount.name),
        string.format("quality = %q", amount.quality),
        "amount_per_second = " .. num_literal(amount.amount_per_second),
    }
    if amount.minimum_temperature ~= nil then
        parts[#parts + 1] = "minimum_temperature = " .. num_literal(amount.minimum_temperature)
    end
    if amount.maximum_temperature ~= nil then
        parts[#parts + 1] = "maximum_temperature = " .. num_literal(amount.maximum_temperature)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

---@param amounts NormalizedAmount[]
---@param indent string
---@return string
local function amounts_literal(amounts, indent)
    if #amounts == 0 then return "{}" end
    local lines = { "{" }
    for _, a in ipairs(amounts) do
        lines[#lines + 1] = indent .. "  " .. amount_literal(a) .. ","
    end
    lines[#lines + 1] = indent .. "}"
    return table.concat(lines, "\n")
end

---Serialize NormalizedProductionLine[] to a `load()`-able Lua chunk that
---`return`s an equivalent array. See the serializer note above.
---@param production_lines NormalizedProductionLine[]
---@return string
function M.dump_normalized_lines(production_lines)
    local out = { "return {" }
    for _, line in ipairs(production_lines) do
        local rtn = line.recipe_typed_name
        out[#out + 1] = "  {"
        out[#out + 1] = string.format(
            "    recipe_typed_name = { type = %q, name = %q, quality = %q },",
            rtn.type, rtn.name, rtn.quality)
        out[#out + 1] = "    products = " .. amounts_literal(line.products, "    ") .. ","
        out[#out + 1] = "    ingredients = " .. amounts_literal(line.ingredients, "    ") .. ","
        if line.fuel_ingredient then
            out[#out + 1] = "    fuel_ingredient = " .. amount_literal(line.fuel_ingredient) .. ","
        end
        if line.fuel_burnt_result then
            out[#out + 1] = "    fuel_burnt_result = " .. amount_literal(line.fuel_burnt_result) .. ","
        end
        out[#out + 1] = "    power_per_second = " .. num_literal(line.power_per_second) .. ","
        out[#out + 1] = "    pollution_per_second = " .. num_literal(line.pollution_per_second) .. ","
        out[#out + 1] = "  },"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

---Serialize Constraint[] to a `load()`-able Lua chunk. Paired with
---dump_normalized_lines, this captures the full create_problem input.
---@param constraints Constraint[]
---@return string
function M.dump_constraints(constraints)
    local out = { "return {" }
    for _, c in ipairs(constraints) do
        local parts = {
            string.format("type = %q", c.type),
            string.format("name = %q", c.name),
            string.format("quality = %q", c.quality),
            string.format("limit_type = %q", c.limit_type),
            "limit_amount_per_second = " .. num_literal(c.limit_amount_per_second),
        }
        if c.minimum_temperature ~= nil then
            parts[#parts + 1] = "minimum_temperature = " .. num_literal(c.minimum_temperature)
        end
        if c.maximum_temperature ~= nil then
            parts[#parts + 1] = "maximum_temperature = " .. num_literal(c.maximum_temperature)
        end
        out[#out + 1] = "  { " .. table.concat(parts, ", ") .. " },"
    end
    out[#out + 1] = "}"
    return table.concat(out, "\n")
end

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@param forced_imports table<string, true>?  Material variable names to seed as |initial_source| imports when unreachable (in addition to the heuristic deficits). The diagnose-then-reclassify pass fills this with the AVOIDABLE cheats from a first solve (see M.diagnose_avoidable_cheats). nil leaves behaviour unchanged.
---@return Problem
function M.create_problem(solution_name, constraints, production_lines, forced_imports)
    local problem = problem_generator.new(solution_name)

    -- The constraints + normalized lines are the minimal data needed to replay
    -- this in-game solve as a headless fixture, so they log at debug (the bulky
    -- LP internals -- cost/limit/subject/primal -- sit one level lower at trace).
    -- Guarded because the dumps build O(lines) strings eagerly: fs_log args are
    -- evaluated by the caller even when the level would filter the emit. Enable
    -- with `/factory-solver-log-level debug` (or trace for the LP internals too).
    if fs_log.is_enabled("debug") then
        log.debug("-- create_problem input '%s' --", solution_name)
        log.debug("constraints:\n%s", M.dump_constraints(constraints))
        log.debug("normalized lines:\n%s", M.dump_normalized_lines(production_lines))
    end

    local bridges = M.create_temperature_bridges(production_lines)
    -- Bridges are not part of solution.production_lines but their flows do
    -- need to net out in the Final Products / Basic Ingredients panels.
    -- Attach the structured bridge lines so report.get_total_amounts can fold
    -- the LP-solved flows back in without parsing variable-name strings.
    problem.bridges = bridges
    -- Consumer-side acceptance-range fluid variables exist only as bridge
    -- targets: a real recipe product always carries a point temperature
    -- (raw_product_to_amount / resolve_bare_fluid_product give min == max), so
    -- the only thing that ever credits a range variable (min ~= max) is a
    -- temperature bridge. Physically the factory emits fluid at a definite
    -- temperature, never "a range", so a range variable must never carry a
    -- surplus. Collect these so the surplus_sink loop below can deny them an
    -- elastic over-production sink (see the comment there).
    local bridge_target_variables = {} ---@type table<string, true>
    for _, bridge in ipairs(bridges) do
        for _, product in ipairs(bridge.products) do
            bridge_target_variables[tn.typed_name_to_variable_name(product)] = true
        end
    end
    local all_lines = {}
    for _, line in ipairs(production_lines) do all_lines[#all_lines + 1] = line end
    for _, line in ipairs(bridges) do all_lines[#all_lines + 1] = line end

    local active_line_indices, inactive_recipe_variables = M.compute_active_lines(all_lines, constraints)
    problem.inactive_recipe_variables = inactive_recipe_variables

    -- Materials the user pinned with a Constraint. A pinned material is a
    -- genuine requested output even when an in-set recipe also consumes it, so
    -- the produced+consumed branch below grants it a |final_sink| it would
    -- otherwise only get as a terminal product -- otherwise the LP produces the
    -- pinned amount only to dump it all back through the penalised
    -- |surplus_sink|, and nothing actually leaves the factory.
    local constrained_materials = {} ---@type table<string, true>
    for _, c in ipairs(constraints) do
        constrained_materials[tn.typed_name_to_variable_name(c)] = true
    end

    -- Identify cycle materials that need external supply and seed reachability
    -- with them, so the |initial_source| we add downstream behaves like a raw
    -- input. Filter to materials not already reachable through the open
    -- boundary -- an iron-ore that already has a mining recipe doesn't need
    -- a second free supply line just because it also participates in a cycle.
    local pre_reachable = M.compute_reachable_materials(all_lines)
    local raw_deficits, _, seed_candidates = material_cycles.find_deficit_materials(all_lines)
    local deficits = {} ---@type table<string, true>
    for name in pairs(raw_deficits) do
        if not pre_reachable[name] then deficits[name] = true end
    end

    -- Diagnose-then-reclassify imports. A first solve found these materials
    -- being fabricated via |shortage_source| even though their recipe set CAN
    -- produce them (export_feasible) -- an AVOIDABLE cheat the cost tiers
    -- preferred over an inefficient real chain. Seed them so they get an
    -- |initial_source| import (and become reachability seeds), which prices in
    -- well below the shortage penalty so the second solve runs the chain or
    -- imports cheaply instead of fabricating. Unavoidable cheats (a material no
    -- flow can produce) are never put here and keep their escape hatch. Filtered
    -- to unreachable names for the same reason as the heuristic deficits.
    if forced_imports then
        for name in pairs(forced_imports) do
            if not pre_reachable[name] then deficits[name] = true end
        end
    end

    local reachable = M.compute_reachable_materials(all_lines, deficits)

    -- Catalyst-loop closure (purely additive over the mass-losing deficits
    -- above). A closed catalyst cycle turns on materials the net-flow heuristic
    -- cannot flag -- net-zero catalysts (sb-oxide in the antimony purex loop),
    -- or self-sustaining loops that still cannot bootstrap from zero (the
    -- limestone slacked-lime cycle, the tuuphra biological loop). Their
    -- materials stay unreachable even after the deficits are seeded, so the LP
    -- falls back to |shortage_source| to fabricate the demanded product. Seed
    -- the still-unreachable primer candidates one at a time, recomputing
    -- reachability after each, so we never add a seed a previous one already
    -- unblocked (the chicken-and-egg pair only needs one primer; the quality
    -- cascade's downstream tiers become reachable on their own and are never
    -- seeded). Cases that already reach their whole chain skip this loop
    -- entirely -- there is nothing left unreachable to pick.
    while true do
        local pick = nil
        for name in pairs(seed_candidates) do
            if not reachable[name] and not deficits[name]
                and (not pick or name < pick) then
                pick = name
            end
        end
        if not pick then break end
        deficits[pick] = true
        reachable = M.compute_reachable_materials(all_lines, deficits)
    end

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for i, line in ipairs(all_lines) do
        if not active_line_indices[i] then
            goto continue_line
        end
        local objective_name = tn.typed_name_to_variable_name(line.recipe_typed_name)
        local bridge = is_bridge_line(line)

        for _, value in each_product(line) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_products[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, amount)
            problem:add_subject_term(objective_name, vk.limit(constraint_name), amount)

            -- Skip bridges from the bare-fluid aggregation: a bridge re-labels
            -- single-T flow as range-T (or vice versa) without creating any new
            -- fluid, so counting both the boiler's steam@165 product and the
            -- bridge's steam@[15,1000] product would double the bare-fluid total.
            local bare_limit = vk.bare_fluid_limit(constraint_name)
            if bare_limit and not bridge then
                problem:add_subject_term(objective_name, bare_limit, amount)
            end
        end

        for _, value in each_ingredient(line) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_ingresients[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, -amount)
        end

        if bridge then
            problem:add_objective(objective_name, slack_cost, false)
        else
            -- A user source recipe is priced at source_cost on its product so
            -- the LP treats it like a declared external input rather than a
            -- free fountain. Sinks (and every other virtual recipe) stay at
            -- slack_cost = 0.
            local recipe_cost = slack_cost
            if is_source_line(line) and line.products[1] then
                recipe_cost = source_cost_for(tn.typed_name_to_variable_name(line.products[1]))
            end
            problem:add_objective(objective_name, recipe_cost, true)
            problem:add_subject_term(objective_name, vk.limit(objective_name), 1)
        end
        ::continue_line::
    end

    for constraint_name, _ in pairs(included_products) do
        if not included_ingresients[constraint_name] then
            goto continue
        end
        included_products[constraint_name] = nil
        included_ingresients[constraint_name] = nil

        problem:add_equivalence_constraint(constraint_name, 0)

        -- A bridge-target range variable gets no surplus_sink. Otherwise the LP
        -- is indifferent between leaving over-production on the producer's point
        -- variable or on the consumer's range variable (both priced at
        -- elastic_cost), and the interior-point solver centers the surplus
        -- across both -- leaking a range temperature ("15-100") into Final
        -- Products even though fluid physically leaves at a single temperature.
        -- Denying the range an over-production sink forces the bridge flow to
        -- equal consumption exactly, so every surplus stays on the physical
        -- point variable (which keeps its own surplus_sink as a category-1
        -- producer/consumer). Underproduction is still relaxed by the
        -- shortage_source / initial_source escape hatches added below.
        if not bridge_target_variables[constraint_name] then
            local elastic_name = vk.surplus_sink(constraint_name)
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, -1)
        end
        -- A user-pinned material ships through a free |final_sink| even though
        -- it is also consumed in-set: it is a requested output, not waste. The
        -- terminal-product loop below only reaches materials that are never an
        -- ingredient, so without this a pinned intermediate would have nowhere
        -- to leave except the penalised |surplus_sink| and the solution would
        -- make the pinned amount only to dump all of it back. A bridge-target
        -- range variable is excluded for the same reason it gets no surplus_sink
        -- above: it is a synthetic temperature relabelling, not a fluid that
        -- physically leaves the factory, so letting it final_sink would drain a
        -- range-constrained chain straight out instead of through its consumer.
        if constrained_materials[constraint_name]
            and not bridge_target_variables[constraint_name] then
            local final_name = vk.final_sink(constraint_name)
            problem:add_objective(final_name, slack_cost)
            problem:add_subject_term(final_name, constraint_name, -1)
        end
        -- Cycle entry points identified by find_deficit_materials get a
        -- |initial_source| at source_cost: they are the natural external
        -- inputs of the cycle (think cu/normal + ir/normal in a quality
        -- recycling chain with no copper / iron producer registered).
        -- Without this, an all-in-cycle chain has no way to start and the
        -- LP would have to lean on |shortage_source| at penalty cost,
        -- producing solutions that look "OK" numerically but hide the
        -- external input behind the slack-vs-source distinction. source_cost
        -- is far below elastic_cost so the shortage gate is unaffected.
        if deficits[constraint_name] then
            local slack_name = vk.initial_source(constraint_name)
            problem:add_objective(slack_name, source_cost_for(constraint_name))
            problem:add_subject_term(slack_name, constraint_name, 1)
            problem:add_subject_term(slack_name, vk.limit(constraint_name), 1)

            local bare_limit = vk.bare_fluid_limit(constraint_name)
            if bare_limit then
                problem:add_subject_term(slack_name, bare_limit, 1)
            end
        elseif not reachable[constraint_name] then
            -- |shortage_source| is gated on reachability: materials reachable
            -- from raw inputs (or promoted deficits) must run their producer
            -- chain. Without this gating the LP would pay elastic_cost to
            -- fabricate intermediates rather than run long recycling chains
            -- (e.g. Fulgora scrap), which produces wrong solutions. Materials
            -- stuck in dead-end cycles that the deficit heuristic did not
            -- catch (mass-losing loops with no external input) keep the
            -- escape hatch — otherwise the LP can only return all-zero.
            local elastic_name = vk.shortage_source(constraint_name)
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
            problem:add_subject_term(elastic_name, vk.limit(constraint_name), 1)

            local bare_limit = vk.bare_fluid_limit(constraint_name)
            if bare_limit then
                problem:add_subject_term(elastic_name, bare_limit, 1)
            end
        end
        ::continue::
    end

    for constraint_name, _ in pairs(included_products) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = vk.final_sink(constraint_name)
        problem:add_objective(slack_name, slack_cost)
        problem:add_subject_term(slack_name, constraint_name, -1)
    end

    for constraint_name, _ in pairs(included_ingresients) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = vk.initial_source(constraint_name)
        problem:add_objective(slack_name, source_cost_for(constraint_name))
        problem:add_subject_term(slack_name, constraint_name, 1)
        problem:add_subject_term(slack_name, vk.limit(constraint_name), 1)

        local bare_limit = vk.bare_fluid_limit(constraint_name)
        if bare_limit then
            problem:add_subject_term(slack_name, bare_limit, 1)
        end
    end

    for _, constraint in ipairs(constraints) do
        local constraint_name = vk.limit(tn.typed_name_to_variable_name(constraint))
        local limit = constraint.limit_amount_per_second

        if constraint.limit_type == "upper" then
            local slack_name = problem:add_upper_limit_constraint(constraint_name, limit)
            problem:update_objective_cost(slack_name, target_cost)
        elseif constraint.limit_type == "lower" then
            problem:add_lower_limit_constraint(constraint_name, limit)

            -- target_cost (not elastic_cost) so the bound dominates the
            -- surplus_sink ledger: a producer chain that emits many
            -- unclearable by-products costs O(N) * elastic_cost per unit
            -- of target, which used to outweigh elastic_cost paid once on
            -- the bound itself. The LP would then satisfy the user's
            -- `lower` by activating the elastic and parking every recipe
            -- at zero (observed on Fulgora with electromagnetic-science-
            -- pack lower=0.5). Mirrors the target_cost slack on `upper`.
            local elastic_name = vk.elastic(constraint_name)
            problem:add_objective(elastic_name, target_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint(constraint_name, limit)

            local elastic_name = vk.elastic(constraint_name)
            problem:add_objective(elastic_name, target_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        else
            assert()
        end
    end

    return problem
end

---Diagnose the AVOIDABLE cheats in a converged solve: materials the LP
---fabricated through |shortage_source| (or relaxed a constraint on via
---|elastic|) even though their recipe set can actually produce them
---(material_cycles.export_feasible). These are the ones a second solve should
---import rather than fabricate -- the cost tiers preferred the cheap shortage
---over an inefficient but valid real chain. UNAVOIDABLE cheats (no recipe flow
---makes the material -- a fabricated dead-end intermediate, or a base resource
---only the prototype layer knows is suppliable) are left out so they keep the
---escape hatch. Feed the result back as create_problem's `forced_imports` and
---re-solve.
---
---`x` is the packed primal map (variable name -> value) from a finished solve.
---@param x table<string, number>
---@param production_lines NormalizedProductionLine[]
---@param epsilon number?  treat |x| below this as zero (default 1e-6)
---@return table<string, true> avoidable  material variable names to re-import
function M.diagnose_avoidable_cheats(x, production_lines, epsilon)
    epsilon = epsilon or 1e-6

    -- Collect the materials that carry a non-zero cheat, deduped. A shortage is
    -- keyed by the bare material; an elastic is keyed by the constraint's |limit|
    -- dual, so strip both prefixes back to the material variable name.
    local cheated = {} ---@type table<string, true>
    for name, value in pairs(x) do
        if math.abs(value) > epsilon then
            -- A shortage is keyed by the bare material; an elastic by the
            -- constraint's |limit| dual. strip_* peel both back to the material;
            -- a bare |elastic|<dual> without a |limit| body maps to no single
            -- material and returns nil from both, so it is skipped.
            local material = vk.strip_shortage(name) or vk.strip_elastic_limit(name)
            if material then
                cheated[material] = true
            end
        end
    end

    -- export_feasible must see the SAME graph create_problem solved: a cycle that
    -- closes only through a temperature bridge (the limestone slacked-lime loop,
    -- produced @[10,10] / consumed @[10,100]) is not a cycle in the bare line set,
    -- so build the bridges here too before testing.
    local all_lines = {}
    for _, line in ipairs(production_lines) do all_lines[#all_lines + 1] = line end
    for _, line in ipairs(M.create_temperature_bridges(production_lines)) do
        all_lines[#all_lines + 1] = line
    end

    local avoidable = {} ---@type table<string, true>
    for material in pairs(cheated) do
        if material_cycles.export_feasible(all_lines, material) then
            avoidable[material] = true
        end
    end
    return avoidable
end

return M
