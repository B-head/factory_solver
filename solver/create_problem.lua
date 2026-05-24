local tn = require "manage/typed_name"
local problem_generator = require "solver/problem_generator"
local material_cycles = require "solver/material_cycles"

local slack_cost = 0
-- Small per-unit cost on |basic_source| (external material supply). It sits
-- well below elastic_cost, so it never competes with the shortage/surplus
-- penalties or changes reachability gating, but it breaks ties between
-- recipes that produce the same product at different material efficiency:
-- the LP now prefers the chain that draws less raw input. Without it those
-- optima are degenerate and the IPM splits the flow arbitrarily.
local source_cost = 1
local elastic_cost = 2 ^ 10
local target_cost = 2 ^ 20

local bridge_prefix = "|bridge|"

local M = {}

---@param line NormalizedProductionLine
---@return boolean
local function is_bridge_line(line)
    return string.sub(line.recipe_typed_name.name, 1, #bridge_prefix) == bridge_prefix
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

---For a temperature-suffixed fluid variable name ("fluid/<X>@T" / "fluid/<X>@[lo,hi]"),
---return the bare-fluid limit dual name ("|limit|fluid/<X>") so constraints on a
---temperature-agnostic fluid pick can aggregate flow across every variant.
---Constraints on temperature-specific variants keep going through their own
---"|limit|fluid/<X>@..." dual, untouched. Returns nil for non-fluid variables and
---for already-bare fluid names (no aggregation to do).
---@param variable_name string
---@return string?
local function bare_fluid_limit_dual(variable_name)
    if string.sub(variable_name, 1, 6) ~= "fluid/" then
        return nil
    end
    local at = string.find(variable_name, "@", 7, true)
    if not at then
        return nil
    end
    return "|limit|" .. string.sub(variable_name, 1, at - 1)
end

---For every (single_temperature, temperature_range) pair found in the production
---line set where the single value falls inside the range, emit a zero-cost
---virtual recipe that converts the single-temperature fluid variable into the
---range-temperature one. The LP solves the otherwise-disconnected variables
---through these bridges (e.g. steam@165 from a boiler feeding a generator that
---accepts steam@[15,1000]).
---@param production_lines NormalizedProductionLine[]
---@return NormalizedProductionLine[]
function M.create_temperature_bridges(production_lines)
    local singles = {}  -- fluid_name -> { temperature = true, ... }
    local ranges = {}   -- fluid_name -> { "min,max" -> { min, max } }

    for _, line in ipairs(production_lines) do
        for _, product in ipairs(line.products) do
            if product.type == "fluid" and product.temperature then
                local s = singles[product.name]
                if not s then
                    s = {}
                    singles[product.name] = s
                end
                s[product.temperature] = true
            end
        end
        for _, ingredient in each_ingredient(line) do
            if ingredient.type == "fluid" and ingredient.minimum_temperature then
                local r = ranges[ingredient.name]
                if not r then
                    r = {}
                    ranges[ingredient.name] = r
                end
                local key = string.format("%g,%g", ingredient.minimum_temperature, ingredient.maximum_temperature)
                r[key] = { ingredient.minimum_temperature, ingredient.maximum_temperature }
            end
        end
    end

    local fluid_names = {}
    local seen = {}
    for name, _ in pairs(singles) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    for name, _ in pairs(ranges) do
        if not seen[name] then seen[name] = true; fluid_names[#fluid_names + 1] = name end
    end
    table.sort(fluid_names)

    local bridges = {}
    for _, fluid_name in ipairs(fluid_names) do
        local s = singles[fluid_name]
        local r = ranges[fluid_name]
        if s and r then
            local single_temps = {}
            for t in pairs(s) do single_temps[#single_temps + 1] = t end
            table.sort(single_temps)

            local range_keys = {}
            for k in pairs(r) do range_keys[#range_keys + 1] = k end
            table.sort(range_keys)

            for _, temperature in ipairs(single_temps) do
                for _, range_key in ipairs(range_keys) do
                    local range = r[range_key]
                    local min, max = range[1], range[2]
                    if min <= temperature and temperature <= max then
                        local bridge_name = string.format("%sfluid/%s@%g->[%g,%g]",
                            bridge_prefix, fluid_name, temperature, min, max)
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
                                minimum_temperature = min,
                                maximum_temperature = max,
                                amount_per_second = 1,
                            } },
                            ingredients = { {
                                type = "fluid",
                                name = fluid_name,
                                quality = "normal",
                                temperature = temperature,
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
---cycle entry points that will receive a `|basic_source|` and therefore
---behave like raw inputs for reachability purposes). Without this, an
---all-in-cycle chain has an empty seed set and the BFS never fires.
---@param production_lines NormalizedProductionLine[]
---@param extra_seeds table<string, true>?
---@return table<string, true> reachable
function M.compute_reachable_materials(production_lines, extra_seeds)
    local has_producer = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, product in ipairs(line.products) do
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
                    for _, product in ipairs(line.products) do
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
---    `|basic_source|` and `|shortage_source|` always link these in the
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
        link(material_var, "|limit|" .. material_var)
        local bare_limit = bare_fluid_limit_dual(material_var)
        if bare_limit then
            link(material_var, bare_limit)
        end
    end

    for i, line in ipairs(all_lines) do
        local recipe_var = tn.typed_name_to_variable_name(line.recipe_typed_name)
        recipe_vars[i] = recipe_var
        local bridge = is_bridge_line(line)

        for _, value in ipairs(line.products) do
            local material_var = tn.typed_name_to_variable_name(value)
            link(recipe_var, material_var)
            link(recipe_var, "|limit|" .. material_var)
            local bare_limit = bare_fluid_limit_dual(material_var)
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
            link(recipe_var, "|limit|" .. recipe_var)
        end
    end

    local visited = {} ---@type table<string, true>
    local queue = {} ---@type string[]
    for _, c in ipairs(constraints) do
        local anchor = "|limit|" .. tn.typed_name_to_variable_name(c)
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

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@return Problem
function M.create_problem(solution_name, constraints, production_lines)
    local problem = problem_generator.new(solution_name)

    local bridges = M.create_temperature_bridges(production_lines)
    -- Bridges are not part of solution.production_lines but their flows do
    -- need to net out in the Final Products / Basic Ingredients panels.
    -- Attach the structured bridge lines so report.get_total_amounts can fold
    -- the LP-solved flows back in without parsing variable-name strings.
    problem.bridges = bridges
    local all_lines = {}
    for _, line in ipairs(production_lines) do all_lines[#all_lines + 1] = line end
    for _, line in ipairs(bridges) do all_lines[#all_lines + 1] = line end

    local active_line_indices, inactive_recipe_variables = M.compute_active_lines(all_lines, constraints)
    problem.inactive_recipe_variables = inactive_recipe_variables

    -- Identify cycle materials that need external supply and seed reachability
    -- with them, so the |basic_source| we add downstream behaves like a raw
    -- input. Filter to materials not already reachable through the open
    -- boundary -- an iron-ore that already has a mining recipe doesn't need
    -- a second free supply line just because it also participates in a cycle.
    local pre_reachable = M.compute_reachable_materials(all_lines)
    local raw_deficits = material_cycles.find_deficit_materials(all_lines)
    local deficits = {} ---@type table<string, true>
    for name in pairs(raw_deficits) do
        if not pre_reachable[name] then deficits[name] = true end
    end
    local reachable = M.compute_reachable_materials(all_lines, deficits)

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for i, line in ipairs(all_lines) do
        if not active_line_indices[i] then
            goto continue_line
        end
        local objective_name = tn.typed_name_to_variable_name(line.recipe_typed_name)
        local bridge = is_bridge_line(line)

        for _, value in ipairs(line.products) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_products[constraint_name] = true

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, amount)
            problem:add_subject_term(objective_name, "|limit|" .. constraint_name, amount)

            -- Skip bridges from the bare-fluid aggregation: a bridge re-labels
            -- single-T flow as range-T (or vice versa) without creating any new
            -- fluid, so counting both the boiler's steam@165 product and the
            -- bridge's steam@[15,1000] product would double the bare-fluid total.
            local bare_limit = bare_fluid_limit_dual(constraint_name)
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
            problem:add_objective(objective_name, slack_cost, true)
            problem:add_subject_term(objective_name, "|limit|" .. objective_name, 1)
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

        do
            local elastic_name = "|surplus_sink|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, -1)
        end
        -- Cycle entry points identified by find_deficit_materials get a
        -- |basic_source| at source_cost: they are the natural external
        -- inputs of the cycle (think cu/normal + ir/normal in a quality
        -- recycling chain with no copper / iron producer registered).
        -- Without this, an all-in-cycle chain has no way to start and the
        -- LP would have to lean on |shortage_source| at penalty cost,
        -- producing solutions that look "OK" numerically but hide the
        -- external input behind the slack-vs-source distinction. source_cost
        -- is far below elastic_cost so the shortage gate is unaffected.
        if deficits[constraint_name] then
            local slack_name = "|basic_source|" .. constraint_name
            problem:add_objective(slack_name, source_cost)
            problem:add_subject_term(slack_name, constraint_name, 1)
            problem:add_subject_term(slack_name, "|limit|" .. constraint_name, 1)

            local bare_limit = bare_fluid_limit_dual(constraint_name)
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
            -- catch (mass-losing loops like fs-test-base + fs-test-short-
            -- negative) keep the escape hatch — otherwise the LP can only
            -- return all-zero.
            local elastic_name = "|shortage_source|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
            problem:add_subject_term(elastic_name, "|limit|" .. constraint_name, 1)

            local bare_limit = bare_fluid_limit_dual(constraint_name)
            if bare_limit then
                problem:add_subject_term(elastic_name, bare_limit, 1)
            end
        end
        ::continue::
    end

    for constraint_name, _ in pairs(included_products) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = "|final_sink|" .. constraint_name
        problem:add_objective(slack_name, slack_cost)
        problem:add_subject_term(slack_name, constraint_name, -1)
    end

    for constraint_name, _ in pairs(included_ingresients) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = "|basic_source|" .. constraint_name
        problem:add_objective(slack_name, source_cost)
        problem:add_subject_term(slack_name, constraint_name, 1)
        problem:add_subject_term(slack_name, "|limit|" .. constraint_name, 1)

        local bare_limit = bare_fluid_limit_dual(constraint_name)
        if bare_limit then
            problem:add_subject_term(slack_name, bare_limit, 1)
        end
    end

    for _, constraint in ipairs(constraints) do
        local constraint_name = "|limit|" .. tn.typed_name_to_variable_name(constraint)
        local limit = constraint.limit_amount_per_second

        if constraint.limit_type == "upper" then
            local slack_name = problem:add_upper_limit_constraint(constraint_name, limit)
            problem:update_objective_cost(slack_name, target_cost)
        elseif constraint.limit_type == "lower" then
            problem:add_lower_limit_constraint(constraint_name, limit)

            local elastic_name = "|elastic|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint(constraint_name, limit)

            local elastic_name = "|elastic|" .. constraint_name
            problem:add_objective(elastic_name, elastic_cost)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        else
            assert()
        end
    end

    return problem
end

return M
