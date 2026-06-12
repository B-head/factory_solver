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

-- Tiny tie-break cost on every non-bridge recipe variable. It collapses the
-- degenerate optima the three boundary costs (source / sink / target) cannot
-- see: net-zero futile cycles (barrel fill <-> empty, temperature-bridge
-- round-trips, productivity recirculation) and free terminal byproduct
-- overproduction consume no net raw input, so source_cost is blind to them and
-- the interior-point method otherwise inflates them arbitrarily on the
-- degenerate face. Any eps > 0 makes running a pointless recipe strictly
-- costly, so the LP drops it to (near) zero.
--
-- 2^-10 is chosen for three reasons: it is the power of two nearest 1e-3, the
-- geometric centre of the empirically safe 1e-4 .. 1e-2 window (below 1e-4 it
-- fails to collapse futile flows; above 1e-2 it starts overriding source_cost's
-- genuine material-efficiency tie-break); and it extends the existing
-- power-of-two ladder by one clean 2^10 step: recipe_epsilon 2^-10 < source 2^0
-- < elastic 2^10 < target 2^20. The 2^10 gap below source_cost keeps it from
-- ever competing with the material-efficiency or reachability gating.
--
-- Note this leaves an interior-point "dust" residual of ~tolerance/eps on a
-- recipe driven to zero (it parks at x ~ mu/s instead of exactly 0). On real
-- (large, richly-connected) problems that dust is negligible against the actual
-- flows; it is only visible, relative to flow, on tiny synthetic chains with an
-- isolated dead-end recipe -- see the activity_floor handling in
-- tests/cases/lp_scale_invariance.lua.
local recipe_epsilon = 2 ^ -10

-- Recipe/bridge face regularizer for the target_only_objective build (the
-- target-rescue stage 1). The stage is a pure measurement solve -- "how little
-- target violation can this build reach?" -- so the regularizer only has to
-- keep the optimal face bounded for the IPM (futile zero-cost loops would
-- drift); it must never compete with one violation unit. Same value as the
-- reference solver's stage epsilon, validated corpus-wide by
-- tests/research/probe_target_rescue.lua.
local target_rescue_epsilon = 2 ^ -20

-- Per-recipe tie-break jitter. The flat recipe_epsilon above collapses futile
-- activity, but it leaves genuine ties degenerate: when several recipes are
-- equally good (identical conversion ratios, or whole equivalent sub-chains) the
-- optimal face stays multi-dimensional and the interior-point method returns its
-- analytic centre -- flow split across the tied recipes. The same problem can
-- then yield a different split under a different presolve formulation (the
-- degeneracy divergence noted in project_proportional_row_reduction). Perturbing
-- each recipe's epsilon by a tiny recipe-specific amount shrinks that face to a
-- single vertex, so the LP has one canonical optimum independent of formulation.
--
-- The perturbation is a *pure deterministic hash of the variable key*, never RNG.
-- This matters twice over:
--   * Multiplayer: the cost feeds storage (the solution), so it must be
--     bit-identical on every client. A pure function of the key has no seed, no
--     generator state, and no table-iteration-order dependence, so it cannot
--     desync. (game.create_random_generator would instead need a persisted seed
--     AND a deterministic recipe ordering to map draws onto recipes.)
--   * Cross-interpreter: the headless suite runs on both PUC-Lua and LuaJIT and
--     must agree. Every intermediate in key_unit_hash stays < 2^53, so the
--     arithmetic is exact in IEEE-754 double on either VM (no overflow divergence).
--
-- jitter_strength keeps the perturbation a small fraction of recipe_epsilon: big
-- enough to separate tied optima past the IPM's relative tolerance (~1e-6),
-- small enough that it never competes with the flat epsilon's futile-collapse
-- or, one tier up, with source_cost's material-efficiency tie-break. At 2^-4 an
-- effective epsilon lands in [2^-10, 2^-10 + 2^-14) ~= [9.8e-4, 1.03e-3): still
-- inside the empirically safe 1e-4..1e-2 epsilon window, still ~600x below
-- source_cost = 1, and the ~6% relative spread between two recipes clears IPM
-- tolerance. It cannot flip the flat epsilon's activity ranking either -- the
-- gaps there are factors (5 vs 10 lines), which a <=1 jitter can never invert.
local jitter_strength = 2 ^ -4

