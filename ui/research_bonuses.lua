local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local save = require "manage/save"
local common = require "ui/common"

-- Dialog for editing the per-force ResearchBonuses snapshot. Working copy
-- lives in the root element's `tags` field (a deep-copied ResearchBonuses
-- table); every input widget reads from there on `on_added` and writes back
-- on edit. Sync / Reset mutate tags then re-dispatch `on_research_bonuses_redraw`
-- so the widgets repaint their displayed values. Apply commits tags through
-- save.apply_research_bonuses, which also marks every solution as needing a
-- fresh solve so the next `on_tick` picks them up.
--
-- The dialog never touches `force_data.research_bonuses` until Apply, and the
-- on_load handler in control.lua does not touch the GUI tree at all — both
-- are necessary to keep the lockstep model happy.

local DIALOG_NAME = "factory_solver_research_bonuses"

local handlers = {}

-- Handlers in this file are bound to both synthetic events (typed
-- EventDataTrait) and concrete Factorio gui events (EventData.on_gui_*),
-- which LuaLS keeps as nominally distinct classes. Accept anything that
-- carries an `element` field so every call site type-checks.
---@param event { element: LuaGuiElement }
---@return LuaGuiElement
local function find_dialog(event)
    return assert(fs_util.find_upper(event.element, DIALOG_NAME))
end

---@param value number?
---@return string
local function num_to_text(value)
    if not value or value == 0 then
        return "0"
    end
    -- %g hides float-noise tails like 0.10000000149012 (the natural shape of
    -- LuaForce.recipe_productivity_bonus after research_unit additions) while
    -- still round-tripping for the values a user would actually type. The
    -- precise number stays in dialog tags, so Apply commits the un-rounded
    -- snapshot.
    return string.format("%g", value)
end

---@param text string
---@return number
local function text_to_num(text)
    local n = tonumber(text)
    if not n or n ~= n then -- nan check
        return 0
    end
    return n
end

---@param event EventDataTrait
function handlers.on_dialog_added(event)
    local elem = event.element
    local force_index = game.players[event.player_index].force_index
    local force_data = storage.forces[force_index]

    -- Deep copy so dialog edits do not leak into the committed snapshot
    -- until Apply explicitly writes them back.
    local working_copy = flib_table.deep_copy(force_data.research_bonuses)
    elem.tags = { bonuses = working_copy }
end

