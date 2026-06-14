local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---@param machines LuaEntityPrototype[]
---@param any_fluid_fuels string[]
---@return string[]
local function collect_fluid_fuels(machines, any_fluid_fuels)
    local names = {}
    local seen = {}
    local include_any = false
    for _, machine in ipairs(machines) do
        if acc.is_use_any_fluid_fuel(machine) then
            include_any = true
        else
            local energy = machine.fluid_energy_source_prototype
            local filter = energy and energy.fluid_box.filter
            if filter and not seen[filter.name] then
                seen[filter.name] = true
                names[#names + 1] = filter.name
            end
        end
    end
    if include_any then
        for _, name in ipairs(any_fluid_fuels) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    return names
end

---Compute the fuel item names and fluid-fuel names for one category given its
---machines. Shared by the one-shot M.cache_fuel_names and the tick-split
---prep-fuel phases so both produce identical lists.
---@param machines LuaEntityPrototype[]
---@param any_fluid_fuels string[]
---@return string[] fuels
---@return string[] fluid_fuels
local function compute_category_fuels(machines, any_fluid_fuels)
    local fuel_categories = {}
    for _, machine in ipairs(machines) do
        local res = acc.try_get_fuel_categories(machine)
        if res then
            for key, _ in pairs(res) do
                fuel_categories[key] = true
            end
        end
    end
    local fuels = flib_table.map(acc.get_fuels_in_categories(fuel_categories), function(value)
        return value.name
    end)
    return fuels, collect_fluid_fuels(machines, any_fluid_fuels)
end

---@return string[]
local function get_any_fluid_fuel_names()
    return flib_table.map(acc.get_any_fluid_fuels(), function(value)
        return value.name
    end)
end

---comment
---@return table<string, string[]>, table<string, string[]>, table<string, string[]>, table<string, string[]>, string[]
function M.cache_fuel_names()
    local any_fluid_fuels = get_any_fluid_fuel_names()

    local cache_crafting_fuels = {}
    local cache_crafting_fluid_fuels = {}
    for crafting_category_name, _ in pairs(prototypes.recipe_category) do
        local machines = acc.get_machines_in_category(crafting_category_name)
        cache_crafting_fuels[crafting_category_name], cache_crafting_fluid_fuels[crafting_category_name] =
            compute_category_fuels(machines, any_fluid_fuels)
    end

    local cache_resource_fuels = {}
    local cache_resource_fluid_fuels = {}
    for resource_category_name, _ in pairs(prototypes.resource_category) do
        local machines = acc.get_machines_in_resource_category(resource_category_name)
        cache_resource_fuels[resource_category_name], cache_resource_fluid_fuels[resource_category_name] =
            compute_category_fuels(machines, any_fluid_fuels)
    end

    return cache_crafting_fuels, cache_resource_fuels,
        cache_crafting_fluid_fuels, cache_resource_fluid_fuels,
        any_fluid_fuels
end

---@param rel RelationToRecipes
---@param filter_type FilterType
---@param name string
---@return RelationToRecipe
local function get_info(rel, filter_type, name)
    if filter_type == "item" then
        return rel.item[name]
    elseif filter_type == "fluid" then
        return rel.fluid[name]
    elseif filter_type == "virtual_material" then
        return rel.virtual_recipe[name]
    else
        return assert()
    end
end

-- Virtual recipes have no per-force `enabled` flag; their researched-ness is
-- derived from the source entity (its `items_to_place_this` against the item
-- craftable_count) and, for entity-less tile / resource virtuals, from
-- `force.is_space_location_unlocked` against the planets that autoplace them.
-- Because entity_is_unresearched reads item craftable_count, this MUST run after
-- the real recipe product counts have settled -- see recompute_relation_dynamic.
---@param rel RelationToRecipes
---@param recipe VirtualRecipe
---@param force LuaForce
---@return boolean
local function compute_researched(rel, recipe, force)
    if recipe.source_entity_name then
        local entity = prototypes.entity[recipe.source_entity_name]
        if acc.entity_is_unresearched(entity, rel) then return false end
    end
    if recipe.source_planet_names then
        local any_unlocked = false
        for _, planet_name in ipairs(recipe.source_planet_names) do
            if force.is_space_location_unlocked(planet_name) then
                any_unlocked = true
                break
            end
        end
        if not any_unlocked then return false end
    end
    return true
end

---@return RelationToRecipe
local function create_relation_table()
    ---@type RelationToRecipe
    return { craftable_count = 0, recipe_for_ingredient = {}, recipe_for_product = {}, recipe_for_burnt_result = {}, fuel_consumer_categories = {}, fuel_consumer_virtual_recipes = {} }
end

-- A machine burning an item fuel emits that fuel's burnt_result (spent cell /
-- ash), so a recipe consuming the fuel is also a *producer* of the residue.
-- Register it under recipe_for_burnt_result -- NOT recipe_for_product -- so the
-- picker lists it in a dedicated "spent fuel" section instead of flooding the
-- product list with every fuel-burning recipe. The craftable_count credit for it
-- is applied later (recompute_relation_dynamic, or apply_research_change in the
-- split build's finalize). Fluid fuels have no burnt_result and never reach here.
---@param rel RelationToRecipes
---@param burnt_result_names table<string, string>
---@param fuel_item_name string
---@param recipe_name string
local function register_burnt_result(rel, burnt_result_names, fuel_item_name, recipe_name)
    local burnt_name = burnt_result_names[fuel_item_name]
    if burnt_name then
        flib_table.insert(rel.item[burnt_name].recipe_for_burnt_result, recipe_name)
        -- The consuming recipe makes the spent item craftable when it runs, so
        -- the residue is one of the recipe's contributions (see RelationContribution).
        local contrib = rel.contributes[recipe_name]
        contrib[#contrib + 1] = { type = "item", name = burnt_name }
    end
end

-- Resolve every fuel item's burnt_result once into an immutable item -> spent-item
-- NAME map (string-valued, not the LuaItemPrototype, so it stays storage-safe when
-- the build is split across ticks). A fuel would otherwise be resolved once per
-- (recipe, category) it can burn in -- ~389k times for only ~116 distinct fuels on
-- a pyanodon set.
---@return table<string, string>
local function build_burnt_result_names()
    local burnt_result_names = {} ---@type table<string, string>
    for name, item in pairs(prototypes.item) do
        local burnt = item.burnt_result
        if burnt then burnt_result_names[name] = burnt.name end
    end
    return burnt_result_names
end

---Bundle cache_fuel_names' five return values into one storage-safe table (all
---name-string arrays / maps) so the split build can carry it across ticks.
---@return RelationBuildFuelCache
local function build_fuel_cache()
    local crafting_fuels, resource_fuels,
        crafting_fluid_fuels, resource_fluid_fuels,
        any_fluid_fuels = M.cache_fuel_names()
    return {
        crafting_fuels = crafting_fuels,
        resource_fuels = resource_fuels,
        crafting_fluid_fuels = crafting_fluid_fuels,
        resource_fluid_fuels = resource_fluid_fuels,
        any_fluid_fuels = any_fluid_fuels,
    }
end

---Allocate the relation-cache skeleton: an empty RelationToRecipe per item / fluid
---/ virtual material, plus empty research-dependent fields. recipe_for_* lists are
---filled by process_real_recipe / process_virtual_recipe.
---@return RelationToRecipes
local function create_empty_rel()
    local items = {} ---@type table<string, RelationToRecipe>
    local fluids = {} ---@type table<string, RelationToRecipe>
    local virtuals = {} ---@type table<string, RelationToRecipe>
    for key, _ in pairs(prototypes.item) do items[key] = create_relation_table() end
    for key, _ in pairs(prototypes.fluid) do fluids[key] = create_relation_table() end
    for key, _ in pairs(storage.virtuals.material) do virtuals[key] = create_relation_table() end
    ---@type RelationToRecipes
    return {
        enabled_recipe = {},
        item = items,
        fluid = fluids,
        virtual_recipe = virtuals,
        virtual_recipe_researched = {},
        virtual_material_researched = {},
        recipes_by_category = {},
        contributes = {},
    }
end

---Add one real recipe's recipe-set contributions to rel: group it by category,
---record its products / ingredients on the materials' recipe_for_* lists, build its
---`contributes` entry, and register the spent-fuel residues of the fuels its
---category can burn. recipe-set-dependent only -- no enabled state is touched.
---@param rel RelationToRecipes
---@param recipe LuaRecipe
---@param fuel RelationBuildFuelCache
---@param burnt_result_names table<string, string>
local function process_real_recipe(rel, recipe, fuel, burnt_result_names)
    -- Group real recipes by category so a fuel's consumers expand lazily
    -- (category -> recipes) instead of being flattened per (recipe, fuel).
    local recipes_by_category = rel.recipes_by_category
    local cat_recipes = recipes_by_category[recipe.category]
    if not cat_recipes then
        cat_recipes = {}
        recipes_by_category[recipe.category] = cat_recipes
    end
    cat_recipes[#cat_recipes + 1] = recipe.name

    local contrib = {}
    rel.contributes[recipe.name] = contrib

    for _, value in ipairs(recipe.products) do
        flib_table.insert(get_info(rel, value.type, value.name).recipe_for_product, recipe.name)
        contrib[#contrib + 1] = { type = value.type, name = value.name }
    end
    for _, value in ipairs(recipe.ingredients) do
        flib_table.insert(get_info(rel, value.type, value.name).recipe_for_ingredient, recipe.name)
    end
    for _, value in ipairs(fuel.crafting_fuels[recipe.category]) do
        register_burnt_result(rel, burnt_result_names, value, recipe.name)
    end
end

-- Reverse cache_fuel_names' category -> fuel lists into each fuel material's
-- fuel_consumer_categories. This is the sum of category fuel-list sizes (~1k on
-- pyanodon), not the recipe x fuel product (~389k) a per-recipe recipe_for_fuel
-- insert would pay.
---@param rel RelationToRecipes
---@param fuel RelationBuildFuelCache
local function build_fuel_consumer_reverse(rel, fuel)
    for category, fuel_items in pairs(fuel.crafting_fuels) do
        for _, fuel_name in ipairs(fuel_items) do
            local info = rel.item[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end
    for category, fuel_fluids in pairs(fuel.crafting_fluid_fuels) do
        for _, fuel_name in ipairs(fuel_fluids) do
            local info = rel.fluid[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end
end

---Add one virtual recipe's recipe-set contributions to rel: its products /
---ingredients, and -- for a fixed-machine or resource virtual -- the fuels it
---consumes (and their spent-fuel residues). recipe-set-dependent only.
---@param rel RelationToRecipes
---@param recipe VirtualRecipe
---@param fuel RelationBuildFuelCache
---@param burnt_result_names table<string, string>
local function process_virtual_recipe(rel, recipe, fuel, burnt_result_names)
    local contrib = {}
    rel.contributes[recipe.name] = contrib

    for _, value in pairs(recipe.products) do
        flib_table.insert(get_info(rel, value.type, value.name).recipe_for_product, recipe.name)
        contrib[#contrib + 1] = { type = value.type, name = value.name }
    end
    for _, value in pairs(recipe.ingredients) do
        flib_table.insert(get_info(rel, value.type, value.name).recipe_for_ingredient, recipe.name)
    end

    if recipe.fixed_crafting_machine then
        local machine = tn.typed_name_to_machine(recipe.fixed_crafting_machine)

        local fixed_fuel = acc.try_get_fixed_fuel(machine)
        if fixed_fuel then
            flib_table.insert(get_info(rel, fixed_fuel.type, fixed_fuel.name).fuel_consumer_virtual_recipes, recipe.name)
            if fixed_fuel.type == "item" then
                register_burnt_result(rel, burnt_result_names, fixed_fuel.name, recipe.name)
            end
        end

        if acc.is_use_any_fluid_fuel(machine) then
            for _, value in ipairs(fuel.any_fluid_fuels) do
                flib_table.insert(get_info(rel, "fluid", value).fuel_consumer_virtual_recipes, recipe.name)
            end
        end

        local fuel_categories = acc.try_get_fuel_categories(machine)
        if fuel_categories then
            local fuels = acc.get_fuels_in_categories(fuel_categories)
            for _, value in ipairs(fuels) do
                flib_table.insert(get_info(rel, "item", value.name).fuel_consumer_virtual_recipes, recipe.name)
                register_burnt_result(rel, burnt_result_names, value.name, recipe.name)
            end
        end
    end

    if recipe.resource_category then
        for _, value in ipairs(fuel.resource_fuels[recipe.resource_category]) do
            flib_table.insert(get_info(rel, "item", value).fuel_consumer_virtual_recipes, recipe.name)
            register_burnt_result(rel, burnt_result_names, value, recipe.name)
        end
        for _, value in ipairs(fuel.resource_fluid_fuels[recipe.resource_category]) do
            flib_table.insert(get_info(rel, "fluid", value).fuel_consumer_virtual_recipes, recipe.name)
        end
    end
end

---Build the recipe-set-dependent half of RelationToRecipes: the recipe_for_* /
---recipes_by_category / fuel_consumer_* lists. These depend only on which recipes
---exist, which is stable across research (force.recipes holds every recipe
---regardless of `enabled`), so they are built once and reused. The
---research-dependent fields (enabled_recipe / craftable_count /
---virtual_recipe_researched) are left empty here and filled by
---recompute_relation_dynamic. This is the synchronous one-pass build; the
---tick-split equivalent (build_relation_init + build_relation_step) reuses the
---same process_* helpers, so both produce a field-for-field identical cache.
---@param force_index integer
---@return RelationToRecipes
local function build_relation_lists(force_index)
    local force = game.forces[force_index]
    local fuel = build_fuel_cache()
    local burnt_result_names = build_burnt_result_names()
    local rel = create_empty_rel()

    for _, recipe in pairs(force.recipes) do
        process_real_recipe(rel, recipe, fuel, burnt_result_names)
    end
    build_fuel_consumer_reverse(rel, fuel)
    for _, recipe in pairs(storage.virtuals.recipe) do
        process_virtual_recipe(rel, recipe, fuel, burnt_result_names)
    end

    return rel
end

---Create caches of relation to recipe for items, fluids and virtuals.
---@param force_index integer
---@return RelationToRecipes
function M.create_relation_to_recipes(force_index)
    local rel = build_relation_lists(force_index)
    M.recompute_relation_dynamic(rel, force_index)
    return rel
end

---Recompute only the research-dependent fields (enabled_recipe, craftable_count,
---virtual_recipe_researched) in place, reusing the recipe-set lists. Run on
---on_research_finished instead of a full create_relation_to_recipes: flipping a
---technology changes which recipes are enabled/researched, but not which recipes
---exist, so the lists are unchanged and only these fields move. Far cheaper than
---a rebuild -- no list allocation, and the spent-fuel credit is counted from
---recipe_for_burnt_result rather than by re-resolving every recipe's category
---fuels (the ~389k-iteration cost a rebuild pays).
---@param rel RelationToRecipes
---@param force_index integer
function M.recompute_relation_dynamic(rel, force_index)
    local force = game.forces[force_index]
    local contributes = rel.contributes

    local enabled_recipe = {} ---@type table<string, boolean>
    for name, recipe in pairs(force.recipes) do
        enabled_recipe[name] = recipe.enabled
    end
    rel.enabled_recipe = enabled_recipe

    for _, info in pairs(rel.item) do info.craftable_count = 0 end
    for _, info in pairs(rel.fluid) do info.craftable_count = 0 end
    for _, info in pairs(rel.virtual_recipe) do info.craftable_count = 0 end

    -- Real recipes first: each visible one credits its contributions (products +
    -- spent-fuel residues). Done before the virtual pass because compute_researched
    -- reads item craftable_count. Counting from `contributes` avoids re-reading
    -- recipe.products and re-resolving fuels.
    for _, recipe in pairs(force.recipes) do
        if recipe.enabled and not recipe.hidden then
            for _, m in ipairs(contributes[recipe.name]) do
                local info = get_info(rel, m.type, m.name)
                info.craftable_count = info.craftable_count + 1
            end
        end
    end

    local virtual_recipe_researched = {} ---@type table<string, boolean>
    for _, recipe in pairs(storage.virtuals.recipe) do
        local researched = compute_researched(rel, recipe, force)
        virtual_recipe_researched[recipe.name] = researched
        if researched and not recipe.hidden then
            for _, m in ipairs(contributes[recipe.name]) do
                local info = get_info(rel, m.type, m.name)
                info.craftable_count = info.craftable_count + 1
            end
        end
    end
    rel.virtual_recipe_researched = virtual_recipe_researched

    -- Virtual materials' researched state is derived from their source's
    -- craftable_count (now finalized); cache it so apply_research_change can detect
    -- flips for the group_infos incremental update.
    local virtual_material_researched = {} ---@type table<string, boolean>
    for name, vm in pairs(storage.virtuals.material) do
        virtual_material_researched[name] = not acc.is_unresearched(vm, rel)
    end
    rel.virtual_material_researched = virtual_material_researched
end

-- Tick-split relation build (driven from on_tick via manage/save.lua). The
-- synchronous create_relation_to_recipes walks every item / fluid / recipe in one
-- pass, which stalls a frame on large modpacks the first time a GUI reads the
-- cache. This spreads the recipe listing over ticks: build_relation_init allocates
-- the empty skeleton, build_relation_step walks each source table
-- RELATION_BUILD_BUDGET entries per call (resuming the pairs iterator from a stored
-- key), then the finalize phases credit the currently-enabled recipes -- also
-- tick-split. The listing phases are research-invariant (force.recipes holds every
-- recipe regardless of enabled), so a research finished while they run does not
-- invalidate them; the finalize phases read the live enabled flag, and once they
-- begin (structure_ready) a concurrent research is applied incrementally to the
-- in-flight rel rather than skipped (save.apply_research_change) -- the guarded
-- credits make that interleave idempotent.
local RELATION_BUILD_BUDGET = 100

-- Prep phases split the heavy one-shot setup across ticks: fuel-cache computation
-- per recipe/resource category, then per-material RelationToRecipe allocation
-- (item + burnt_result, fluid, virtual material). Every phase -- including the key
-- listing itself -- walks its source table directly via a stored-key pairs resume
-- (step_table), so no single tick pays a full pass. The all-false seed of the
-- research-dependent fields rides along on the phase that walks the matching table
-- (real -> enabled_recipe, virtual -> virtual_recipe_researched, vmat ->
-- virtual_material_researched), all complete before the finalize phases read them.
-- After prep, the listing phases run.
local RELATION_PHASE_PREP_FUEL_CRAFTING = "prep_fuel_crafting"
local RELATION_PHASE_PREP_FUEL_RESOURCE = "prep_fuel_resource"
local RELATION_PHASE_PREP_ALLOC_ITEM = "prep_alloc_item"
local RELATION_PHASE_PREP_ALLOC_FLUID = "prep_alloc_fluid"
local RELATION_PHASE_PREP_ALLOC_VMAT = "prep_alloc_vmat"
local RELATION_PHASE_REAL = "real_recipes"
local RELATION_PHASE_FUEL_REVERSE = "fuel_reverse"
local RELATION_PHASE_VIRTUAL = "virtual_recipes"
local RELATION_PHASE_FINALIZE_REAL = "finalize_real"
local RELATION_PHASE_FINALIZE_VRECIPE = "finalize_vrecipe"
local RELATION_PHASE_FINALIZE_VMAT = "finalize_vmat"
local RELATION_PHASE_DONE = "done"

---Process up to `budget` entries of the live table `t`, resuming after
---state.cursor_key (nil = from the start), calling fn(name, value) for each and
---advancing the cursor. Returns true once the table is exhausted (the caller then
---moves to the next phase; cursor_key is reset to nil so it starts fresh). Shared
---walk for every prep / listing phase.
---
---Holds only the last key -- a string, hence storage-safe across the tick-split --
---and re-derives the pairs iterator each call, resuming via the iterator function
---pairs() returns. This works for both LuaCustomTable (prototypes.* / force.recipes)
---and plain tables (storage.virtuals.*): raw next() rejects a LuaCustomTable
---(userdata), but the pairs iterator resumes from a stored key. Resume is O(1) for
---force.recipes and an O(position) -- but ~1.5ns/key -- scan for prototypes.item,
---paid once per call, so the spread is essentially free. In-game pairs order is
---deterministic and the resume yields the same sequence as a single pass, so the
---resulting recipe_for_* order matches the synchronous build.
---@param state RelationBuildState
---@param t table
---@param budget integer
---@param fn fun(name: string, value: any)
---@return boolean done
local function step_table(state, t, budget, fn)
    local iter, s = pairs(t)
    local key = state.cursor_key
    local processed = 0
    while processed < budget do
        local k, v = iter(s, key)
        if k == nil then
            state.cursor_key = nil
            return true
        end
        fn(k, v)
        key = k
        processed = processed + 1
    end
    state.cursor_key = key
    return false
end

---Start a tick-split relation build: allocate the empty cache skeleton and the
---any-fluid-fuel name list, then return the state armed at the first prep phase.
---Everything heavy -- fuel cache, per-material table allocation, burnt_result map,
---the recipe-set listing, and the all-false seed of the research-dependent fields --
---is deferred to build_relation_step's phases, which walk each source table directly
---via step_table's stored-key pairs resume so no single tick pays a full pass.
---
---The all-false seed (enabled_recipe / virtual_recipe_researched /
---virtual_material_researched) is required for correctness -- the finalize pass
---replays the live-enabled recipes through apply_research_change, which keys its flip
---test on the stored value, so a nil would be misread as a flip and wrongly debit
---craftable_count -- but it no longer happens here: each phase seeds the field for
---the table it walks (REAL -> enabled_recipe, VIRTUAL -> virtual_recipe_researched,
---PREP_ALLOC_VMAT -> virtual_material_researched), all complete before finalize.
---@return RelationBuildState
function M.build_relation_init()
    ---@type RelationToRecipes
    local rel = {
        enabled_recipe = {},
        item = {},
        fluid = {},
        virtual_recipe = {},
        virtual_recipe_researched = {},
        virtual_material_researched = {},
        recipes_by_category = {},
        contributes = {},
    }

    ---@type RelationBuildState
    return {
        phase = RELATION_PHASE_PREP_FUEL_CRAFTING,
        rel = rel,
        fuel = {
            crafting_fuels = {},
            resource_fuels = {},
            crafting_fluid_fuels = {},
            resource_fluid_fuels = {},
            any_fluid_fuels = get_any_fluid_fuel_names(),
        },
        burnt_result_names = {},
    }
end

---Advance an in-flight build by up to `budget` recipes (one phase per call).
---Returns true once the build has reached the done phase (state.rel is complete).
---@param state RelationBuildState
---@param force_index integer
---@param budget integer
---@return boolean done
local function build_relation_step(state, force_index, budget)
    local rel = state.rel

    if state.phase == RELATION_PHASE_PREP_FUEL_CRAFTING then
        local fuel = state.fuel
        if step_table(state, prototypes.recipe_category, budget, function(cat)
                fuel.crafting_fuels[cat], fuel.crafting_fluid_fuels[cat] =
                    compute_category_fuels(acc.get_machines_in_category(cat), fuel.any_fluid_fuels)
            end) then
            state.phase = RELATION_PHASE_PREP_FUEL_RESOURCE
        end
        return false
    elseif state.phase == RELATION_PHASE_PREP_FUEL_RESOURCE then
        local fuel = state.fuel
        if step_table(state, prototypes.resource_category, budget, function(cat)
                fuel.resource_fuels[cat], fuel.resource_fluid_fuels[cat] =
                    compute_category_fuels(acc.get_machines_in_resource_category(cat), fuel.any_fluid_fuels)
            end) then
            state.phase = RELATION_PHASE_PREP_ALLOC_ITEM
        end
        return false
    elseif state.phase == RELATION_PHASE_PREP_ALLOC_ITEM then
        -- Allocate item RelationToRecipe tables and resolve each item's burnt_result
        -- in the same item pass; the resume yields the item prototype as the value,
        -- so no second prototypes.item[name] lookup is needed.
        local burnt = state.burnt_result_names
        if step_table(state, prototypes.item, budget, function(name, item)
                rel.item[name] = create_relation_table()
                local b = item.burnt_result
                if b then burnt[name] = b.name end
            end) then
            state.phase = RELATION_PHASE_PREP_ALLOC_FLUID
        end
        return false
    elseif state.phase == RELATION_PHASE_PREP_ALLOC_FLUID then
        if step_table(state, prototypes.fluid, budget, function(name)
                rel.fluid[name] = create_relation_table()
            end) then
            state.phase = RELATION_PHASE_PREP_ALLOC_VMAT
        end
        return false
    elseif state.phase == RELATION_PHASE_PREP_ALLOC_VMAT then
        -- Allocate the virtual-material relation tables and seed each material's
        -- researched flag false (finalize flips the researched ones; a nil would be
        -- misread as a flip). Nothing between here and finalize reads it.
        if step_table(state, storage.virtuals.material, budget, function(name)
                rel.virtual_recipe[name] = create_relation_table()
                rel.virtual_material_researched[name] = false
            end) then
            state.phase = RELATION_PHASE_REAL
        end
        return false
    elseif state.phase == RELATION_PHASE_REAL then
        -- List real recipes and seed enabled_recipe false (finalize flips the live-
        -- enabled ones). The resume yields the live recipe as the value, so there is
        -- no force.recipes[name] re-lookup and no stale-entry guard: pairs only
        -- yields recipes that exist, and the set is research-stable (a config change
        -- that could remove one discards this whole state via reinit_force_data).
        local fuel, burnt = state.fuel, state.burnt_result_names
        if step_table(state, game.forces[force_index].recipes, budget, function(name, recipe)
                rel.enabled_recipe[name] = false
                process_real_recipe(rel, recipe, fuel, burnt)
            end) then
            state.phase = RELATION_PHASE_FUEL_REVERSE
        end
        return false
    elseif state.phase == RELATION_PHASE_FUEL_REVERSE then
        build_fuel_consumer_reverse(rel, state.fuel)
        state.phase = RELATION_PHASE_VIRTUAL
        return false
    elseif state.phase == RELATION_PHASE_VIRTUAL then
        -- List virtual recipes and seed virtual_recipe_researched false (finalize
        -- flips the researched ones). Same resume-yields-the-value shape as REAL.
        local fuel, burnt = state.fuel, state.burnt_result_names
        if step_table(state, storage.virtuals.recipe, budget, function(name, recipe)
                rel.virtual_recipe_researched[name] = false
                process_virtual_recipe(rel, recipe, fuel, burnt)
            end) then
            -- Listing done: contributes / seeds / virtual tables are all in place, so
            -- apply_research_change is now structurally safe. Flag it so a research
            -- finishing during the (tick-split) finalize is applied incrementally to
            -- this rel instead of skipped (save.apply_research_change). The finalize
            -- phases are guarded (idempotent), so an interleaved apply and a phase's
            -- own credit converge.
            state.structure_ready = true
            state.phase = RELATION_PHASE_FINALIZE_REAL
        end
        return false
    elseif state.phase == RELATION_PHASE_FINALIZE_REAL then
        -- Credit the currently-enabled real recipes (the listing seeded every
        -- enabled_recipe false). Walks force.recipes live, so a research finished
        -- during the listing phases is captured here by the live enabled flag. The
        -- flip guard (not already enabled_recipe[name]) makes this idempotent with
        -- any apply_research_change that interleaved once structure became ready.
        -- group_infos is rebuilt after the build, so credit with nil.
        local contributes = rel.contributes
        if step_table(state, game.forces[force_index].recipes, budget, function(name, recipe)
                if recipe.enabled and not rel.enabled_recipe[name] then
                    rel.enabled_recipe[name] = true
                    if not recipe.hidden then
                        for _, m in ipairs(contributes[name]) do
                            local info = get_info(rel, m.type, m.name)
                            info.craftable_count = info.craftable_count + 1
                        end
                    end
                end
            end) then
            state.phase = RELATION_PHASE_FINALIZE_VRECIPE
        end
        return false
    elseif state.phase == RELATION_PHASE_FINALIZE_VRECIPE then
        -- Evaluate each virtual recipe's researched state against the now-final real
        -- craftable_count (the real-before-virtual order recompute_relation_dynamic
        -- relies on) and credit the researched non-hidden ones. The researched flip
        -- guard keeps it idempotent with an interleaved apply.
        local force = game.forces[force_index]
        local contributes = rel.contributes
        if step_table(state, storage.virtuals.recipe, budget, function(name, recipe)
                local now = compute_researched(rel, recipe, force)
                if now ~= rel.virtual_recipe_researched[name] then
                    rel.virtual_recipe_researched[name] = now
                    if not recipe.hidden then
                        local d = now and 1 or -1
                        for _, m in ipairs(contributes[name]) do
                            local info = get_info(rel, m.type, m.name)
                            info.craftable_count = info.craftable_count + d
                        end
                    end
                end
            end) then
            state.phase = RELATION_PHASE_FINALIZE_VMAT
        end
        return false
    elseif state.phase == RELATION_PHASE_FINALIZE_VMAT then
        -- Virtual materials' researched state derives from their source's (now-final)
        -- craftable_count. No craftable credit -- this only records the flag (a later
        -- group_infos rebuild consumes it). Guarded flip. Last phase: done on exhaust.
        if step_table(state, storage.virtuals.material, budget, function(name, vm)
                local now = not acc.is_unresearched(vm, rel)
                if now ~= rel.virtual_material_researched[name] then
                    rel.virtual_material_researched[name] = now
                end
            end) then
            state.phase = RELATION_PHASE_DONE
            return true
        end
        return false
    end

    return true
end

---Advance a build by one tick's worth (RELATION_BUILD_BUDGET recipes). Returns the
---finished cache when done, nil while still building.
---@param state RelationBuildState
---@param force_index integer
---@return RelationToRecipes?
function M.advance_relation_build(state, force_index)
    if build_relation_step(state, force_index, RELATION_BUILD_BUDGET) then
        return state.rel
    end
    return nil
end

---Run a build to completion synchronously -- the get_relation_to_recipes fallback
---for when a GUI needs the cache before the on_tick driver has finished it. Walks
---every remaining phase (including the finalize apply) and returns the cache.
---@param state RelationBuildState
---@param force_index integer
---@return RelationToRecipes
function M.finish_relation_build(state, force_index)
    while not build_relation_step(state, force_index, math.huge) do end
    return state.rel
end

---Credit (delta=+1) or debit (delta=-1) a material's craftable_count for one
---recipe contribution, and -- when group_infos is provided -- move its group's
---researched<->unresearched count if craftable_count crossed 0. Item/fluid only:
---a virtual_material's group is driven by its source via is_unresearched, handled
---in apply_research_change's virtual-material pass, so here it just adjusts the
---count. Hidden/parameter prototypes are counted in hidden_count, never moved.
---@param rel RelationToRecipes
---@param group_infos GroupInfos?
---@param m RelationContribution
---@param delta integer
local function credit_material(rel, group_infos, m, delta)
    local info = get_info(rel, m.type, m.name)
    local before = info.craftable_count
    info.craftable_count = before + delta
    if not group_infos or (before > 0) == (info.craftable_count > 0) then return end
    local proto, group_table
    if m.type == "item" then
        proto = prototypes.item[m.name]; group_table = group_infos.item
    elseif m.type == "fluid" then
        proto = prototypes.fluid[m.name]; group_table = group_infos.fluid
    else
        return
    end
    if proto.parameter or proto.hidden then return end
    local g = group_table[proto.group.name]
    if info.craftable_count > 0 then
        g.unresearched_count = g.unresearched_count - 1
        g.researched_count = g.researched_count + 1
    else
        g.researched_count = g.researched_count - 1
        g.unresearched_count = g.unresearched_count + 1
    end
end

---Move one group's researched<->unresearched count by one (a recipe enabled or a
---virtual researched flip). hidden_count is never touched -- hidden is invariant
---across research.
---@param group_table table<string, GroupInfo>
---@param group_name string
---@param now_researched boolean
local function move_group(group_table, group_name, now_researched)
    local g = group_table[group_name]
    if now_researched then
        g.unresearched_count = g.unresearched_count - 1
        g.researched_count = g.researched_count + 1
    else
        g.researched_count = g.researched_count - 1
        g.unresearched_count = g.unresearched_count + 1
    end
end

---Incrementally apply a technology's recipe unlocks (on_research_finished) or
---reverts (on_research_reversed) to an already-built relation_to_recipes, instead
---of a full rebuild. `recipe_names` are the unlock-recipe targets from the
---technology's effects; `now_enabled` is true for finish, false for reverse.
---Updates enabled_recipe and the affected materials' craftable_count via
---`contributes` (products and spent-fuel residues both), then any virtual recipe
---whose researched-ness flips because a placement item just became (un)craftable
---or a planet (un)locked, then any virtual material whose source flipped. Virtual
---products are never placement items, so flips cannot cascade -- single passes
---suffice. When `group_infos` is non-nil it is patched in lockstep (every
---researched<->unresearched move mirrored); pass nil to update relation only and
---leave a full group_infos rebuild pending.
---@param rel RelationToRecipes
---@param group_infos GroupInfos?
---@param force_index integer
---@param recipe_names string[]
---@param now_enabled boolean
function M.apply_research_change(rel, group_infos, force_index, recipe_names, now_enabled)
    local force = game.forces[force_index]
    local contributes = rel.contributes
    local delta = now_enabled and 1 or -1

    for _, recipe_name in ipairs(recipe_names) do
        if rel.enabled_recipe[recipe_name] ~= now_enabled then
            rel.enabled_recipe[recipe_name] = now_enabled
            local recipe = prototypes.recipe[recipe_name]
            if recipe and not recipe.hidden then
                if group_infos and not recipe.parameter then
                    move_group(group_infos.recipe, recipe.group.name, now_enabled)
                end
                for _, m in ipairs(contributes[recipe_name] or {}) do
                    credit_material(rel, group_infos, m, delta)
                end
            end
        end
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        local was = rel.virtual_recipe_researched[recipe.name]
        local now = compute_researched(rel, recipe, force)
        if now ~= was then
            rel.virtual_recipe_researched[recipe.name] = now
            if not recipe.hidden then
                if group_infos then
                    local bucket = (recipe.is_source or recipe.is_sink) and group_infos.external or group_infos.virtual_recipe
                    move_group(bucket, recipe.group_name, now)
                end
                local vdelta = now and 1 or -1
                for _, m in ipairs(contributes[recipe.name] or {}) do
                    credit_material(rel, group_infos, m, vdelta)
                end
            end
        end
    end

    -- Virtual materials: researched is derived from a source fluid/entity whose
    -- craftable_count may have changed above. Re-evaluate all and move the group
    -- count for any that flipped. Kept in sync even without group_infos so a later
    -- apply still detects flips correctly.
    for name, vm in pairs(storage.virtuals.material) do
        local was = rel.virtual_material_researched[name]
        local now = not acc.is_unresearched(vm, rel)
        if now ~= was then
            rel.virtual_material_researched[name] = now
            if group_infos and not acc.is_hidden(vm) then
                move_group(group_infos.virtual_recipe, vm.group_name, now)
            end
        end
    end
end

---Expand a material's lazy fuel-consumer representation into the flat list of
---recipe names that burn it as fuel: real recipes via category indirection
---(fuel_consumer_categories x recipes_by_category) plus the directly-listed
---virtual recipes. The flat list is never stored -- it is the recipe x fuel
---product that dominated create_relation_to_recipes -- so the picker materializes
---it on demand for the single selected material.
---@param relation_to_recipes RelationToRecipes
---@param info RelationToRecipe
---@return string[]
function M.expand_fuel_consumers(relation_to_recipes, info)
    local result = {}
    local by_category = relation_to_recipes.recipes_by_category
    for _, category in ipairs(info.fuel_consumer_categories) do
        local recipes = by_category[category]
        if recipes then
            for _, recipe_name in ipairs(recipes) do
                result[#result + 1] = recipe_name
            end
        end
    end
    for _, recipe_name in ipairs(info.fuel_consumer_virtual_recipes) do
        result[#result + 1] = recipe_name
    end
    return result
end

---Create caches of additional information for groups.
---@param force_index integer
---@param relation_to_recipes RelationToRecipes
---@return GroupInfos
function M.create_group_infos(force_index, relation_to_recipes)
    local force = game.forces[force_index]
    local items = {} ---@type table<string, GroupInfo>
    local fluids = {} ---@type table<string, GroupInfo>
    local recipes = {} ---@type table<string, GroupInfo>
    local virtuals = {} ---@type table<string, GroupInfo>
    -- External source/sink recipes are split off into their own group counts so
    -- they populate the constraint picker's dedicated "External" tab and stop
    -- burying the genuine virtual recipes (boiler / mining / spoilage / ...) in
    -- the Virtual tab.
    local externals = {} ---@type table<string, GroupInfo>

    for key, _ in pairs(prototypes.item_group) do
        items[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        fluids[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        recipes[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        virtuals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
        externals[key] = { hidden_count = 0, researched_count = 0, unresearched_count = 0 }
    end

    for _, recipe in pairs(force.recipes) do
        if not prototypes.recipe[recipe.name].parameter then
            local recipe_group = recipes[recipe.group.name]
            if recipe.hidden then
                recipe_group.hidden_count = recipe_group.hidden_count + 1
            elseif recipe.enabled then
                recipe_group.researched_count = recipe_group.researched_count + 1
            else
                recipe_group.unresearched_count = recipe_group.unresearched_count + 1
            end
        end
    end

    for key, item in pairs(prototypes.item) do
        if not item.parameter then
            local item_group = items[item.group.name]
            if item.hidden then
                item_group.hidden_count = item_group.hidden_count + 1
            elseif 0 < relation_to_recipes.item[key].craftable_count then
                item_group.researched_count = item_group.researched_count + 1
            else
                item_group.unresearched_count = item_group.unresearched_count + 1
            end
        end
    end

    for key, fluid in pairs(prototypes.fluid) do
        if not fluid.parameter then
            local fluid_group = fluids[fluid.group.name]
            if fluid.hidden then
                fluid_group.hidden_count = fluid_group.hidden_count + 1
            elseif 0 < relation_to_recipes.fluid[key].craftable_count then
                fluid_group.researched_count = fluid_group.researched_count + 1
            else
                fluid_group.unresearched_count = fluid_group.unresearched_count + 1
            end
        end
    end

    for _, virtual_material in pairs(storage.virtuals.material) do
        local virtual_group = virtuals[virtual_material.group_name]
        if acc.is_hidden(virtual_material) then
            virtual_group.hidden_count = virtual_group.hidden_count + 1
        elseif acc.is_unresearched(virtual_material, relation_to_recipes) then
            virtual_group.unresearched_count = virtual_group.unresearched_count + 1
        else
            virtual_group.researched_count = virtual_group.researched_count + 1
        end
    end

    for _, virtual_recipe in pairs(storage.virtuals.recipe) do
        -- Route source/sink into the External group counts; everything else
        -- stays in the Virtual counts.
        local bucket = (virtual_recipe.is_source or virtual_recipe.is_sink) and externals or virtuals
        local virtual_group = bucket[virtual_recipe.group_name]
        if acc.is_hidden(virtual_recipe) then
            virtual_group.hidden_count = virtual_group.hidden_count + 1
        elseif acc.is_unresearched(virtual_recipe, relation_to_recipes) then
            virtual_group.unresearched_count = virtual_group.unresearched_count + 1
        else
            virtual_group.researched_count = virtual_group.researched_count + 1
        end
    end

    return { item = items, fluid = fluids, recipe = recipes, virtual_recipe = virtuals, external = externals }
end

return M