---Deterministic [0,1) hash of a variable key. FNV-1a-style polynomial over the
---bytes, reduced mod 2^28 each step so that h * prime + byte stays < 2^48 (<<
---2^53), i.e. exact in IEEE-754 double on every conforming Lua VM. Pure: no RNG,
---no os/time, no table order -- safe to feed storage under lockstep. Collisions
---(two recipes sharing an epsilon) only leave that one pair mutually degenerate,
---which is harmless for a tie-break.
---@param key string variable key (the recipe's content-addressed name)
---@return number jitter in [0, 1)
local function key_unit_hash(key)
    local modulus = 2 ^ 28
    local h = 2166136261 % modulus
    for i = 1, #key do
        h = (h * 1000003 + string.byte(key, i)) % modulus
    end
    return h / modulus
end

---Source-cost tier of a material, read from the typed value's own fields rather
---than by parsing its variable-name string.
---@param value NormalizedAmount|TypedName
---@return number
local function source_cost_of(value)
    if value.type == "virtual_material" and value.name == "<heat>" then
        return source_cost_heat
    elseif value.type == "fluid" then
        return source_cost_fluid
    else
        return source_cost_item
    end
end

---The bare-fluid aggregation |limit| dual for a temperature-carrying fluid,
---built straight from the typed value (no name parse). The bare name drops the
---temperature, so a constraint on the temperature-agnostic fluid aggregates flow
---across every variant. Returns nil for non-fluids and for bare (untemperatured)
---fluids -- matching the old string check "starts with fluid/ and contains @".
---@param value NormalizedAmount|TypedName
---@return string?
local function bare_fluid_limit_of(value)
    if value.type == "fluid" and value.minimum_temperature ~= nil then
        return vk.limit(vk.material({ type = "fluid", name = value.name, quality = "normal" }))
    end
    return nil
end

local M = {}

---@param line NormalizedProductionLine
---@return boolean
local function is_bridge_line(line)
    return line.is_bridge == true
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
    return line.is_source == true
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
                            is_bridge = true,
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

---Research only (tilted-cost experiment): like compute_reachable_materials but
---records the BFS layer at which each material first became reachable. Seeds
---(materials with no producer + extra_seeds) are depth 0; a product becomes
---reachable one layer past the deepest of its recipe's ingredients. Materials
---never reached are absent from the result (treat as depth = infinity). This is
---the "distance from raw" signal a depth-based shortage tilt would ride on.
---@param production_lines NormalizedProductionLine[]
---@param extra_seeds table<string, true>?
---@return table<string, integer> depth
function M.compute_reachability_depth(production_lines, extra_seeds)
    local has_producer = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, product in each_product(line) do
            has_producer[tn.typed_name_to_variable_name(product)] = true
        end
    end

    local depth = {} ---@type table<string, integer>
    for _, line in ipairs(production_lines) do
        for _, ingredient in each_ingredient(line) do
            local name = tn.typed_name_to_variable_name(ingredient)
            if not has_producer[name] then depth[name] = 0 end
        end
    end
    if extra_seeds then
        for name in pairs(extra_seeds) do depth[name] = 0 end
    end

    local fired = {} ---@type table<integer, true>
    repeat
        local changed = false
        for i, line in ipairs(production_lines) do
            if not fired[i] then
                local all_reachable, max_in = true, 0
                for _, ingredient in each_ingredient(line) do
                    local d = depth[tn.typed_name_to_variable_name(ingredient)]
                    if d == nil then all_reachable = false break end
                    if d > max_in then max_in = d end
                end
                if all_reachable then
                    fired[i] = true
                    for _, product in each_product(line) do
                        local name = tn.typed_name_to_variable_name(product)
                        if depth[name] == nil then
                            depth[name] = max_in + 1
                            changed = true
                        end
                    end
                end
            end
        end
    until not changed

    return depth
end

---Backward dual of compute_reachable_materials: the set of materials whose
---surplus can be drained, for free, to a zero-cost terminal sink. Seeds with the
---materials that own a free |final_sink| -- pure products (produced, never
---consumed) and any caller-supplied `extra_seeds` (the constrained / pinned
---materials, which also get a free final_sink) -- then fires recipes BACKWARD:
---a line all of whose products are already drainable lets every one of its
---ingredients drain through it (run the recipe, its outputs leave for free), so
---those ingredients become drainable too. A zero-product line (a user `<sink>`
---virtual recipe) fires vacuously, which is correct -- it IS a free drain.
---
---Research only: the sink-side analogue of reachability gating. An A/B sweep
---(project_sink_side_reachability_gating) showed gating |surplus_sink| on this
---is NOT solution-preserving -- topological drainability is not economical
---drainability, because draining a material's surplus down its consumer chain
---costs the consumers' own inputs, which may be dearer than just dumping it. So
---surplus_sink stays unconditional in shipped builds; this exists to reproduce
---that measurement, never wired on in-engine.
---@param production_lines NormalizedProductionLine[]
---@param extra_seeds table<string, true>?
---@return table<string, true> drainable
function M.compute_drainable_materials(production_lines, extra_seeds)
    local has_producer = {} ---@type table<string, true>
    local has_consumer = {} ---@type table<string, true>
    for _, line in ipairs(production_lines) do
        for _, product in each_product(line) do
            has_producer[tn.typed_name_to_variable_name(product)] = true
        end
        for _, ingredient in each_ingredient(line) do
            has_consumer[tn.typed_name_to_variable_name(ingredient)] = true
        end
    end

    local drainable = {} ---@type table<string, true>
    for name in pairs(has_producer) do
        if not has_consumer[name] then
            drainable[name] = true
        end
    end
    if extra_seeds then
        for name in pairs(extra_seeds) do
            drainable[name] = true
        end
    end

    local fired = {} ---@type table<integer, true>
    repeat
        local changed = false
        for i, line in ipairs(production_lines) do
            if not fired[i] then
                local all_products_drainable = true
                for _, product in each_product(line) do
                    if not drainable[tn.typed_name_to_variable_name(product)] then
                        all_products_drainable = false
                        break
                    end
                end
                if all_products_drainable then
                    fired[i] = true
                    for _, ingredient in each_ingredient(line) do
                        local name = tn.typed_name_to_variable_name(ingredient)
                        if not drainable[name] then
                            drainable[name] = true
                            changed = true
                        end
                    end
                end
            end
        end
    until not changed

    return drainable
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
    local function touch_material(value, material_var)
        if seen_materials[material_var] then return end
        seen_materials[material_var] = true
        link(material_var, vk.limit(material_var))
        local bare_limit = bare_fluid_limit_of(value)
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
            local bare_limit = bare_fluid_limit_of(value)
            if bare_limit and not bridge then
                link(recipe_var, bare_limit)
            end
            touch_material(value, material_var)
        end
        for _, value in each_ingredient(line) do
            local material_var = tn.typed_name_to_variable_name(value)
            link(recipe_var, material_var)
            touch_material(value, material_var)
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
        if line.is_source then out[#out + 1] = "    is_source = true," end
        if line.is_sink then out[#out + 1] = "    is_sink = true," end
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

---Research-only switches for the produced-AND-consumed (cycle-material) escape
---hatch preprocessing. Every field defaults to its current shipped behaviour
---(on) when nil; only the standalone headless solve worker (tests/solve_problem)
---sets them, from env vars, to ablate one mechanism at a time on a fixed corpus.
---NEVER read from os.getenv in here -- create_problem runs in-engine under the
---Factorio sandbox (os stripped) and on the deterministic-lockstep path, so the
---toggles must arrive as an argument, decided by the Factorio-free caller.
---@class CreateProblemOptions
---@field deficit_seeding boolean?      Default true. Seed find_deficit_materials' raw deficits as |initial_source| cycle entry points. Off: skip that seeding.
---@field catalyst_closure boolean?     Default true. Run the catalyst-loop closure loop that seeds still-unreachable primer candidates one at a time. Off: skip the loop.
---@field reachability_gating boolean?  Default true. HARD gate: deny |shortage_source| to reachable materials (they must run their chain). Off: un-gated -- every non-deficit produced+consumed material gets a |shortage_source|. The shipped build replaces this with reachability_soft_gate_k (below); the hard gate is retained for the A/B and for fixtures that still assert the deny-the-hatch behaviour.
---@field reachability_soft_gate_k number?  SOFT gate (the shipped replacement for the hard reachability_gating): instead of denying the hatch to a reachable material, emit its |shortage_source| at elastic_cost * k (k >> 1), so running the chain beats the penalised import. Reproduces the gate as a cost using create_problem's OWN reachability verdict (active lines + deficit seeds + catalyst closure). k must stay below target_cost/elastic_cost (= 2^10) so a reachable shortage never undercuts target relaxation; the shipped value is 256. Applies only to reachable, non-deficit materials; unreachable materials keep the flat elastic_cost hatch (their import-vs-fabricate is observe_price's job via shortage_cost_overrides). nil leaves the hatch flat.
---@field shortage_cost_overrides table<string, number>?  Per-material multiplier on the |shortage_source| objective (cost = elastic_cost * mult), keyed by material variable name. Plain string-keyed table, storage-safe and deterministic. Applied regardless of gating and takes precedence over reachability_soft_gate_k. This is solver/observe_price's production channel: it reprices the unreachable self-sustaining catalyst shortages so the placed cycle fabricates instead of penalty-importing. Absent materials keep their gate/flat cost. nil leaves costs unchanged.
---@field shortage_cost_fn (fun(constraint_name: string, is_reachable: boolean): number)?  Research only. When set (and reachability_gating is off so the hatch is un-gated), the un-gated |shortage_source| objective is priced by this callback instead of the flat elastic_cost -- the hook for the tilted-cost experiment. is_reachable is create_problem's OWN reachability verdict (the same set the gate uses: active lines + deficit seeds + catalyst closure), so a "soft gate" can lift only reachable materials and leave unreachable ones their cheap import hatch. The caller may also close over any precomputed signal (e.g. M.compute_reachability_depth). nil leaves the flat elastic_cost in place.
---@field deficit_exclude table<string, true>?  Research only. Materials never to seed as deficits / closure primers, even when the heuristics pick them. Lets a probe ask the leave-one-out reachability question -- is a seeded material reachable WITHOUT its own seed (a seed otherwise extends reachability to itself, so the shipped build cannot answer it). The excluded material keeps its plain |shortage_source| hatch, so shortage_cost_fn fires for it and reports the leave-one-out verdict. nil excludes nothing.
---@field surplus_cost_fn (fun(constraint_name: string): number)?  Research only. Re-prices the |surplus_sink| (over-production / byproduct disposal) objective instead of the flat elastic_cost. Lowering surplus relative to shortage tests the "byproduct disposal is bookkeeping, not real economic cost" hypothesis: a chain whose cost is byproduct-dominated should beat the import, while a raw-dominated chain (genuine resource spend) is unaffected. nil leaves the flat elastic_cost in place.
---@field surplus_sink_gating boolean?   Default FALSE -- this is NOT shipped behaviour, a research probe (project_sink_side_reachability_gating). When on, gate |surplus_sink| on drainability (the backward dual of reachability): a material that can shed surplus to a free terminal sink loses its penalised over-production escape. Measured to change ~21% of the corpus and break convergence on a few, so it ships OFF; the switch only exists to reproduce that A/B. Off (default): every produced+consumed non-bridge material gets a |surplus_sink|.
---@field target_only_objective boolean?  Target-rescue stage 1 (manage/pre_solve.lua M.target_rescue_step): re-cost the finished build so the target elastics (cost 1) are the ONLY objective; recipe/bridge keep a tiny face regularizer so the optimal face stays bounded for the IPM, everything else is free. The solve's summed |elastic| is T_min -- the least target violation this build can structurally reach (mirrors the reference solver's lexicographic stage 1). Build-only switch: combine with target_budget on the NEXT build to lock the optimum in.
---@field target_budget number?  Target-rescue lock (manage/pre_solve.lua M.target_rescue_step): add one upper-limit row capping the summed target elastics at this value, so the solve keeps the stage-1 target optimum no matter how expensive the violations the chain forces. This fixes the all-zero target collapse: a single weighted LP trades the target against violations at the finite exchange rate target_cost / elastic_cost = 2^10, so any problem needing > 1024 violation units per target unit was rationally abandoned (T relaxed in full -- the trade is linear, hence all-or-nothing). 30/1678 corpus problems before the rescue, 0 after. nil adds no row.

---Create linear programming problems.
---@param solution_name string
---@param constraints Constraint[]
---@param production_lines NormalizedProductionLine[]
---@param forced_imports table<string, true>?  Material variable names to seed as |initial_source| imports when unreachable (in addition to the heuristic deficits). The diagnose-then-reclassify pass fills this with the AVOIDABLE cheats from a first solve (see M.diagnose_avoidable_cheats). nil leaves behaviour unchanged.
---@param options CreateProblemOptions?  Research ablation switches for the cycle-material escape-hatch preprocessing; nil (the in-engine default) leaves every mechanism on.
---@return Problem
function M.create_problem(solution_name, constraints, production_lines, forced_imports, options)
    local problem = problem_generator.new(solution_name)

    -- Ablation switches (all default ON; only the headless research worker flips
    -- them). Read once here so the gated sites below stay readable.
    options = options or {}
    local opt_deficit_seeding = options.deficit_seeding ~= false
    local opt_catalyst_closure = options.catalyst_closure ~= false
    local opt_reachability_gating = options.reachability_gating ~= false
    -- Research probe; unlike the three above it defaults OFF (the shipped build
    -- never gates surplus_sink), so only an explicit `true` from the headless
    -- worker turns it on.
    local opt_surplus_sink_gating = options.surplus_sink_gating == true
    -- Research probe (tilted-cost experiment): callback that re-prices the
    -- un-gated |shortage_source| objective. nil leaves the flat elastic_cost.
    local opt_shortage_cost_fn = options.shortage_cost_fn
    local opt_surplus_cost_fn = options.surplus_cost_fn
    -- Soft gate (shipped gating replacement) and observe_price's per-material
    -- overrides. Both re-price the |shortage_source| objective on the same
    -- (un-gated) hatch; overrides win over the soft gate, the soft gate lifts
    -- reachable materials, unreachable ones stay flat.
    local opt_soft_gate_k = options.reachability_soft_gate_k
    local opt_shortage_cost_overrides = options.shortage_cost_overrides
    -- Research probe (machine-polish vs plain-epsilon comparison): overrides
    -- the flat recipe_epsilon tier. nil keeps the shipped 2^-10; the per-key
    -- jitter scales with it (it is a fraction OF the tier).
    local opt_recipe_epsilon = options.recipe_epsilon or recipe_epsilon
    -- Research probe (the Vp rescue's hatch-deletion final): materials whose
    -- import hatches (intermediate |initial_source| / |shortage_source|) are
    -- omitted entirely. Only sound when a stage solve has already PROVEN the
    -- material's import can be ~zero (the stage solution is the witness, so
    -- elastic necessity is not violated): deletion encodes that face
    -- structurally, where a ~zero budget row over live variables is
    -- numerically hostile to the IPM's interior point. Deficit seeds still
    -- count for reachability; only the hatch variables disappear.
    local opt_hatch_exclude = options.hatch_exclude

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
    if opt_deficit_seeding then
        for name in pairs(raw_deficits) do
            if not pre_reachable[name] then deficits[name] = true end
        end
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

    -- Research-only leave-one-out hole (see CreateProblemOptions): drop the
    -- excluded materials from the seed set before reachability is derived.
    local opt_deficit_exclude = options.deficit_exclude
    if opt_deficit_exclude then
        for name in pairs(opt_deficit_exclude) do deficits[name] = nil end
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
    while opt_catalyst_closure do
        local pick = nil
        for name in pairs(seed_candidates) do
            if not reachable[name] and not deficits[name]
                and not (opt_deficit_exclude and opt_deficit_exclude[name])
                and (not pick or name < pick) then
                pick = name
            end
        end
        if not pick then break end
        deficits[pick] = true
        reachable = M.compute_reachable_materials(all_lines, deficits)
    end

    -- Sink-side dual of the reachability gate (research probe; off unless the
    -- worker turns it on). A material that can drain its surplus to a free
    -- terminal sink does not also need the penalised |surplus_sink|; one that is
    -- stuck does. Seed with the pinned/constrained materials (they own a free
    -- |final_sink| like the pure products the BFS already seeds itself).
    local drainable = opt_surplus_sink_gating
        and M.compute_drainable_materials(all_lines, constrained_materials)
        or {}

    local included_products, included_ingresients = {}, {} ---@type table<string, true>, table<string, true>
    for i, line in ipairs(all_lines) do
        if not active_line_indices[i] then
            goto continue_line
        end
        local objective_name = tn.typed_name_to_variable_name(line.recipe_typed_name)
        local bridge = is_bridge_line(line)

        for _, value in each_product(line) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_products[constraint_name] = value

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, amount)
            problem:add_subject_term(objective_name, vk.limit(constraint_name), amount)

            -- Skip bridges from the bare-fluid aggregation: a bridge re-labels
            -- single-T flow as range-T (or vice versa) without creating any new
            -- fluid, so counting both the boiler's steam@165 product and the
            -- bridge's steam@[15,1000] product would double the bare-fluid total.
            local bare_limit = bare_fluid_limit_of(value)
            if bare_limit and not bridge then
                problem:add_subject_term(objective_name, bare_limit, amount)
            end
        end

        for _, value in each_ingredient(line) do
            local constraint_name = tn.typed_name_to_variable_name(value)
            included_ingresients[constraint_name] = value

            local amount = value.amount_per_second
            problem:add_subject_term(objective_name, constraint_name, -amount)
        end

        if bridge then
            -- A bridge only re-labels one fluid temperature range as another; it
            -- creates no material, so it carries no base cost (a bridge hop must
            -- stay free relative to source/elastic, or the LP would skip a needed
            -- temperature conversion). But when several bridges can route the same
            -- fluid they are all cost-0 and the LP is indifferent between them --
            -- a degenerate face whose free dimension lives entirely on the bridge
            -- variables. The interior-point method picks its analytic centre cold,
            -- so the realized bridge flows drift across warm-started re-solves
            -- (the seed26-class "temperature plumbing wobble": measured ~0.29 wide
            -- on the explorer corpus, three orders above the recipe wobble). The
            -- recipe jitter above cannot reach it -- bridges take neither the base
            -- epsilon nor that jitter. So give each bridge the SAME deterministic
            -- key-hash jitter, WITHOUT the recipe_epsilon base: a distinct
            -- infinitesimal cost in [0, 2^-14) that picks one canonical routing
            -- without pricing the hop. Still ~four orders below source_cost, so it
            -- never tips a real decision or makes the LP skip a bridge.
            local bridge_cost = slack_cost + opt_recipe_epsilon * jitter_strength * key_unit_hash(objective_name)
            problem:add_objective(objective_name, bridge_cost, true, "bridge")
        else
            -- A user source recipe is priced at source_cost on its product so
            -- the LP treats it like a declared external input rather than a
            -- free fountain. Sinks (and every other virtual recipe) stay at
            -- slack_cost = 0.
            -- Flat epsilon plus a per-recipe hash jitter (both inside the
            -- recipe_epsilon tier) so genuinely tied recipes resolve to one
            -- canonical vertex instead of an analytic-centre split.
            local recipe_cost = opt_recipe_epsilon * (1 + jitter_strength * key_unit_hash(objective_name))
            if is_source_line(line) and line.products[1] then
                recipe_cost = source_cost_of(line.products[1]) + recipe_cost
            end
            problem:add_objective(objective_name, recipe_cost, true, "recipe")
            problem:add_subject_term(objective_name, vk.limit(objective_name), 1)
        end
        ::continue_line::
    end

    for constraint_name, value in pairs(included_products) do
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
        if not bridge_target_variables[constraint_name]
            and not (opt_surplus_sink_gating and drainable[constraint_name]) then
            local elastic_name = vk.surplus_sink(constraint_name)
            local surplus_cost = elastic_cost
            if opt_surplus_cost_fn then
                surplus_cost = opt_surplus_cost_fn(constraint_name)
            end
            problem:add_objective(elastic_name, surplus_cost, false, "surplus_sink", constraint_name)
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
            problem:add_objective(final_name, slack_cost, false, "final_sink", constraint_name)
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
        if opt_hatch_exclude and opt_hatch_exclude[constraint_name] then --[[
            Deletion mode (research): no import hatch at all for this
            intermediate -- see opt_hatch_exclude above. ]]
        elseif deficits[constraint_name] then
            local slack_name = vk.initial_source(constraint_name)
            problem:add_objective(slack_name, source_cost_of(value), false, "initial_source", constraint_name)
            problem:add_subject_term(slack_name, constraint_name, 1)
            problem:add_subject_term(slack_name, vk.limit(constraint_name), 1)

            local bare_limit = bare_fluid_limit_of(value)
            if bare_limit then
                problem:add_subject_term(slack_name, bare_limit, 1)
            end
        elseif not (opt_reachability_gating and reachable[constraint_name]) then
            -- |shortage_source| is the import-vs-fabricate escape. Reachable
            -- materials (reachable from raw inputs or promoted deficits) must run
            -- their producer chain rather than pay elastic_cost to fabricate
            -- intermediates (the Fulgora-scrap wrong-solution). The shipped build
            -- enforces that as a SOFT gate (reachability_soft_gate_k): the hatch
            -- exists but is priced at elastic_cost*k so the chain wins. The legacy
            -- HARD gate (opt_reachability_gating) instead denies the hatch
            -- entirely and is kept for the A/B; when it is on, reachable materials
            -- skip this branch. Materials in dead-end / mass-losing cycles the
            -- deficit heuristic did not catch stay unreachable and keep the flat
            -- hatch -- their import-vs-fabricate is observe_price's job, repriced
            -- per material through shortage_cost_overrides.
            local elastic_name = vk.shortage_source(constraint_name)
            local is_reachable = reachable[constraint_name] == true
            local shortage_cost = elastic_cost
            if opt_soft_gate_k and is_reachable then
                shortage_cost = elastic_cost * opt_soft_gate_k
            end
            -- Per-material override (observe_price) takes precedence over the gate.
            if opt_shortage_cost_overrides then
                local mult = opt_shortage_cost_overrides[constraint_name]
                if mult then shortage_cost = elastic_cost * mult end
            end
            -- Research-only callback, authoritative when set (headless ablation).
            if opt_shortage_cost_fn then
                shortage_cost = opt_shortage_cost_fn(constraint_name, is_reachable)
            end
            problem:add_objective(elastic_name, shortage_cost, false, "shortage_source", constraint_name)
            problem:add_subject_term(elastic_name, constraint_name, 1)
            problem:add_subject_term(elastic_name, vk.limit(constraint_name), 1)

            local bare_limit = bare_fluid_limit_of(value)
            if bare_limit then
                problem:add_subject_term(elastic_name, bare_limit, 1)
            end
        end
        ::continue::
    end

    for constraint_name, _ in pairs(included_products) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = vk.final_sink(constraint_name)
        problem:add_objective(slack_name, slack_cost, false, "final_sink", constraint_name)
        problem:add_subject_term(slack_name, constraint_name, -1)
    end

    for constraint_name, value in pairs(included_ingresients) do
        problem:add_equivalence_constraint(constraint_name, 0)

        local slack_name = vk.initial_source(constraint_name)
        problem:add_objective(slack_name, source_cost_of(value), false, "initial_source", constraint_name)
        problem:add_subject_term(slack_name, constraint_name, 1)
        problem:add_subject_term(slack_name, vk.limit(constraint_name), 1)

        local bare_limit = bare_fluid_limit_of(value)
        if bare_limit then
            problem:add_subject_term(slack_name, bare_limit, 1)
        end
    end

    for _, constraint in ipairs(constraints) do
        local constraint_material = tn.typed_name_to_variable_name(constraint)
        local constraint_name = vk.limit(constraint_material)
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
            problem:add_objective(elastic_name, target_cost, false, "elastic", constraint_material)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        elseif constraint.limit_type == "equal" then
            problem:add_equivalence_constraint(constraint_name, limit)

            local elastic_name = vk.elastic(constraint_name)
            problem:add_objective(elastic_name, target_cost, false, "elastic", constraint_material)
            problem:add_subject_term(elastic_name, constraint_name, 1)
        else
            assert()
        end
    end

    -- Target rescue (see CreateProblemOptions): the budget row locks the summed
    -- target elastics at stage 1's optimum; the stage-1 re-cost makes them the
    -- only objective. Last so every elastic above already exists.
    if options.target_budget then
        local budget_name = vk.target_budget()
        problem:add_upper_limit_constraint(budget_name, options.target_budget)
        for key, primal in pairs(problem.primals) do
            if primal.kind == "elastic" then
                problem:add_subject_term(key, budget_name, 1)
            end
        end
    end
    if options.target_only_objective then
        for _, primal in pairs(problem.primals) do
            if primal.kind == "elastic" then
                primal.cost = 1
            elseif primal.kind == "recipe" or primal.kind == "bridge" then
                primal.cost = target_rescue_epsilon
            else
                primal.cost = 0
            end
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
---`x` is the packed primal map (variable name -> value) from a finished solve;
---`primals` is the matching Problem.primals, read for each variable's class.
---@param x table<string, number>
---@param primals table<string, Primal>
---@param production_lines NormalizedProductionLine[]
---@param epsilon number?  treat |x| below this as zero (default 1e-6)
---@return table<string, true> avoidable  material variable names to re-import
function M.diagnose_avoidable_cheats(x, primals, production_lines, epsilon)
    epsilon = epsilon or 1e-6

    -- Collect the materials that carry a non-zero cheat, deduped. Each escape
    -- variable's Primal records the base material key it stands in for (both
    -- shortage_source and elastic set .material), so read it off the metadata
    -- instead of stripping the prefix off the variable name. A bare |elastic|
    -- without a material maps to no single material and is skipped.
    local cheated = {} ---@type table<string, true>
    for name, value in pairs(x) do
        if math.abs(value) > epsilon then
            local p = primals[name]
            if p and (p.kind == "shortage_source" or p.kind == "elastic") and p.material then
                cheated[p.material] = true
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

-- Cost tiers exported so solver/observe_price.lua can compute its ceiling
-- (target_cost / (elastic_cost * qty)) and its per-material shortage multipliers
-- against the same constants the LP is priced with, instead of duplicating them.
M.elastic_cost = elastic_cost
M.target_cost = target_cost

return M
