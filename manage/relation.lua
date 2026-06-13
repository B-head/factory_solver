local flib_table = require "__flib__/table"
local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---comment
---@return table<string, string[]>, table<string, string[]>, table<string, string[]>, table<string, string[]>, string[]
function M.cache_fuel_names()
    local any_fluid_fuels = flib_table.map(acc.get_any_fluid_fuels(), function(value)
        return value.name
    end)

    ---@param machines LuaEntityPrototype[]
    ---@return string[]
    local function collect_fluid_fuels(machines)
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

    local cache_crafting_fuels = {}
    local cache_crafting_fluid_fuels = {}
    for crafting_category_name, _ in pairs(prototypes.recipe_category) do
        local machines = acc.get_machines_in_category(crafting_category_name)

        local fuel_categories = {}
        for _, machine in ipairs(machines) do
            local res = acc.try_get_fuel_categories(machine)
            if not res then
                goto continue
            end
            for key, _ in pairs(res) do
                fuel_categories[key] = true
            end
            ::continue::
        end

        local fuels = acc.get_fuels_in_categories(fuel_categories)
        cache_crafting_fuels[crafting_category_name] = flib_table.map(fuels, function(value)
            return value.name
        end)
        cache_crafting_fluid_fuels[crafting_category_name] = collect_fluid_fuels(machines)
    end

    local cache_resource_fuels = {}
    local cache_resource_fluid_fuels = {}
    for resource_category_name, _ in pairs(prototypes.resource_category) do
        local machines = acc.get_machines_in_resource_category(resource_category_name)

        local fuel_categories = {}
        for _, machine in ipairs(machines) do
            local res = acc.try_get_fuel_categories(machine)
            if not res then
                goto continue
            end
            for key, _ in pairs(res) do
                fuel_categories[key] = true
            end
            ::continue::
        end

        local fuels = acc.get_fuels_in_categories(fuel_categories)
        cache_resource_fuels[resource_category_name] = flib_table.map(fuels, function(value)
            return value.name
        end)
        cache_resource_fluid_fuels[resource_category_name] = collect_fluid_fuels(machines)
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

