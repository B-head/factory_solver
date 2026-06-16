local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local save = require "manage/save"
local preset = require "manage/preset"
local tn = require "manage/typed_name"
local common = require "ui/common"

local handlers = {}

---@param event EventDataTrait
function handlers.on_memorize_machine_presets(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)

    elem.tags = {
        presets = flib_table.deep_copy(player_data.presets),
    }
end

---@param event EventDataTrait
function handlers.on_make_preset_tables(event)
    local elem = event.element
    local preset_type = elem.tags.preset_type
    local player_data = save.get_player_data(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    -- Read the dialog's presets ONCE here and set each button's toggled state at
    -- build time, rather than building untoggled buttons and re-syncing them with a
    -- post-build dispatch_to_subtree(on_preset_changed). LuaGuiElement.tags returns
    -- a fresh snapshot of the whole presets table on every read, so the old toggle
    -- handler -- fired per button by a dialog-wide dispatch run once per preset
    -- table (5x) -- copied presets thousands of times: ~1.3s of the dialog open at
    -- pyanodon scale. Build-time toggle reads it once per table instead. The click
    -- path keeps the on_preset_changed handler for the narrow per-row re-sync.
    local dialog = assert(fs_util.find_upper(elem, "factory_solver_machine_presets"))
    local presets = dialog.tags.presets --[[@as Presets]]

    -- This runs both on_added (initial build) and on_craft_visible_changed (filter
    -- toggle), so it must clear prior rows first; otherwise every toggle appends a
    -- fresh, unfiltered copy on top of the old one — the filter appears inert and
    -- the table grows without bound.
    elem.clear()

    local categories
    if preset_type == "fuel" then
        categories = storage.virtuals.fuel_categories_dictionary
    elseif preset_type == "fluid_fuel" then
        categories = { ["<any-fluid-fuel>"] = true }
    elseif preset_type == "resource" then
        categories = prototypes.resource_category
    elseif preset_type == "machine" then
        categories = prototypes.recipe_category
    elseif preset_type == "fixed_recipe" then
        categories = storage.virtuals.shared_fixed_recipes
    else
        assert()
    end

    local rows_emitted = 0
    for category_name, value in pairs(categories) do
        -- The engine auto-adds the core "parameters" crafting category to every
        -- crafting machine so parametrised blueprints can target any of them. It
        -- holds only the parameter-N placeholder recipes (filtered out elsewhere
        -- via .parameter), so its preset row would just duplicate every real
        -- machine under a meaningless heading. Skip it.
        if preset_type == "machine" and category_name == "parameters" then
            goto continue
        end

        -- Each row is one preset entry: a (key, caption, choices) triple, where
        -- key is what the pick is stored under in presets[preset_type]. Most preset
        -- types are one row per category; machine presets split a category into
        -- ingredient_count tiers, each its own row and key (preset.machine_preset_tiers).
        local rows
        if preset_type == "fuel" then
            rows = { {
                key = category_name,
                caption = category_name,
                crafts = acc.get_fuels_in_categories(value --[[@as { [string]: true }]])
            } }
        elseif preset_type == "fluid_fuel" then
            rows = { {
                key = category_name,
                caption = category_name,
                crafts = acc.get_any_fluid_fuels()
            } }
        elseif preset_type == "resource" then
            rows = { {
                key = category_name,
                caption = category_name,
                crafts = acc.get_machines_in_resource_category(category_name)
            } }
        elseif preset_type == "machine" then
            -- Tier machine lists already exclude fixed_recipe machines: those are
            -- offered per-recipe, never as a category default.
            rows = {}
            for _, tier in ipairs(preset.machine_preset_tiers(category_name)) do
                local caption = tier.threshold
                    and { "factory-solver-machine-preset-tier", category_name, tostring(tier.threshold) }
                    or category_name
                flib_table.insert(rows, { key = tier.key, caption = caption, crafts = tier.machines })
            end
        elseif preset_type == "fixed_recipe" then
            -- One row per recipe craftable only by >=2 fixed_recipe machines; key is
            -- the recipe name and the choices are exactly those fixed machines.
            local recipe = prototypes.recipe[category_name]
            rows = { {
                key = category_name,
                caption = recipe.localised_name,
                crafts = acc.get_machines_for_recipe(recipe)
            } }
        else
            assert()
        end

        for _, row in ipairs(rows) do
            if #row.crafts <= 1 then
                goto continue_row
            end

            -- The currently-selected preset for this row, used to set toggled at
            -- build time. fluid_fuel is a single global pick; the rest are dicts
            -- keyed by the row's preset key. Mirrors on_preset_change_toggle's
            -- lookup (explicit per type, not dynamic, to keep the Presets type
            -- checkable).
            local selected
            if preset_type == "fuel" then
                selected = presets.fuel[row.key]
            elseif preset_type == "fluid_fuel" then
                selected = presets.fluid_fuel
            elseif preset_type == "resource" then
                selected = presets.resource[row.key]
            elseif preset_type == "machine" then
                selected = presets.machine[row.key]
            elseif preset_type == "fixed_recipe" then
                selected = presets.fixed_recipe[row.key]
            end

            -- Build the buttons first so a row whose every choice is filtered out
            -- by the visibility switches contributes nothing: no label and no empty
            -- slot frame are emitted, and it does not count toward rows_emitted.
            local def_buttons = {}
            for _, craft in ipairs(row.crafts) do
                local typed_name = tn.craft_to_typed_name(craft)
                local is_hidden = acc.is_hidden(craft)
                local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

                if not common.craft_visible(is_hidden, is_unresearched, player_data) then
                    goto continue_button
                end

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    -- Dialog slots opt out of the per-hover full-grid refresh_highlight.
                    no_hover_highlight = true,
                    tags = {
                        typed_name = typed_name,
                        category_name = row.key,
                        preset_type = preset_type,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_preset_button_click,
                        on_preset_changed = handlers.on_preset_change_toggle,
                    },
                }
                -- toggled is a LuaGuiElement property (set post-creation), so it
                -- rides in elem_mods on the returned def rather than the add_param.
                def.elem_mods = {
                    toggled = selected ~= nil and tn.equals_typed_name(selected, typed_name, true) or false,
                }
                flib_table.insert(def_buttons, def)
                ::continue_button::
            end

            if #def_buttons == 0 then
                goto continue_row
            end
            rows_emitted = rows_emitted + 1

            do
                local def = {
                    type = "label",
                    caption = row.caption,
                    -- Wrap inside the 160px-wide first column instead of clipping;
                    -- single_line is a LuaStyle property so it must go in style_mods
                    -- (ignored at element top level). Long ingredient_count tier
                    -- captions span two lines; short category names stay one.
                    style_mods = { single_line = false, maximal_width = 160 },
                }
                fs_util.add_gui(elem, def)
            end

            do
                local def_table = {
                    type = "frame",
                    style = "factory_solver_slot_background_frame",
                    {
                        type = "table",
                        style = "filter_slot_table",
                        column_count = 6,
                        children = def_buttons,
                    },
                }
                fs_util.add_gui(elem, def_table)
            end
            ::continue_row::
        end
        ::continue::
    end

    -- The Fixed-recipe machines section is empty for vanilla and most mods (no
    -- recipe has >=2 fixed_recipe machines), so hide its whole frame rather than
    -- leave a bare heading. Its table is the only child of its section frame, so
    -- toggling the parent is safe; the fuel section shares one frame across two
    -- tables and is never empty, so it is not affected. Set both ways: a filter
    -- switch can empty the section and a later toggle can repopulate it, so the
    -- frame must be able to come back.
    if preset_type == "fixed_recipe" then
        elem.parent.visible = rows_emitted > 0
    end
