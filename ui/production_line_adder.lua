local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"

---[a_lo,a_hi] ⊆ [b_lo,b_hi]
local function range_subset(a_lo, a_hi, b_lo, b_hi)
    return b_lo <= a_lo and a_hi <= b_hi
end

---The candidate recipe's fluid-slot temperature range relevant to `kind`,
---returned as (lo, hi), or nil when it has no single well-defined range (then
---the candidate is never filtered out). `recipe` is a real LuaRecipePrototype
---or a plain-table VirtualRecipe.
---@param recipe LuaRecipePrototype | VirtualRecipe
---@param fluid_name string
---@param kind string
---@return number?, number?
local function candidate_fluid_range(recipe, fluid_name, kind)
    if kind == "product" then
        for _, p in ipairs(recipe.products) do
            if p.type == "fluid" and p.name == fluid_name then
                -- A product comes out at a single temperature; bare resolves to
                -- the degenerate [default, default].
                return acc.resolve_bare_fluid_product(fluid_name, p.temperature, p.temperature)
            end
        end
    elseif kind == "ingredient" then
        for _, ing in ipairs(recipe.ingredients) do
            if ing.type == "fluid" and ing.name == fluid_name then
                if ing.temperature ~= nil then
                    return ing.temperature, ing.temperature
                end
                return acc.resolve_bare_fluid_ingredient(fluid_name,
                    ing.minimum_temperature, ing.maximum_temperature)
            end
        end
    elseif kind == "fuel" then
        -- Only a virtual recipe pins a single machine, whose fixed fuel intake is
        -- the acceptance range. Real-recipe category fuels and any-fluid-fuel have
        -- no single range, so they stay unfiltered (nil). Guard the
        -- fixed_crafting_machine read: a real LuaRecipePrototype (userdata) throws
        -- on unknown keys, while a VirtualRecipe is a plain table (object_name nil).
        if recipe.object_name == nil and recipe.fixed_crafting_machine then
            local machine = tn.typed_name_to_machine(recipe.fixed_crafting_machine)
            local fuel = acc.try_get_fixed_fuel(machine)
            if fuel and fuel.type == "fluid" and fuel.name == fluid_name then
                return fuel.minimum_temperature, fuel.maximum_temperature
            end
        end
    end
    return nil
end

