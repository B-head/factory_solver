local flib_table = require "__flib__/table"
local flib_dictionary = require "__flib__/dictionary"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local recipe_filter = require "manage/recipe_filter"
local save = require "manage/save"
local tn = require "manage/typed_name"
local relation = require "manage/relation"
local common = require "ui/common"
local picker_build = require "ui/picker_build"

local handlers = {}

---Reorder the four recipe-picker frames to input-group-first, the default
---(is_recipe_io_placement_swapped is true unless the player opts into "Classic
---Product / Ingredient placement"). The static template builds them in
---[product, spent, ingredient, fuel] order; swapping the output group
---(product, spent) with the input group (ingredient, fuel) yields
---[ingredient, fuel, product, spent], mirroring the column order in the solution
---editor. The frames are always built; we permute the already-built children.
---@param event EventDataTrait
function handlers.on_arrange_recipe_io_placement(event)
    if not common.is_recipe_io_placement_swapped(event.player_index) then
        return
    end
    local flow = event.element
    -- [product, spent, ingredient, fuel] -> [ingredient, fuel, product, spent]
    flow.swap_children(1, 3) -- -> [ingredient, spent, product, fuel]
    flow.swap_children(2, 4) -- -> [ingredient, fuel, product, spent]
end

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
    elseif kind == "spent" then
        -- Burnt fuel residue (spent cell / ash) is a way the material is produced,
        -- so it shares the product-choosing mode.
        allowed, recipe_names = dialog_tags.is_choose_product, relation_to_recipe.recipe_for_burnt_result
    elseif kind == "ingredient" then
        allowed, recipe_names = dialog_tags.is_choose_ingredient, relation_to_recipe.recipe_for_ingredient
    elseif kind == "fuel" then
        allowed = dialog_tags.is_choose_ingredient
        recipe_names = relation.expand_fuel_consumers(relation_to_recipes, relation_to_recipe)
    else
        assert()
    end
    elem.visible = allowed
        and recipe_filter.has_pickable_recipe(reference_typed_name, recipe_names, kind)
end

---@param event EventDataTrait
-- The actual build is heavy (a pyanodon spent picker is thousands of buttons) and
-- runs on every client in lockstep, so it must not happen synchronously here.
-- Clear the table and arm a tick-split build (ui/picker_build.lua); control.lua's
-- on_tick fills it in at a bounded budget per tick. Re-firing (filter / craft-
-- visible change) overwrites the request = cancel + restart. The matching build
-- spec is registered below (production_line_picker_spec).
---@param event EventDataTrait
function handlers.on_make_choose_table(event)
    local elem = event.element
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags

    local kind = elem.tags.kind --[[@as string]]
    local reference = dialog_tags.typed_name --[[@as TypedName]]
    local raw_filter = dialog_tags.filter_text --[[@as string?]] or ""
    local needle = (raw_filter ~= "") and helpers.multilingual_to_lower(raw_filter) or ""
    -- table -> scroll-pane -> recipe_for_* frame (the section, used as the build key).
    local section = elem.parent.parent

    elem.clear()
    picker_build.request(event.player_index, section.name, {
        spec_id = "production_line_adder",
        kind = kind,
        reference = reference,
        needle = needle,
        dialog_name = "factory_solver_production_line_adder",
        section_name = section.name,
    })
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

---@param event EventData.on_gui_text_changed
function handlers.on_name_filter_textfield_changed(event)
    local dialog = assert(common.find_root_element(event.player_index, "factory_solver_production_line_adder"))
    local dialog_tags = dialog.tags
    dialog_tags.filter_text = event.element.text
    dialog.tags = dialog_tags -- tags are a snapshot; reassign the whole table to persist.

    fs_util.dispatch_to_subtree(dialog, "on_filter_text_changed")
end

-- Tick-split build spec for the recipe picker (driven by ui/picker_build.lua from
-- control.lua's on_tick). `plan` is the old on_make_choose_table prep, emitting the
-- ordered recipe-name list instead of building buttons; `make_button` /
-- `open_group` materialise one chunk per tick.
picker_build.register_spec {
    id = "production_line_adder",

    -- Re-find the target choose-table by name. Navigate via recipe_choose_flow
    -- (found before its section subtrees, so cheap) then the named section frame
    -- (direct child) then the named table -- never a DFS through the built buttons.
    find_table = function(player_index, req)
        local dialog = common.find_root_element(player_index, req.dialog_name)
        if not dialog then return nil end
        local flow = fs_util.find_lower(dialog, "recipe_choose_flow")
        if not flow then return nil end
        local section = flow[req.section_name]
        if not section or not section.valid then return nil end
        return fs_util.find_lower(section, "fs_choose_table")
    end,

    -- Append a group's icon + an (empty) slot table; return the slot table. The
    -- choose-table is a 2-column table: [group sprite, slot-table frame] per group.
    open_group = function(player_index, req, choose_table, group_name)
        local group = prototypes.item_group[group_name]
        fs_util.add_gui(choose_table, {
            type = "sprite",
            style = "factory_solver_group_sprite",
            sprite = "item-group/" .. group_name,
            resize_to_sprite = false,
            tooltip = group and group.localised_name or nil,
        })
        fs_util.add_gui(choose_table, {
            type = "frame",
            style = "factory_solver_recipe_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 6,
            },
        })
        local kids = choose_table.children
        return kids[#kids].children[1]
    end,

    -- The current (last-opened) group's slot table = last child's only child. O(1)
    -- via the children array (no name lookup, no DFS over prior buttons).
    current_slot = function(player_index, req, choose_table)
        local kids = choose_table.children
        return kids[#kids].children[1]
    end,

    -- The former on_make_choose_table prep, emitting names + group instead of GUI.
    plan = function(player_index, req)
        local relation_to_recipes = save.get_relation_to_recipes(player_index)
        local kind = req.kind
        local reference = req.reference --[[@as TypedName]]

        local relation_to_recipe
        if reference.type == "item" then
            relation_to_recipe = relation_to_recipes.item[reference.name]
        elseif reference.type == "fluid" then
            relation_to_recipe = relation_to_recipes.fluid[reference.name]
        elseif reference.type == "virtual_material" then
            relation_to_recipe = relation_to_recipes.virtual_recipe[reference.name]
        else
            assert()
        end

        local recipe_names
        if kind == "product" then
            recipe_names = relation_to_recipe.recipe_for_product
        elseif kind == "spent" then
            recipe_names = relation_to_recipe.recipe_for_burnt_result
        elseif kind == "ingredient" then
            recipe_names = relation_to_recipe.recipe_for_ingredient
        elseif kind == "fuel" then
            recipe_names = relation.expand_fuel_consumers(relation_to_recipes, relation_to_recipe)
        else
            assert()
        end
        recipe_names = recipe_filter.pickable_recipe_names(reference, recipe_names, kind)

        local used_recipes = flib_table.map(recipe_names, function(name)
            return assert(storage.virtuals.recipe[name] or prototypes.recipe[name])
        end) --[=[@as (LuaRecipePrototype | VirtualRecipe)[]]=]

        local grouped = fs_util.group_by(used_recipes, function(value)
            if value.group then return value.group.name else return value.group_name end
        end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]

        local groups = fs_util.sort_prototypes(fs_util.to_list(prototypes.item_group))

        local entries, group_of, sort_of = {}, {}, {}
        for _, group in ipairs(groups) do
            local group_recipes = grouped[group.name] or {}
            local subgrouped = fs_util.group_by(group_recipes, function(value)
                if value.subgroup then return value.subgroup.name else return value.subgroup_name end
            end) --[=[@as table<string, (LuaRecipePrototype | VirtualRecipe)[]>]=]
            local subgroups = fs_util.sort_prototypes(fs_util.to_list(group.subgroups))
            for _, subgroup in ipairs(subgroups) do
                local subgroup_recipes = subgrouped[subgroup.name] or {}
                -- Emit every pickable recipe of this subgroup UNSORTED; sort_run sorts
                -- the run in the build phase. The hidden / unresearched / name-filter
                -- checks run per-entry in make_button so they spread across ticks too
                -- (an all-filtered group then never opens an empty slot table).
                for _, recipe in ipairs(subgroup_recipes) do
                    entries[#entries + 1] = recipe.name
                    group_of[#group_of + 1] = group.name
                    sort_of[#sort_of + 1] = subgroup.name
                end
            end
        end
        ---@type PickerBuildPlan
        return { entries = entries, group_of = group_of, sort_of = sort_of }
    end,

    -- Sort one subgroup's slice into display order (the former per-subgroup
    -- sort_prototypes), precomputing (order, name) keys so the comparator does not
    -- re-read the prototype API per comparison. group_of is constant within a
    -- subgroup run, so only entries needs reordering.
    sort_run = function(player_index, req, plan, lo, hi)
        local keyed = {}
        for i = lo, hi do
            local name = plan.entries[i]
            local recipe = storage.virtuals.recipe[name] or prototypes.recipe[name]
            keyed[#keyed + 1] = { order = recipe.order, name = name }
        end
        flib_table.sort(keyed, function(a, b)
            if a.order ~= b.order then return a.order < b.order else return a.name < b.name end
        end)
        for k = 1, #keyed do
            plan.entries[lo + k - 1] = keyed[k].name
        end
    end,

    -- Build one decorated button, or return nil to skip this entry. The hidden /
    -- unresearched / name-filter checks (the former on_make_choose_table per-recipe
    -- filter) run here so they are spread across ticks; is_hidden / is_unresearched
    -- are computed once and used for both the skip decision and the styling. The
    -- relation cache is stable mid-build (a rebuild closes all GUIs).
    make_button = function(player_index, req, plan, i)
        local name = plan.entries[i]
        local recipe = assert(storage.virtuals.recipe[name] or prototypes.recipe[name])
        local relation_to_recipes = save.get_relation_to_recipes(player_index)
        local player_data = save.get_player_data(player_index)
        local is_hidden = acc.is_hidden(recipe)
        local is_unresearched = acc.is_unresearched(recipe, relation_to_recipes)
        if not common.craft_visible(is_hidden, is_unresearched, player_data) then
            return nil
        end
        local needle = req.needle or ""
        if needle ~= "" then
            -- real = LuaRecipePrototype (object_name set), virtual = plain table;
            -- they live in different dictionaries.
            local dict = flib_dictionary.get(player_index, recipe.object_name ~= nil and "recipe" or "virtual")
            if not common.name_filter_matches(needle, recipe.name, dict and dict[recipe.name] or nil) then
                return nil
            end
        end
        local typed_name = tn.craft_to_typed_name(recipe)
        return common.create_decorated_sprite_button {
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            -- Pickers opt out of the hover-highlight: refresh_highlight repaints the
            -- whole (up to thousands-slot) picker per hover, and entries are unique.
            no_hover_highlight = true,
            tags = {
                recipe_typed_name = typed_name,
                kind = req.kind,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_production_line_picker_button_click,
            },
        }
    end,
}

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
            type = "textfield",
            name = "name_filter_textfield",
            style = "flib_titlebar_search_textfield",
            visible = false,
            clear_and_focus_on_right_click = true,
            tooltip = { "factory-solver-name-filter-tooltip" },
            handler = {
                [defines.events.on_gui_text_changed] = handlers.on_name_filter_textfield_changed,
            },
        },
        {
            type = "sprite-button",
            style = "frame_action_button",
            sprite = "utility/search",
            hovered_sprite = "utility/search",
            clicked_sprite = "utility/search",
            handler = {
                [defines.events.on_gui_click] = common.on_toggle_name_filter,
            },
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
        type = "label",
        style = "factory_solver_dialog_description_label",
        caption = { "factory-solver-desc-production-line-adder" },
    },
    {
        type = "frame",
        style = "inside_shallow_frame_with_padding",
        direction = "vertical",
        {
            type = "flow",
            name = "recipe_choose_flow",
            handler = {
                on_added = handlers.on_arrange_recipe_io_placement,
            },
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
                        name = "fs_choose_table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "product",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                            on_filter_text_changed = handlers.on_make_choose_table,
                        },
                    },
                },
            },
            {
                type = "frame",
                name = "recipe_for_spent",
                style = "flib_shallow_frame_in_shallow_frame",
                direction = "vertical",
                visible = false,
                tags = {
                    kind = "spent",
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
                        caption = { "factory-solver-recipe-for-spent" },
                    },
                    {
                        type = "table",
                        name = "fs_choose_table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "spent",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                            on_filter_text_changed = handlers.on_make_choose_table,
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
                        name = "fs_choose_table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "ingredient",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                            on_filter_text_changed = handlers.on_make_choose_table,
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
                        name = "fs_choose_table",
                        style = "factory_solver_choose_table",
                        column_count = 2,
                        draw_horizontal_lines = true,
                        tags = {
                            kind = "fuel",
                        },
                        handler = {
                            on_added = handlers.on_make_choose_table,
                            on_craft_visible_changed = handlers.on_make_choose_table,
                            on_filter_text_changed = handlers.on_make_choose_table,
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