end

---@param event EventData.on_gui_click
function handlers.on_preset_button_click(event)
    if common.try_open_factoriopedia(event) then return end
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    if preset_type == "fuel" then
        dialog_tags.presets.fuel[category_name] = typed_name
    elseif preset_type == "fluid_fuel" then
        dialog_tags.presets.fluid_fuel = typed_name
    elseif preset_type == "resource" then
        dialog_tags.presets.resource[category_name] = typed_name
    elseif preset_type == "machine" then
        dialog_tags.presets.machine[category_name] = typed_name
    elseif preset_type == "fixed_recipe" then
        dialog_tags.presets.fixed_recipe[category_name] = typed_name
    else
        assert()
    end

    dialog.tags = dialog_tags
    -- Only the clicked row's buttons change toggled state (its category's selection
    -- moved); re-sync just that slot table, not the whole dialog. elem.parent is the
    -- filter_slot_table holding this category's buttons. A dialog-wide dispatch here
    -- would re-toggle every preset button -- each snapshotting dialog.tags -- for no
    -- reason, the same cost the build path used to pay.
    fs_util.dispatch_to_subtree(elem.parent, "on_preset_changed")
end

---@param event EventDataTrait
function handlers.on_preset_change_toggle(event)
    local elem = event.element
    local typed_name = elem.tags.typed_name --[[@as TypedName]]
    local category_name = elem.tags.category_name
    local preset_type = elem.tags.preset_type
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    local dialog_tags = dialog.tags
    local selected
    if preset_type == "fuel" then
        selected = dialog_tags.presets.fuel[category_name]
    elseif preset_type == "fluid_fuel" then
        selected = dialog_tags.presets.fluid_fuel
    elseif preset_type == "resource" then
        selected = dialog_tags.presets.resource[category_name]
    elseif preset_type == "machine" then
        selected = dialog_tags.presets.machine[category_name]
    elseif preset_type == "fixed_recipe" then
        selected = dialog_tags.presets.fixed_recipe[category_name]
    end
    assert(selected)

    elem.toggled = tn.equals_typed_name(selected, typed_name, true)