---Keep only recipes whose referenced-fluid slot is LP-connectable to the
---referenced temperature: producer_range ⊆ consumer_range, the same rule the
---temperature bridges use. A non-fluid or temperature-less reference (e.g. a
---bare fluid constraint) filters nothing. A candidate with no well-defined slot
---range is kept.
---@param reference TypedName
---@param recipe_names string[]
---@param kind string
---@return string[]
local function compatible_recipe_names(reference, recipe_names, kind)
    if reference.type ~= "fluid" or reference.minimum_temperature == nil then
        return recipe_names
    end
    local ref_lo = reference.minimum_temperature
    local ref_hi = reference.maximum_temperature
    local out = {}
    for _, name in ipairs(recipe_names) do
        local recipe = storage.virtuals.recipe[name] or prototypes.recipe[name]
        local keep = true
        if recipe then
            local c_lo, c_hi = candidate_fluid_range(recipe, reference.name, kind)
            if c_lo ~= nil then
                if kind == "product" then
                    -- candidate is the producer, reference the consumer
                    keep = range_subset(c_lo, c_hi, ref_lo, ref_hi)
                else
                    -- ingredient / fuel: reference is the producer, candidate the consumer
                    keep = range_subset(ref_lo, ref_hi, c_lo, c_hi)
                end
            end
        end
        if keep then
            out[#out + 1] = name
        end
    end
    return out
end

local handlers = {}

---@param event EventDataTrait
function handlers.on_init_choose_visiblity(event)
    local elem = event.element
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local reference_typed_name = dialog_tags.typed_name --[[@as TypedName]]
    dialog_tags.recipe_quality = reference_typed_name.quality
    dialog_tags.recipe_quality_multi = { [reference_typed_name.quality] = true }
    dialog_tags.is_multi_mode = false
    dialog.tags = dialog_tags

    local kind = elem.tags.kind --[[@as string]]
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local relation_to_recipe
    if reference_typed_name.type == "item" then
        relation_to_recipe = relation_to_recipes.item[reference_typed_name.name]
    elseif reference_typed_name.type == "fluid" then
        relation_to_recipe = relation_to_recipes.fluid[reference_typed_name.name]
    elseif reference_typed_name.type == "virtual_material" then
        relation_to_recipe = relation_to_recipes.virtual_recipe[reference_typed_name.name]
    else
        assert()
    end

    -- Visibility must reflect the temperature-filtered count, so a section that
    -- ends up empty after filtering is hidden.
    local allowed, recipe_names
    if kind == "product" then
        allowed, recipe_names = dialog_tags.is_choose_product, relation_to_recipe.recipe_for_product
    elseif kind == "ingredient" then
        allowed, recipe_names = dialog_tags.is_choose_ingredient, relation_to_recipe.recipe_for_ingredient
    elseif kind == "fuel" then
        allowed, recipe_names = dialog_tags.is_choose_ingredient, relation_to_recipe.recipe_for_fuel
    else
        assert()
    end
    elem.visible = allowed
        and 0 < #compatible_recipe_names(reference_typed_name, recipe_names, kind)
end

---@param event EventDataTrait
function handlers.on_make_choose_table(event)
    local elem = event.element
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local player_data = save.get_player_data(event.player_index)
    local kind = elem.tags.kind --[[@as string]]
    local choose_typed_name = dialog_tags.typed_name --[[@as TypedName]]
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    local relation_to_recipe
    if choose_typed_name.type == "item" then
        relation_to_recipe = relation_to_recipes.item[choose_typed_name.name]
    elseif choose_typed_name.type == "fluid" then
        relation_to_recipe = relation_to_recipes.fluid[choose_typed_name.name]
    elseif choose_typed_name.type == "virtual_material" then
        relation_to_recipe = relation_to_recipes.virtual_recipe[choose_typed_name.name]
    else
        assert()
    end

    local recipe_names
    if kind == "product" then
        recipe_names = relation_to_recipe.recipe_for_product
    elseif kind == "ingredient" then
        recipe_names = relation_to_recipe.recipe_for_ingredient
    elseif kind == "fuel" then
        recipe_names = relation_to_recipe.recipe_for_fuel
    else
        assert()
    end
    recipe_names = compatible_recipe_names(choose_typed_name, recipe_names, kind)

    local used_recipes = flib_table.map(recipe_names, function(name)
        return assert(storage.virtuals.recipe[name] or prototypes.recipe[name])
    end) --[=[@as (LuaRecipePrototype | VirtualRecipe)[]]=]

    local grouped = fs_util.group_by(used_recipes, function(value)
        if value.group then
            return value.group.name
        else
            return value.group_name
        end
    end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]

    local groups = fs_util.to_list(prototypes.item_group)
    groups = fs_util.sort_prototypes(groups)

    elem.clear()
    for _, group in ipairs(groups) do
        local group_name = group.name

        local group_recipes = grouped[group_name] or {}
        local subgrouped = fs_util.group_by(group_recipes, function(value)
            if value.subgroup then
                return value.subgroup.name
            else
                return value.subgroup_name
            end
        end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]

        local subgroups = fs_util.to_list(group.subgroups)
        subgroups = fs_util.sort_prototypes(subgroups)

        local def_buttons = {}
        for _, subgroup in ipairs(subgroups) do
            local subgroup_recipes = subgrouped[subgroup.name] or {}
            local sorted = fs_util.sort_prototypes(fs_util.to_list(subgroup_recipes))
            for _, recipe in ipairs(sorted) do
                local typed_name = tn.craft_to_typed_name(recipe)
                local is_hidden = acc.is_hidden(recipe)
                local is_unresearched = acc.is_unresearched(recipe, relation_to_recipes)
                if not common.craft_visible(is_hidden, is_unresearched, player_data) then
                    goto inner_continue
                end

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    tags = {
                        recipe_typed_name = typed_name,
                        kind = kind
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_picker_button_click,
                    },
                }
                flib_table.insert(def_buttons, def)
                ::inner_continue::
            end
        end

        if #def_buttons == 0 then
            goto outer_continue
        end

        local def_sprite = {
            type = "sprite",
            style = "factory_solver_group_sprite",
            sprite = "item-group/" .. group_name,
            resize_to_sprite = false,
            tooltip = group.localised_name,
        }
        fs_util.add_gui(elem, def_sprite)

        local def_table = {
            type = "frame",
            style = "factory_solver_recipe_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 6,
                children = def_buttons,
            },
        }
        fs_util.add_gui(elem, def_table)

        ::outer_continue::
    end