---Build the recipe-set-dependent half of RelationToRecipes: the recipe_for_* /
---recipes_by_category / fuel_consumer_* lists. These depend only on which recipes
---exist, which is stable across research (force.recipes holds every recipe
---regardless of `enabled`), so they are built once and reused. The
---research-dependent fields (enabled_recipe / craftable_count /
---virtual_recipe_researched) are left empty here and filled by
---recompute_relation_dynamic.
---@param force_index integer
---@return RelationToRecipes
local function build_relation_lists(force_index)
    local force = game.forces[force_index]
    local items = {} ---@type table<string, RelationToRecipe>
    local fluids = {} ---@type table<string, RelationToRecipe>
    local virtuals = {} ---@type table<string, RelationToRecipe>
    local recipes_by_category = {} ---@type table<string, string[]>

    local cache_crafting_fuels, cache_resource_fuels,
        cache_crafting_fluid_fuels, cache_resource_fluid_fuels,
        any_fluid_fuels = M.cache_fuel_names()

    ---@return RelationToRecipe
    local function create_relation_table()
        ---@type RelationToRecipe
        return { craftable_count = 0, recipe_for_ingredient = {}, recipe_for_product = {}, recipe_for_burnt_result = {}, fuel_consumer_categories = {}, fuel_consumer_virtual_recipes = {} }
    end

    for key, _ in pairs(prototypes.item) do
        items[key] = create_relation_table()
    end
    for key, _ in pairs(prototypes.fluid) do
        fluids[key] = create_relation_table()
    end
    for key, _ in pairs(storage.virtuals.material) do
        virtuals[key] = create_relation_table()
    end

    local contributes = {} ---@type table<string, RelationContribution[]>

    ---@type RelationToRecipes
    local rel = {
        enabled_recipe = {},
        item = items,
        fluid = fluids,
        virtual_recipe = virtuals,
        virtual_recipe_researched = {},
        virtual_material_researched = {},
        recipes_by_category = recipes_by_category,
        contributes = contributes,
    }

    -- A machine burning an item fuel emits that fuel's burnt_result (spent cell /
    -- ash), so a recipe consuming the fuel is also a *producer* of the residue.
    -- Register it under recipe_for_burnt_result -- NOT recipe_for_product -- so the
    -- picker lists it in a dedicated "spent fuel" section instead of flooding the
    -- product list with every fuel-burning recipe. The craftable_count credit for
    -- it is applied later, from this list, by recompute_relation_dynamic. Fluid
    -- fuels have no burnt_result and never reach here.
    --
    -- A fuel is registered once per (recipe, category) it can burn in -- ~389k
    -- times for only ~116 distinct fuels on a pyanodon set -- so resolve
    -- burnt_result once up front into an immutable item -> spent-item NAME map
    -- (string-valued, not the LuaItemPrototype, so it stays storage-safe if this
    -- is ever split across ticks).
    local burnt_result_names = {} ---@type table<string, string>
    for name, item in pairs(prototypes.item) do
        local burnt = item.burnt_result
        if burnt then burnt_result_names[name] = burnt.name end
    end
    ---@param fuel_item_name string
    ---@param recipe_name string
    local function register_burnt_result(fuel_item_name, recipe_name)
        local burnt_name = burnt_result_names[fuel_item_name]
        if burnt_name then
            flib_table.insert(items[burnt_name].recipe_for_burnt_result, recipe_name)
            -- The consuming recipe makes the spent item craftable when it runs, so
            -- the residue is one of the recipe's contributions (see RelationContribution).
            local contrib = contributes[recipe_name]
            contrib[#contrib + 1] = { type = "item", name = burnt_name }
        end
    end

    for _, recipe in pairs(force.recipes) do
        -- Group real recipes by category so a fuel's consumers expand lazily
        -- (category -> recipes) instead of being flattened per (recipe, fuel).
        local cat_recipes = recipes_by_category[recipe.category]
        if not cat_recipes then
            cat_recipes = {}
            recipes_by_category[recipe.category] = cat_recipes
        end
        cat_recipes[#cat_recipes + 1] = recipe.name

        local contrib = {}
        contributes[recipe.name] = contrib

        for _, value in ipairs(recipe.products) do
            flib_table.insert(get_info(rel, value.type, value.name).recipe_for_product, recipe.name)
            contrib[#contrib + 1] = { type = value.type, name = value.name }
        end
        for _, value in ipairs(recipe.ingredients) do
            flib_table.insert(get_info(rel, value.type, value.name).recipe_for_ingredient, recipe.name)
        end
        for _, value in ipairs(cache_crafting_fuels[recipe.category]) do
            register_burnt_result(value, recipe.name)
        end
    end

    -- Reverse cache_fuel_names' category -> fuel lists into each fuel material's
    -- fuel_consumer_categories. This is the sum of category fuel-list sizes
    -- (~1k on pyanodon), not the recipe x fuel product (~389k) a per-recipe
    -- recipe_for_fuel insert would pay.
    for category, fuel_items in pairs(cache_crafting_fuels) do
        for _, fuel_name in ipairs(fuel_items) do
            local info = items[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end
    for category, fuel_fluids in pairs(cache_crafting_fluid_fuels) do
        for _, fuel_name in ipairs(fuel_fluids) do
            local info = fluids[fuel_name]
            if info then
                info.fuel_consumer_categories[#info.fuel_consumer_categories + 1] = category
            end
        end
    end

    for _, recipe in pairs(storage.virtuals.recipe) do
        local contrib = {}
        contributes[recipe.name] = contrib

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
                    register_burnt_result(fixed_fuel.name, recipe.name)
                end
            end

            if acc.is_use_any_fluid_fuel(machine) then
                for _, value in ipairs(any_fluid_fuels) do
                    flib_table.insert(get_info(rel, "fluid", value).fuel_consumer_virtual_recipes, recipe.name)
                end
            end

            local fuel_categories = acc.try_get_fuel_categories(machine)
            if fuel_categories then
                local fuels = acc.get_fuels_in_categories(fuel_categories)
                for _, value in ipairs(fuels) do
                    flib_table.insert(get_info(rel, "item", value.name).fuel_consumer_virtual_recipes, recipe.name)
                    register_burnt_result(value.name, recipe.name)
                end
            end
        end

        if recipe.resource_category then
            for _, value in ipairs(cache_resource_fuels[recipe.resource_category]) do
                flib_table.insert(get_info(rel, "item", value).fuel_consumer_virtual_recipes, recipe.name)
                register_burnt_result(value, recipe.name)
            end
            for _, value in ipairs(cache_resource_fluid_fuels[recipe.resource_category]) do
                flib_table.insert(get_info(rel, "fluid", value).fuel_consumer_virtual_recipes, recipe.name)
            end
        end
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
