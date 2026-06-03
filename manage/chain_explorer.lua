-- Random-chain explorer: a research/stress harness that asks whether
-- factory_solver returns a PRACTICALLY USABLE solution on pyanodon-scale recipe
-- graphs -- NOT whether the solution is optimal. The LP is always feasible and
-- bounded (soft elastic/shortage/surplus structure), so "usable" is about the
-- solver's heuristics (reachability gating, find_deficit_materials seeding, the
-- shortage_source escape hatch, temperature bridges) holding up at a scale they
-- were never hand-tuned against.
--
-- Method: pick a random seed recipe, grow a connected chain through the relation
-- index (mode = both / upstream-only / downstream-only), pin ONLY the seed
-- recipe at 1/s, and solve through the real pre_solve -> create_problem -> IPM
-- path.
--
-- What counts as "undesirable" (learned empirically on pyanodon, 2026-06-03):
--   * TRUE signal -> solver_state ~= "finished" (numeric blow-up / no
--     convergence) OR cheat mass > 0 (shortage_source / elastic activated: the
--     LP fabricated/dumped material instead of running the chain -- the
--     degenerate escape create_problem's heuristics are meant to prevent).
--   * PARK fraction (recipe vars near zero) is NOT a reliable signal on its own:
--     on branching pyanodon graphs a parked recipe is usually a normal unused
--     ALTERNATIVE or a *-pyvoid waste recipe, not a degeneracy. (The synthetic
--     one-line chains that "ran every recipe" had no branches/void.) It is kept
--     as a secondary note (park fraction excluding pyvoid), never the HIT gate.
--
-- Driven over RCON like manage/smoke_rcon.lua, registered in the same smoke_rcon
-- scenario block in control.lua. Launcher: tests/explore_chains.ps1. A fixed
-- seed reproduces a chain, so any HIT can be re-run by its (seed,mode,void,hops).

local flib_table = require "__flib__/table"
local fs_log = require "fs_log"
local acc = require "manage/accessor"
local preset = require "manage/preset"
local relation = require "manage/relation"
local save = require "manage/save"
local pre_solve = require "manage/pre_solve"
local tn = require "manage/typed_name"

local log = fs_log.for_module("chain_explorer")

local M = {}

local FORCE_INDEX = 1
local PLAYER_INDEX = 1

-- A recipe variable is "parked" when it sits at the IPM's interior floor rather
-- than carrying real flow. The live solver keeps strictly-interior values near
-- ~1e-11 for a truly-zero variable while active ones are O(1)+, so a threshold
-- relative to the chain's largest recipe value (with an absolute floor) cleanly
-- separates the two without assuming a fixed solution scale.
local PARK_REL = 1e-6
local PARK_ABS = 1e-9
-- Cheat mass (shortage_source/elastic) above this flags a TRUE undesirable
-- solution. Slack values ride near the IPM floor (~1e-11) when inactive.
local CHEAT_EPS = 1e-6
-- park fraction (excluding pyvoid) at/above this earns a "~park" note -- worth a
-- look, but usually an alternative path on a branchy chain, so not a HIT.
local PARK_NOTE_FRACTION = 0.5

---@param recipe_proto LuaRecipePrototype
---@param prefer_modules boolean? Prefer a machine WITH module slots (needed so
---  quality modules actually decompose this recipe's product -- otherwise a
---  slot-0 machine like assembling-machine-1 is picked and the target product
---  is never upcycled, making a rare target reachable only via unrelated
---  recycling by-products: not a realistic upcycle chain).
---@return LuaEntityPrototype? machine A deterministically-chosen crafting machine, or nil if none can craft it.
local function pick_machine(recipe_proto, prefer_modules)
    local machines = acc.get_machines_for_recipe(recipe_proto)
    if #machines == 0 then
        return nil
    end
    -- Category machine order is not guaranteed stable across runs; sort by name
    -- so the same seed rebuilds the same chain.
    table.sort(machines, function(a, b) return a.name < b.name end)
    if prefer_modules then
        for _, m in ipairs(machines) do
            if (acc.get_machine_module_inventory_size(m, "normal") or 0) > 0 then
                return m
            end
        end
    end
    return machines[1]
end

---Build a ProductionLine for a real recipe, picking a machine and (if the
---machine burns fuel) a fuel preset. Returns nil when the recipe has no eligible
---machine (uncraftable in this mod set) so the caller can skip it.
---@param recipe_name string
---@param use_quality boolean Fill the machine's module slots with quality modules to drive quality decomposition.
---@return ProductionLine?
local function make_line(recipe_name, use_quality)
    local recipe_proto = prototypes.recipe[recipe_name]
    if not recipe_proto then
        return nil
    end
    local machine = pick_machine(recipe_proto, use_quality)
    if not machine then
        return nil
    end
    local machine_tn = tn.create_typed_name("machine", machine.name)
    -- get_fuel_preset returns the fixed/preset fuel, or nil for a fuel-less
    -- machine; pcall because the preset tables assert on some energy sources.
    local ok, fuel_tn = pcall(preset.get_fuel_preset, PLAYER_INDEX, machine_tn)
    if not ok then
        fuel_tn = nil
    end

    -- Quality modules drive pre_solve.quality_decomposition: each product splits
    -- into a normal/uncommon/rare/... distribution, so the LP must balance every
    -- quality variant -- the recycling-loop machinery that is this mod's USP.
    -- Filled only when the machine actually has slots; the LP/normalize layer
    -- trims the effect for machines that disallow quality, so no extra gating.
    local modules = {}
    if use_quality then
        local slots = acc.get_machine_module_inventory_size(machine, "normal") or 0
        local qm = prototypes.item["quality-module-3"] or prototypes.item["quality-module"]
        if slots > 0 and qm then
            -- module_typed_names is keyed by SLOT NUMBER as a string ("1".."N"),
            -- NOT a plain array -- trim_modules / get_total_modules read
            -- module_typed_names[tostring(slot)]. A numeric array is silently
            -- ignored (no effect, no error). A module is an item prototype, so
            -- the typed_name uses type "item".
            for i = 1, slots do
                modules[tostring(i)] = tn.create_typed_name("item", qm.name, "normal")
            end
        end
    end

    ---@type ProductionLine
    return {
        recipe_typed_name = tn.create_typed_name("recipe", recipe_name),
        machine_typed_name = machine_tn,
        module_typed_names = modules,
        affected_by_beacons = {},
        fuel_typed_name = fuel_tn,
    }
end

---Grow a connected chain from a random seed recipe.
---@param seed integer
---@param hops integer How many growth steps to attempt.
---@param mode string "both" (default) | "up" (upstream only) | "down" (downstream only) | "cycle" (both, preferring loop-closing candidates).
---@param exclude_void boolean Drop pyanodon *-pyvoid (waste/disposal) recipes from seeds and growth.
---@param exclude_source_sink boolean Drop recipes with no ingredients (source-like) or no products (sink-like).
---@return string? seed_recipe nil on failure.
---@return string[]? order Selected recipe names in insertion order (nil on failure).
---@return string? err Error message, set when seed_recipe is nil.
---@return { added: integer, closed: boolean, unresolved: string[] }? closure Ingredient-closure stats (nil on failure).
function M.build_chain(seed, hops, mode, exclude_void, exclude_source_sink)
    -- Factorio's create_random_generator maps small seed differences to an
    -- IDENTICAL first draw (verified live: seeds 1/2/3/7/99 all yield 10580),
    -- and warming the generator does not help -- the raw seed barely reaches the
    -- initial state, so every warmed sequence still matches. Scatter the seed
    -- with a Knuth multiplicative hash (+offset so seed 0 isn't a fixed point)
    -- so consecutive seeds diverge from the very first draw.
    local rng = game.create_random_generator((seed * 2654435761 + 12345) % 4294967296)
    local rel = relation.create_relation_to_recipes(FORCE_INDEX)
    local force = game.forces[FORCE_INDEX]

    -- fs-test-* are factory_solver's own data_test debug recipes (not real game
    -- content); *-pyvoid are pyanodon's waste/disposal recipes a usable factory
    -- chain rarely includes. Both are filtered out (pyvoid only when requested)
    -- so the chain reflects recipes a user would actually place.
    local function allowed(name)
        if name:find("^fs%-test") then return false end
        if exclude_void and name:find("pyvoid", 1, true) then return false end
        return true
    end
    -- A recipe that consumes nothing acts like a SOURCE (mining/extraction); one
    -- that produces nothing acts like a SINK (disposal). Either lets the LP
    -- short-circuit the chain -- supply or absorb material without running the
    -- intended path -- which is exactly why the solver finds a usable solution so
    -- easily. Dropping them forces a closed transformation chain with no escape,
    -- so the solver's heuristics are actually stressed.
    local function structural_ok(recipe)
        if not exclude_source_sink then return true end
        return #recipe.ingredients > 0 and #recipe.products > 0
    end

    local candidates = {}
    for name, recipe in pairs(force.recipes) do
        if recipe.enabled and not recipe.hidden and #recipe.products > 0
            and allowed(name) and structural_ok(recipe) then
            candidates[#candidates + 1] = name
        end
    end
    table.sort(candidates)
    if #candidates == 0 then
        return nil, nil, "no candidate recipes in this mod set"
    end

    local seed_recipe = candidates[rng(1, #candidates)]
    local selected = { [seed_recipe] = true }
    local order = { seed_recipe }

    -- Materials touched by selected recipes. In "cycle" mode the growth step
    -- prefers candidates that reconnect to these (closing loops) instead of
    -- always extending outward into a DAG. Random both-direction growth rarely
    -- forms the cyclic chains (recycling / catalytic / mutual-conversion loops)
    -- that stress the solver most, so cycle mode biases toward them.
    local selected_materials = {}
    local function touch(recipe_proto)
        for _, ing in ipairs(recipe_proto.ingredients) do selected_materials[ing.name] = true end
        for _, prod in ipairs(recipe_proto.products) do selected_materials[prod.name] = true end
    end
    touch(prototypes.recipe[seed_recipe])

    for _ = 1, hops do
        local base = order[rng(1, #order)]
        local rp = prototypes.recipe[base]
        if rp then
            -- (direction, material) pool. mode gates which directions grow:
            -- "up" follows ingredients to producers, "down" follows products to
            -- consumers, "both"/"cycle" do both.
            local pool = {}
            if mode ~= "down" then
                for _, ing in ipairs(rp.ingredients) do
                    pool[#pool + 1] = { dir = "up", type = ing.type, name = ing.name }
                end
            end
            if mode ~= "up" then
                for _, prod in ipairs(rp.products) do
                    pool[#pool + 1] = { dir = "down", type = prod.type, name = prod.name }
                end
            end
            if #pool > 0 then
                local hook = pool[rng(1, #pool)]
                local info
                if hook.type == "item" then
                    info = rel.item[hook.name]
                elseif hook.type == "fluid" then
                    info = rel.fluid[hook.name]
                end
                if info then
                    local list = hook.dir == "up" and info.recipe_for_product or info.recipe_for_ingredient
                    local pick = {}
                    for _, rn in ipairs(list) do
                        local fr = force.recipes[rn]
                        if prototypes.recipe[rn] and not selected[rn] and fr and fr.enabled
                            and allowed(rn) and structural_ok(fr) then
                            pick[#pick + 1] = rn
                        end
                    end
                    table.sort(pick)
                    if #pick > 0 then
                        local chosen
                        if mode == "cycle" and #pick > 1 then
                            -- Prefer the candidate touching the most already-
                            -- selected materials: its extra inputs/outputs feed
                            -- back into the chain, closing a loop rather than
                            -- dangling a fresh leaf.
                            local best, best_score = {}, -1
                            for _, rn in ipairs(pick) do
                                local crp = prototypes.recipe[rn]
                                local score = 0
                                for _, ing in ipairs(crp.ingredients) do
                                    if selected_materials[ing.name] then score = score + 1 end
                                end
                                for _, prod in ipairs(crp.products) do
                                    if selected_materials[prod.name] then score = score + 1 end
                                end
                                if score > best_score then
                                    best, best_score = { rn }, score
                                elseif score == best_score then
                                    best[#best + 1] = rn
                                end
                            end
                            chosen = best[rng(1, #best)]
                        else
                            chosen = pick[rng(1, #pick)]
                        end
                        selected[chosen] = true
                        order[#order + 1] = chosen
                        touch(prototypes.recipe[chosen])
                    end
                end
            end
        end
    end

    -- Reachability of every material from base resources THROUGH the current
    -- selected recipe set, mirroring solver/create_problem.compute_reachable_
    -- materials so the generator's notion of "this material has a real producer
    -- chain" matches the LP's exactly. A material consumed but produced by no
    -- selected recipe is a raw seed (the LP |initial_source|s it: ores, water,
    -- ...); a recipe's products only become reachable once ALL its ingredients
    -- are reachable. Crucially, a by-product of a cyclic recipe is NOT reachable
    -- until the cycle gains an external entry -- which is the stone-furnace <-
    -- burner-mining-drill-recycling dead end that the old "is it produced at
    -- all" test missed (the by-product made the material look craftable while it
    -- was only makeable from inside the cycle).
    ---@return table<string, true> reachable Set of "type/name" keys.
    local function compute_reachable()
        local produced = {}
        for rn in pairs(selected) do
            local rp2 = prototypes.recipe[rn]
            if rp2 then
                for _, p in ipairs(rp2.products) do produced[p.type .. "/" .. p.name] = true end
            end
        end
        local reachable = {}
        for rn in pairs(selected) do
            local rp2 = prototypes.recipe[rn]
            if rp2 then
                for _, ing in ipairs(rp2.ingredients) do
                    local key = ing.type .. "/" .. ing.name
                    if not produced[key] then reachable[key] = true end
                end
            end
        end
        local changed = true
        while changed do
            changed = false
            for rn in pairs(selected) do
                local rp2 = prototypes.recipe[rn]
                if rp2 then
                    local all_in = true
                    for _, ing in ipairs(rp2.ingredients) do
                        if not reachable[ing.type .. "/" .. ing.name] then
                            all_in = false
                            break
                        end
                    end
                    if all_in then
                        for _, p in ipairs(rp2.products) do
                            local key = p.type .. "/" .. p.name
                            if not reachable[key] then
                                reachable[key] = true
                                changed = true
                            end
                        end
                    end
                end
            end
        end
        return reachable
    end

    -- Ingredient closure: ensure every consumed material is reachable from base
    -- resources, not merely "produced somewhere" (which a cyclic by-product
    -- satisfies without the material ever being makeable from raw inputs).
    -- For each consumed-but-unreachable material, add the producer recipe
    -- CLOSEST to firing -- most ingredients already reachable, then fewest total
    -- ingredients (a leaner recipe is likelier a base bootstrap), then name for
    -- determinism. Iterating bottoms the chain out at raw resources, so the LP
    -- never has to |shortage_source| an intermediate it could have crafted,
    -- leaving only genuine solver findings. Materials whose only producers are
    -- virtual (mining / pumping) yield no eligible candidate and stay raw seeds
    -- (already reachable) -- correct, the LP initial_sources them.
    local closure_added = 0
    local closure_closed = false
    for _ = 1, 200 do
        local reachable = compute_reachable()

        -- Consumed materials not reachable from base. Raw resources never appear
        -- here: with no in-chain producer they are seeds, hence reachable.
        local needs = {} ---@type table<string, { type: string, name: string }>
        for rn in pairs(selected) do
            local rp2 = prototypes.recipe[rn]
            if rp2 then
                for _, ing in ipairs(rp2.ingredients) do
                    local key = ing.type .. "/" .. ing.name
                    if not reachable[key] then needs[key] = { type = ing.type, name = ing.name } end
                end
            end
        end
        if not next(needs) then
            closure_closed = true
            break
        end

        local need_keys = {}
        for k in pairs(needs) do need_keys[#need_keys + 1] = k end
        table.sort(need_keys)

        local to_add = {}
        local progressed = false
        for _, key in ipairs(need_keys) do
            local m = needs[key]
            local info = (m.type == "item" and rel.item[m.name])
                or (m.type == "fluid" and rel.fluid[m.name])
            if info then
                local best, best_score, best_ning = nil, -1, math.huge
                for _, prn in ipairs(info.recipe_for_product) do
                    local fr = force.recipes[prn]
                    if prototypes.recipe[prn] and not selected[prn] and not to_add[prn]
                        and fr and fr.enabled and allowed(prn) and structural_ok(fr) then
                        local crp = prototypes.recipe[prn]
                        local rscore = 0
                        for _, ing in ipairs(crp.ingredients) do
                            if reachable[ing.type .. "/" .. ing.name] then rscore = rscore + 1 end
                        end
                        local ning = #crp.ingredients
                        local take = rscore > best_score
                            or (rscore == best_score and ning < best_ning)
                            or (rscore == best_score and ning == best_ning and (not best or prn < best))
                        if take then best, best_score, best_ning = prn, rscore, ning end
                    end
                end
                if best then
                    to_add[best] = true
                    progressed = true
                end
            end
        end

        -- No eligible producer for any unreachable material: a genuine dead end
        -- (mass-losing loop / virtual-only supply). Stop and let the launcher
        -- report it via the unresolved note rather than spinning to the cap.
        if not progressed then break end

        local names = {}
        for n in pairs(to_add) do names[#names + 1] = n end
        table.sort(names)
        for _, n in ipairs(names) do
            if not selected[n] then
                selected[n] = true
                order[#order + 1] = n
                closure_added = closure_added + 1
            end
        end
    end

    -- Surface what closure could not bottom out, so a resulting cheat>0 can be
    -- read as a generator dead end (this list non-empty) versus a true solver
    -- finding (closed, yet the LP still leaned on the escape hatch). No silent
    -- cap: if closure stopped short, the leftover materials are named.
    local unresolved = {}
    if not closure_closed then
        local reachable = compute_reachable()
        local seen = {}
        for rn in pairs(selected) do
            local rp2 = prototypes.recipe[rn]
            if rp2 then
                for _, ing in ipairs(rp2.ingredients) do
                    local key = ing.type .. "/" .. ing.name
                    if not reachable[key] and not seen[key] then
                        seen[key] = true
                        unresolved[#unresolved + 1] = key
                    end
                end
            end
        end
        table.sort(unresolved)
    end

    return seed_recipe, order, nil, { added = closure_added, closed = closure_closed, unresolved = unresolved }
end

---Inspect a solved variable set. Reports the TRUE-signal cheat mass plus the
---(secondary) park fractions: all recipes, and excluding pyvoid waste recipes.
---@param vars PackedVariables?
---@return { recipes: integer, near_zero: integer, frac: number, recipes_nv: integer, near_zero_nv: integer, frac_nv: number, cheat: number, zeros: string[] }
function M.detect(vars)
    if not vars or not vars.x then
        return { recipes = 0, near_zero = 0, frac = 0, recipes_nv = 0,
            near_zero_nv = 0, frac_nv = 0, cheat = 0, zeros = {} }
    end

    -- Count only real production recipes. |bridge| temperature-conversion
    -- variables (keyed virtual_recipe/|bridge|...) are LP-internal plumbing
    -- create_problem injects, not recipes the user placed; they park whenever no
    -- temperature conversion is needed, so excluding them keeps the count about
    -- the user's chain rather than solver internals.
    local function is_recipe(k)
        if k:find("|bridge|", 1, true) then return false end
        return k:sub(1, 7) == "recipe/" or k:sub(1, 15) == "virtual_recipe/"
    end
    local function is_void(k)
        return k:find("pyvoid", 1, true) ~= nil
    end

    local max_x = 0
    for k, v in pairs(vars.x) do
        if is_recipe(k) and math.abs(v) > max_x then
            max_x = math.abs(v)
        end
    end
    local thresh = math.max(PARK_ABS, max_x * PARK_REL)

    local recipes, near_zero = 0, 0
    local recipes_nv, near_zero_nv = 0, 0
    local zeros = {}
    for k, v in pairs(vars.x) do
        if is_recipe(k) then
            recipes = recipes + 1
            local parked = math.abs(v) < thresh
            if parked then
                near_zero = near_zero + 1
                zeros[#zeros + 1] = k:match("^[%w_]+/(.+)/[^/]+$") or k
            end
            if not is_void(k) then
                recipes_nv = recipes_nv + 1
                if parked then near_zero_nv = near_zero_nv + 1 end
            end
        end
    end

    -- Total mass carried by the penalty escapes (shortage_source / elastic): a
    -- non-trivial value means the solution leaned on the cheat instead of real
    -- flow -- the TRUE undesirable signal.
    local cheat = 0
    for k, v in pairs(vars.x) do
        if math.abs(v) > thresh
            and (k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true)) then
            cheat = cheat + math.abs(v)
        end
    end

    return {
        recipes = recipes,
        near_zero = near_zero,
        frac = recipes > 0 and near_zero / recipes or 0,
        recipes_nv = recipes_nv,
        near_zero_nv = near_zero_nv,
        frac_nv = recipes_nv > 0 and near_zero_nv / recipes_nv or 0,
        cheat = cheat,
        zeros = zeros,
    }
end

---RCON entry point. Args string: "seed=N;hops=M;mode=both;void=ex". Builds one
---random chain, solves it, returns a single status line the launcher logs.
---  <<HIT  -> TRUE undesirable solution (non-convergence or cheat>0); investigate.
---  ~park  -> high park fraction (ex-pyvoid); usually a normal alternative, note only.
---@param args_str string?
---@return string
function M.explore(args_str)
    local params = {}
    for k, v in string.gmatch(args_str or "", "(%w+)=([%w%.%-]+)") do
        params[k] = v
    end
    local seed = math.floor(tonumber(params.seed) or 1)
    local hops = math.floor(tonumber(params.hops) or 12)
    local mode = params.mode or "both"
    local exclude_void = params.void == "ex"
    local exclude_source_sink = params.nosrc == "ex"
    local pins = math.max(1, math.floor(tonumber(params.pins) or 1))
    local use_quality = params.qual == "on"
    local target_quality = params.tq or "rare"

    save.init_force_data(FORCE_INDEX)
    save.init_player_data(PLAYER_INDEX)

    if use_quality then
        -- The smoke force defaults to unlocked_qualities = { normal }, so
        -- pre_solve.quality_decomposition stops at normal and never produces a
        -- high-quality product. A rare target would then be unreachable and the
        -- LP would dump it onto |elastic| (R=0, cheat=1) -- not a solver finding,
        -- just an un-researched force. Unlock every real quality so the
        -- decomposition (and the recycling loop) actually runs.
        local uq = {}
        for qname in pairs(prototypes.quality) do
            if qname ~= "quality-unknown" then uq[qname] = true end
        end
        storage.forces[FORCE_INDEX].research_bonuses.unlocked_qualities = uq
    end

    local ok_build, seed_recipe, order, err, closure =
        pcall(M.build_chain, seed, hops, mode, exclude_void, exclude_source_sink)
    if not ok_build then
        return string.format("ERROR seed=%d build raised: %s", seed, tostring(seed_recipe))
    end
    if not seed_recipe then
        return string.format("ERROR seed=%d %s", seed, tostring(err))
    end

    local solutions = storage.forces[FORCE_INDEX].solutions
    for name in pairs(solutions) do
        solutions[name] = nil
    end
    local sol_name = save.new_solution(solutions, "explore")
    local solution = assert(solutions[sol_name])

    local built = 0
    local built_names = {}
    for _, recipe_name in ipairs(order or {}) do
        local ok, line = pcall(make_line, recipe_name, use_quality)
        if ok and line then
            flib_table.insert(solution.production_lines, line)
            built = built + 1
            built_names[#built_names + 1] = recipe_name
        end
    end
    if built == 0 then
        return string.format("ERROR seed=%d no buildable lines (seed_recipe=%s)", seed, seed_recipe)
    end

    if use_quality then
        -- Target the seed recipe's main ITEM product at a high quality (fluids
        -- carry no quality). With quality modules on every line, the only way to
        -- hit a high-quality output is the upgrade-and-recycle loop, which is the
        -- structure that stresses the IPM. Falls back to a recipe pin when the
        -- seed has no item product.
        local item_product
        for _, p in ipairs(prototypes.recipe[seed_recipe].products) do
            if p.type == "item" then item_product = p; break end
        end
        if item_product then
            ---@type Constraint
            flib_table.insert(solution.constraints, {
                type = "item",
                name = item_product.name,
                quality = target_quality,
                limit_type = "equal",
                limit_amount_per_second = 1,
            })
        else
            flib_table.insert(solution.constraints, {
                type = "recipe",
                name = seed_recipe,
                quality = "normal",
                limit_type = "equal",
                limit_amount_per_second = 1,
            })
        end
    else
        -- Pin the seed recipe plus (pins-1) more built recipes. Multiple
        -- equal-pins impose simultaneous fixed throughputs that can fight over
        -- shared materials, which a single pin never forces. Only built recipes
        -- are pinnable (their LP variable exists). seed_recipe is pinned first
        -- when it was buildable.
        local pin_names = {}
        local seed_built = false
        for _, n in ipairs(built_names) do
            if n == seed_recipe then seed_built = true break end
        end
        if seed_built then pin_names[#pin_names + 1] = seed_recipe end
        if pins > #pin_names then
            local prng = game.create_random_generator((seed * 2246822519 + 99) % 4294967296)
            local pool = {}
            for _, n in ipairs(built_names) do
                if n ~= seed_recipe then pool[#pool + 1] = n end
            end
            table.sort(pool)
            while #pin_names < pins and #pool > 0 do
                local idx = prng(1, #pool)
                pin_names[#pin_names + 1] = pool[idx]
                table.remove(pool, idx)
            end
        end
        if #pin_names == 0 then pin_names[1] = built_names[1] end
        for _, pn in ipairs(pin_names) do
            ---@type Constraint
            flib_table.insert(solution.constraints, {
                type = "recipe",
                name = pn,
                quality = "normal",
                limit_type = "equal",
                limit_amount_per_second = 1,
            })
        end
    end

    -- Solve to a terminal state synchronously (forwerd_solve advances one IPM
    -- step per call, same state machine the on_tick pump drives).
    solution.solver_state = "ready"
    local force_data = storage.forces[FORCE_INDEX]
    local steps = 0
    while solution.solver_state == "ready" or solution.solver_state == "calculating" do
        local ok, solve_err = pcall(pre_solve.forwerd_solve, force_data, solution)
        if not ok then
            return string.format("ERROR seed=%d solve raised: %s (seed_recipe=%s built=%d)",
                seed, tostring(solve_err), seed_recipe, built)
        end
        steps = steps + 1
        if steps > 1200 then
            break
        end
    end

    local d = M.detect(solution.raw_variables)
    local converged = solution.solver_state == "finished"
    local true_hit = (not converged) or d.cheat > CHEAT_EPS
    local park_note = d.frac_nv >= PARK_NOTE_FRACTION
    log.info("explore seed=%d mode=%s void=%s hops=%d state=%s cheat=%.4g frac_nv=%.2f",
        seed, mode, exclude_void and "ex" or "in", hops, solution.solver_state, d.cheat, d.frac_nv)

    local tag = ""
    if true_hit then
        tag = "  <<HIT"
    elseif park_note then
        tag = "  ~park"
    end
    local parked = ""
    if (true_hit or park_note) and #d.zeros > 0 then
        table.sort(d.zeros)
        parked = " parked={" .. table.concat(d.zeros, ",") .. "}"
    end

    -- Closure note: how many bootstrap producers the generator had to add, and
    -- (when it could not bottom the chain out at raw resources) which materials
    -- stayed unreachable. A cheat>0 next to a non-empty unclosed set is a
    -- generator dead end, not a solver weakness -- this is the disambiguation
    -- the reachability rework exists to provide.
    local closure_note = ""
    if closure then
        if not closure.closed and #closure.unresolved > 0 then
            closure_note = string.format(" closure=add%d,unclosed={%s}",
                closure.added, table.concat(closure.unresolved, ","))
        elseif closure.added > 0 then
            closure_note = string.format(" closure=add%d", closure.added)
        end
    end

    return string.format(
        "seed=%d mode=%s void=%s nosrc=%s pins=%d qual=%s hops=%d state=%s built=%d R=%d nz=%d(%.0f%%) Rnv=%d(%.0f%%) cheat=%.4g steps=%d sr=%s%s%s%s",
        seed, mode, exclude_void and "ex" or "in", exclude_source_sink and "ex" or "in", pins,
        use_quality and target_quality or "off", hops,
        tostring(solution.solver_state), built,
        d.recipes, d.near_zero, d.frac * 100,
        d.recipes_nv, d.frac_nv * 100,
        d.cheat, steps, seed_recipe, closure_note, tag, parked)
end

---Diagnostic: normalize a single quality-module line and report the slot count,
---quality effectivity, and decomposed products -- to check whether quality
---modules actually drive decomposition. Args: "recipe=NAME;machine=NAME".
---@param args_str string?
---@return string
function M.diag(args_str)
    local params = {}
    for k, v in string.gmatch(args_str or "", "(%w+)=([%w%-]+)") do params[k] = v end
    save.init_force_data(FORCE_INDEX)
    save.init_player_data(PLAYER_INDEX)
    local bonuses = storage.forces[FORCE_INDEX].research_bonuses
    local uq = {}
    for q in pairs(prototypes.quality) do if q ~= "quality-unknown" then uq[q] = true end end
    bonuses.unlocked_qualities = uq

    local recipe = params.recipe or "iron-plate"
    local machine = params.machine or "assembling-machine-2"
    local mp = prototypes.entity[machine]
    local slots = (mp and acc.get_machine_module_inventory_size(mp, "normal")) or 0
    local modules = {}
    for i = 1, math.max(1, slots) do
        modules[tostring(i)] = tn.create_typed_name("item", "quality-module-3", "normal")
    end
    local line = {
        recipe_typed_name = tn.create_typed_name("recipe", recipe),
        machine_typed_name = tn.create_typed_name("machine", machine),
        module_typed_names = modules,
        affected_by_beacons = {},
    }
    local ok, n, eff = pcall(acc.normalize_production_line, line, bonuses)
    if not ok then return "ERR " .. tostring(n) end
    local out = { string.format("slots=%s eff_quality=%s nprod=%d",
        tostring(slots), tostring(eff and eff.quality), #n.products) }
    for _, p in ipairs(n.products) do
        out[#out + 1] = string.format("%s/%s=%.4g", p.name, tostring(p.quality), p.amount_per_second)
    end
    return table.concat(out, " | ")
end

---Diagnostic: dump the current solution's solve result -- constraints, the
---active penalty slacks (elastic / shortage / source / sink), and the top
---non-zero recipe variables. Call after an explore() so the solution is still
---in storage. Lets us see WHY a target was missed (which slack absorbed it) and
---whether the recycling/quality recipes actually ran.
---@return string
function M.detail()
    local fd = storage.forces[FORCE_INDEX]
    local _, sol = next(fd and fd.solutions or {})
    if not sol then return "no solution in storage" end

    local out = { "state=" .. tostring(sol.solver_state) }
    for _, c in ipairs(sol.constraints or {}) do
        out[#out + 1] = string.format("target %s/%s/%s %s=%g",
            c.type, c.name, tostring(c.quality), c.limit_type, c.limit_amount_per_second)
    end

    local x = (sol.raw_variables and sol.raw_variables.x) or {}

    -- Penalty slacks that actually carry flow: these say how the LP balanced the
    -- books (elastic = target relaxed, shortage = material fabricated, source =
    -- external input drawn, sink = surplus dumped).
    local slacks = {}
    for k, v in pairs(x) do
        if math.abs(v) > 1e-4 and (k:find("|elastic|", 1, true)
                or k:find("|shortage_source|", 1, true)
                or k:find("|initial_source|", 1, true)
                or k:find("|surplus_sink|", 1, true)) then
            slacks[#slacks + 1] = string.format("%s=%.3g", k, v)
        end
    end
    table.sort(slacks)
    out[#out + 1] = "slacks: " .. (next(slacks) and table.concat(slacks, "  ") or "(none)")

    -- Top active recipe variables (name only, quality suffix kept).
    local recs = {}
    for k, v in pairs(x) do
        if (k:sub(1, 7) == "recipe/" or k:sub(1, 15) == "virtual_recipe/") and math.abs(v) > 1e-4 then
            recs[#recs + 1] = { k = k:match("^[%w_]+/(.+)$") or k, v = v }
        end
    end
    table.sort(recs, function(a, b) return a.v > b.v end)
    local rl = {}
    for i = 1, math.min(#recs, 15) do
        rl[#rl + 1] = string.format("%s=%.3g", recs[i].k, recs[i].v)
    end
    out[#out + 1] = "active recipes (" .. #recs .. "): " .. table.concat(rl, "  ")

    return table.concat(out, "\n")
end

---Register the RCON interface (flat namespace -> factory_solver_ prefix). Not
---persisted across save/load, so control.lua calls it on every load in the
---smoke_rcon scenario.
function M.register()
    remote.add_interface("factory_solver_explore", {
        explore = M.explore,
        diag = M.diag,
        detail = M.detail,
    })
end

return M