end

---@param event EventDataTrait
function handlers.on_make_recipe_quality_buttons(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_production_line_adder"))
    local tags = dialog.tags
    event.element.clear()
    if tags.is_multi_mode then
        local set = tags.recipe_quality_multi --[[@as table<string, true>]]
        common.make_quality_buttons_multi(event.element, set or {},
            handlers.on_recipe_quality_clicked_multi)
    else
        local initial_value = tags.recipe_quality --[[@as string]]
        common.make_quality_buttons(event.element, initial_value, handlers.on_recipe_quality_clicked)
    end
end

---@param event EventData.on_gui_click
function handlers.on_recipe_quality_clicked(event)
    local quality_name = common.on_quality_button_clicked(event.element)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_production_line_adder"))

    local dialog_tags = dialog.tags
    dialog_tags.recipe_quality = quality_name
    dialog.tags = dialog_tags
end

---@param event EventData.on_gui_click
function handlers.on_recipe_quality_clicked_multi(event)
    local quality_name, new_state = common.on_quality_button_clicked_multi(event.element)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_production_line_adder"))

    local dialog_tags = dialog.tags
    local set = dialog_tags.recipe_quality_multi or {}
    if new_state then
        set[quality_name] = true
    else
        set[quality_name] = nil
    end
    dialog_tags.recipe_quality_multi = set
    dialog.tags = dialog_tags
end

---Toggle between single-quality (radio) and multi-quality (independent
---toggle) modes for the picker. Rebuilds the quality button row in place
---so the new behaviour takes effect immediately, carrying state in both
---directions: single→multi seeds the multi set from the current radio
---selection; multi→single picks one quality (preferring the dialog's
---reference quality, falling back to the lowest-level selected quality,
---then "normal").
---@param event EventData.on_gui_checked_state_changed
function handlers.on_multi_mode_toggle(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags
    local is_multi = event.element.state

    if is_multi then
        -- Seed the multi-select set with the current single-mode quality and
        -- every higher tier, mirroring the per-line dialog's "source quality
        -- and above" default. The user can deselect afterwards.
        local current = dialog_tags.recipe_quality --[[@as string]]
        local current_proto = current and prototypes.quality[current]
        local threshold = current_proto and current_proto.level or 0
        local set = {}
        for _, q in pairs(prototypes.quality) do
            if not q.hidden and q.level >= threshold then
                set[q.name] = true
            end
        end
        if current then set[current] = true end
        dialog_tags.recipe_quality_multi = set
    else
        local set = dialog_tags.recipe_quality_multi or {} --[[@as table<string, true>]]
        local reference_typed_name = dialog_tags.typed_name --[[@as TypedName]]
        local picked
        if set[reference_typed_name.quality] then
            picked = reference_typed_name.quality
        elseif set[dialog_tags.recipe_quality] then
            picked = dialog_tags.recipe_quality --[[@as string]]
        else
            local lowest_level, lowest_name = math.huge, nil
            for name in pairs(set) do
                local proto = prototypes.quality[name]
                if proto and proto.level < lowest_level then
                    lowest_level = proto.level
                    lowest_name = name
                end
            end
            picked = lowest_name or "normal"
        end
        dialog_tags.recipe_quality = picked
    end
    dialog_tags.is_multi_mode = is_multi
    dialog.tags = dialog_tags

    local quality_flow
    for e in fs_util.dfs_lower(dialog) do
        if e.name == "recipe_quality_flow" then
            quality_flow = e
            break
        end
    end
    if quality_flow then
        local rebuild_event = fs_util.create_gui_event(quality_flow)
        handlers.on_make_recipe_quality_buttons(rebuild_event)
    end
end

---@param event EventData.on_gui_click
function handlers.on_production_line_picker_button_click(event)
    if common.try_open_factoriopedia(event) then return end
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local recipe_typed_name = tags.recipe_typed_name --[[@as TypedName]]
    local line_index = dialog_tags.line_index --[[@as integer?]]
    local kind = tags.kind --[[@as string]]
    local reference_typed_name = dialog_tags.typed_name --[[@as TypedName]]
    local fuel_typed_name = (kind == "fuel") and reference_typed_name or nil

    if dialog_tags.is_multi_mode then
        local set = dialog_tags.recipe_quality_multi or {} --[[@as table<string, true>]]
        local qualities = {}
        for name in pairs(set) do
            local proto = prototypes.quality[name]
            if proto then qualities[#qualities + 1] = proto end
        end
        if #qualities == 0 then
            local player = game.players[event.player_index]
            player.create_local_flying_text {
                text = { "factory-solver-no-qualities-selected" },
                create_at_cursor = true,
            }
            player.play_sound { path = "utility/cannot_build" }
            return
        end
        table.sort(qualities, function(a, b) return a.level > b.level end)
        for i, q in ipairs(qualities) do
            local tn_copy = flib_table.deep_copy(recipe_typed_name)
            tn_copy.quality = q.name
            local li = line_index and (line_index + i - 1) or nil
            save.new_production_line(event.player_index, solution, tn_copy, fuel_typed_name, li)
        end
    else
        recipe_typed_name.quality = dialog_tags.recipe_quality --[[@as string]]
        save.new_production_line(event.player_index, solution, recipe_typed_name, fuel_typed_name, line_index)
    end

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_production_line_adder",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_production_line_adder",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-add-production-line" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/close",
            hovered_sprite = "utility/close_black",
            clicked_sprite = "utility/close_black",
            tags = {
                close_target = "factory_solver_production_line_adder",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
    },
    {
        type = "frame",
        style = "inside_shallow_frame_with_padding",
        direction = "vertical",
        {
            type = "flow",
            {
                type = "frame",
                name = "recipe_for_product",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "product",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = { "factory-solver-recipe-for-product" },
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "product",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
            {
                type = "frame",
                name = "recipe_for_ingredient",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "ingredient",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = { "factory-solver-recipe-for-ingredient" },
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "ingredient",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
            {
                type = "frame",
                name = "recipe_for_fuel",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "fuel",
                },
                handler = {
                    on_added = handlers.on_init_choose_visiblity,
                },
                {
                    type = "scroll-pane",
                    style = "factory_solver_scroll_pane",
                    horizontal_scroll_policy = "never",
                    vertical_scroll_policy = "auto-and-reserve-space",
                    {
                        type = "label",
                        style = "caption_label",
                        caption = { "factory-solver-recipe-for-fuel" },
                    },
                    {
                        type = "table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "fuel",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
        },
        {
            type = "flow",
            name = "recipe_quality_flow",
            style = "factory_solver_centering_horizontal_flow",
            style_mods = { horizontal_spacing = 0 },
            direction = "horizontal",
            visible = script.feature_flags.quality,
            handler = {
                on_added = handlers.on_make_recipe_quality_buttons,
            },
        },
        {
            type = "flow",
            style = "factory_solver_centering_horizontal_flow",
            direction = "horizontal",
            visible = script.feature_flags.quality,
            {
                type = "checkbox",
                name = "multi_quality_checkbox",
                state = false,
                caption = { "factory-solver-select-multiple-qualities" },
                handler = {
                    [defines.events.on_gui_checked_state_changed] = handlers.on_multi_mode_toggle,
                },
            },
        },
        {
            type = "flow",
            style = "factory_solver_craft_visible_control_flow",
            {
                type = "table",
                name = "craft_visible_control",
                style = "factory_solver_craft_visible_control_table",
                column_count = 2,
                {
                    type = "label",
                    caption = { "factory-solver-unresearched" },
                },
                {
                    type = "switch",
                    name = "craft_visible_unresearched_switch",
                    switch_state = "right",
                    left_label_caption = { "factory-solver-show" },
                    right_label_caption = { "factory-solver-hide" },
                    tags = {
                        root_gui = "factory_solver_production_line_adder",
                        state_name = "unresearched_craft_visible",
                    },
                    handler = {
                        [defines.events.on_gui_switch_state_changed] = common
                            .on_craft_visible_switch_state_changed,
                        on_added = common.on_craft_visible_switch_added,
                    },
                },
                {
                    type = "label",
                    caption = { "factory-solver-hidden" },
                },
                {
                    type = "switch",
                    name = "craft_visible_hidden_switch",
                    switch_state = "right",
                    left_label_caption = { "factory-solver-show" },
                    right_label_caption = { "factory-solver-hide" },
                    tags = {
                        root_gui = "factory_solver_production_line_adder",
                        state_name = "hidden_craft_visible",
                    },
                    handler = {
                        [defines.events.on_gui_switch_state_changed] = common
                            .on_craft_visible_switch_state_changed,
                        on_added = common.on_craft_visible_switch_added,
                    },
                },
            },
        },
    },
}