---@param event EventDataTrait
function handlers.on_scalar_field_added(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local key = elem.tags.bonus_key --[[@as string]]
    local bonuses = dialog.tags.bonuses --[[@as ResearchBonuses]]
    elem.text = num_to_text(bonuses[key] --[[@as number]])
end

---@param event EventData.on_gui_text_changed
function handlers.on_scalar_field_text_changed(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local key = elem.tags.bonus_key --[[@as string]]

    local dialog_tags = dialog.tags
    local bonuses = dialog_tags.bonuses
    bonuses[key] = text_to_num(elem.text)
    dialog.tags = dialog_tags
end

---@param event EventDataTrait
function handlers.on_quality_checkbox_added(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local quality_name = elem.tags.quality_name --[[@as string]]
    local bonuses = dialog.tags.bonuses --[[@as ResearchBonuses]]
    elem.state = bonuses.unlocked_qualities[quality_name] == true
end

---@param event EventData.on_gui_checked_state_changed
function handlers.on_quality_checkbox_changed(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local quality_name = elem.tags.quality_name --[[@as string]]

    local dialog_tags = dialog.tags
    local bonuses = dialog_tags.bonuses
    if elem.state then
        bonuses.unlocked_qualities[quality_name] = true
    else
        bonuses.unlocked_qualities[quality_name] = nil
    end
    dialog.tags = dialog_tags
end

---@param event EventDataTrait
function handlers.on_recipe_field_added(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local recipe_name = elem.tags.recipe_name --[[@as string]]
    local bonuses = dialog.tags.bonuses --[[@as ResearchBonuses]]
    elem.text = num_to_text(bonuses.recipe_productivity[recipe_name])
end

---@param event EventData.on_gui_text_changed
function handlers.on_recipe_field_text_changed(event)
    local elem = event.element
    local dialog = find_dialog(event)
    local recipe_name = elem.tags.recipe_name --[[@as string]]

    local dialog_tags = dialog.tags
    local bonuses = dialog_tags.bonuses
    local value = text_to_num(elem.text)
    if value == 0 then
        bonuses.recipe_productivity[recipe_name] = nil
    else
        bonuses.recipe_productivity[recipe_name] = value
    end
    dialog.tags = dialog_tags
end

---@param event EventData.on_gui_click
function handlers.on_sync_click(event)
    local dialog = find_dialog(event)
    local force = game.players[event.player_index].force --[[@as LuaForce]]

    local dialog_tags = dialog.tags
    dialog_tags.bonuses = save.snapshot_force_research_bonuses(force)
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_research_bonuses_redraw")
end

---@param event EventData.on_gui_click
function handlers.on_reset_click(event)
    local dialog = find_dialog(event)

    local dialog_tags = dialog.tags
    dialog_tags.bonuses = save.default_research_bonuses()
    dialog.tags = dialog_tags

    fs_util.dispatch_to_subtree(dialog, "on_research_bonuses_redraw")
end

---@param event EventData.on_gui_click
function handlers.on_apply_click(event)
    local dialog = find_dialog(event)
    local force_index = game.players[event.player_index].force_index
    local force_data = storage.forces[force_index]

    local new_bonuses = dialog.tags.bonuses --[[@as ResearchBonuses]]
    save.apply_research_bonuses(force_data, new_bonuses)

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    -- unlocked_qualities feeds into the per-product quality decomposition that
    -- make_production_line_table renders, so toggling it has to invalidate the
    -- Products column's button set — not just the solver state — or the icons
    -- keep showing the pre-Apply quality cascade.
    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

---Build the per-recipe rows. Lives in `on_added` of the container so the
---recipe set is recomputed on each dialog open (cheap; the technology scan
---is O(#tech * #effects) and the list is small in vanilla + Space Age).
---@param event EventDataTrait
function handlers.on_recipe_table_added(event)
    local elem = event.element
    local recipe_names = save.list_productivity_research_recipes()

    for _, recipe_name in ipairs(recipe_names) do
        local recipe_proto = prototypes.recipe[recipe_name]
        if not recipe_proto then
            goto continue
        end

        fs_util.add_gui(elem, {
            type = "sprite-button",
            style = "transparent_slot",
            sprite = "recipe/" .. recipe_name,
            tooltip = recipe_proto.localised_name,
            elem_tooltip = { type = "recipe", name = recipe_name },
            ignored_by_interaction = true,
        })
        fs_util.add_gui(elem, {
            type = "label",
            caption = recipe_proto.localised_name,
        })
        fs_util.add_gui(elem, {
            type = "textfield",
            style = "short_number_textfield",
            numeric = true,
            allow_decimal = true,
            allow_negative = false,
            tags = { recipe_name = recipe_name },
            handler = {
                on_added = handlers.on_recipe_field_added,
                on_research_bonuses_redraw = handlers.on_recipe_field_added,
                [defines.events.on_gui_text_changed] = handlers.on_recipe_field_text_changed,
            },
        })

        ::continue::
    end

    if #elem.children == 0 then
        fs_util.add_gui(elem.parent, {
            type = "label",
            caption = { "factory-solver-no-recipe-productivity-research" },
        })
    end
end

---Build the per-quality checkboxes.
---@param event EventDataTrait
function handlers.on_quality_table_added(event)
    local elem = event.element
    local qualities = fs_util.sort_prototypes(fs_util.to_list(prototypes.quality))

    for _, quality in ipairs(qualities) do
        if quality.hidden then
            goto continue
        end

        local is_normal = quality.name == "normal"
        fs_util.add_gui(elem, {
            type = "checkbox",
            state = false,
            caption = { "", "[quality=", quality.name, "] ", quality.localised_name },
            enabled = not is_normal,
            tags = { quality_name = quality.name },
            handler = {
                on_added = handlers.on_quality_checkbox_added,
                on_research_bonuses_redraw = handlers.on_quality_checkbox_added,
                [defines.events.on_gui_checked_state_changed] = handlers.on_quality_checkbox_changed,
            },
        })

        ::continue::
    end
end

fs_util.add_handlers(handlers)

---@param caption LocalisedString
---@param bonus_key string
---@return fs.GuiElemDef
local function scalar_row(caption, bonus_key)
    return {
        type = "flow",
        direction = "horizontal",
        {
            type = "label",
            caption = caption,
            style_mods = { width = 220 },
        },
        {
            type = "textfield",
            style = "short_number_textfield",
            numeric = true,
            allow_decimal = true,
            allow_negative = false,
            tags = { bonus_key = bonus_key },
            handler = {
                on_added = handlers.on_scalar_field_added,
                on_research_bonuses_redraw = handlers.on_scalar_field_added,
                [defines.events.on_gui_text_changed] = handlers.on_scalar_field_text_changed,
            },
        },
    }
end

---@type fs.GuiElemDef
return {
    type = "frame",
    name = DIALOG_NAME,
    direction = "vertical",
    handler = {
        on_added = handlers.on_dialog_added,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = DIALOG_NAME,
        },
        handler = {
            on_added = common.on_init_drag_target,
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-research-bonuses" },
            ignored_by_interaction = true,
        },
        {
            type = "empty-widget",
            style = "flib_titlebar_drag_handle",
            ignored_by_interaction = true,
        },
    },
    {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
        {
            type = "scroll-pane",
            style = "factory_solver_preset_scroll_pane",
            direction = "vertical",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "auto",
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-global-bonuses" },
                },
                scalar_row({ "factory-solver-mining-drill-productivity" }, "mining_drill_productivity"),
                scalar_row({ "factory-solver-laboratory-productivity" }, "laboratory_productivity"),
                scalar_row({ "factory-solver-laboratory-speed" }, "laboratory_speed"),
                scalar_row({ "factory-solver-beacon-distribution-efficiency" }, "beacon_distribution"),
                scalar_row({ "factory-solver-research-unit-energy" }, "research_unit_energy"),
            },
            {
                type = "frame",
                style = "factory_solver_shallow_frame_in_shallow_frame",
                direction = "vertical",
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-unlocked-qualities" },
                },
                {
                    type = "flow",
                    direction = "vertical",
                    handler = {
                        on_added = handlers.on_quality_table_added,
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
                    caption = { "factory-solver-recipe-productivity" },
                },
                {
                    type = "table",
                    column_count = 3,
                    handler = {
                        on_added = handlers.on_recipe_table_added,
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
            caption = { "factory-solver-sync-with-current-research" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_sync_click,
            },
        },
        {
            type = "button",
            caption = { "factory-solver-reset-all-to-zero" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_reset_click,
            },
        },
        {
            type = "empty-widget",
            style = "flib_dialog_footer_drag_handle",
            ignored_by_interaction = true,
        },
        {
            type = "button",
            style = "back_button",
            caption = { "gui.cancel" },
            tags = {
                close_target = DIALOG_NAME,
            },
            handler = {
                [defines.events.on_gui_click] = common.on_close_target,
            },
        },
        {
            type = "button",
            style = "confirm_button",
            caption = { "gui.confirm" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_apply_click,
            },
        },
    },
}