end

---@param event EventData.on_gui_click
function handlers.on_machine_presets_confirm(event)
    local player_data = save.get_player_data(event.player_index)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_machine_presets"))

    player_data.presets = dialog.tags.presets --[[@as Presets]]

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_machine_presets",
    direction = "vertical",
    handler = {
        on_added = handlers.on_memorize_machine_presets,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_machine_presets",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-machine-presets" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
    },
    {
        type = "label",
        style = "factory_solver_dialog_description_label",
        caption = { "factory-solver-desc-machine-presets" },
    },
    {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
        style_mods = {
            bottom_padding = 12,
        },
        {
            type = "scroll-pane",
            style = "factory_solver_preset_scroll_pane",
            direction = "vertical",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "always",
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-fuels" },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fluid_fuel",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-minings" },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "resource",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-machines" },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "machine",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-fixed-recipe-machines" },
                },
                {
                    type = "table",
                    style = "factory_solver_preset_layout_table",
                    column_count = 2,
                    tags = {
                        preset_type = "fixed_recipe",
                    },
                    handler = {
                        on_added = handlers.on_make_preset_tables,
                        on_craft_visible_changed = handlers.on_make_preset_tables,
                    },
                },
            },
        },
        -- One craft-visibility control governs all five preset tables; toggling
        -- dispatches on_craft_visible_changed to the root, which every table listens
        -- for and rebuilds from.
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
                        root_gui = "factory_solver_machine_presets",
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
                        root_gui = "factory_solver_machine_presets",
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
    {
        type = "flow",
        name = "dialog_buttons",
        {
            type = "button",
            style = "back_button",
            caption = { "gui.cancel" },
            tags = {
                close_target = "factory_solver_machine_presets",
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target
            },
        },
        {
            type = "empty-widget",
            style = "flib_dialog_footer_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "button",
            style = "confirm_button",
            caption = { "gui.confirm" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_machine_presets_confirm,
            }
        },
    },
}
