local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"
local constraint_adder = require "ui/constraint_adder"
local production_line_adder = require "ui/production_line_adder"

local limit_type_to_index = {
    ["upper"] = 1,
    ["lower"] = 2,
    ["equal"] = 3,
}

-- Amount quick-set popup (slider + belt/pump buttons). The slider sets a
-- multiplier (0..10x in 1x steps) applied to a base per-second value held on the
-- slider's tags: the constraint's current amount, or a belt/pump throughput set
-- via the buttons. So "900*2" is base 900 at 2x. The range is a placeholder.
local SLIDER_STEP = 0.5
local SLIDER_MIN = SLIDER_STEP
local SLIDER_MAX = 10

---Evaluate the text in a constraint amount field. Delegates to the same
---engine helper Factorio's own numeric textboxes use, so the supported
---syntax (operators, precedence, variable substitution shape, parse-error
---behaviour) matches what users already learned in vanilla textboxes — we
---do not maintain a parallel grammar.
---The field accepts any character, so partial / mid-typing states like
---"60*" raise inside the helper; we pcall and return false in `ok` so the
---handler keeps the previously-saved value rather than clobbering it with
---0 on every keystroke. An explicitly empty field returns 0 + true so
---clearing the textbox still maps to "no constraint".
---@param text string?
---@return number value
---@return boolean ok
local function eval_amount_expression(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return 0, true end
    local n = tonumber(text)
    if n then return n, true end
    local ok, result = pcall(helpers.evaluate_expression, text)
    if not ok or type(result) ~= "number" then return 0, false end
    -- NaN / ±inf collapse the LP, so treat them as "invalid input, keep the
    -- last good value" rather than committing them and watching the solver
    -- blow up on the next tick.
    if result ~= result or result == math.huge or result == -math.huge then
        return 0, false
    end
    return result, true
end

-- Split a "base*<number>" amount-field text into its base expression and the
-- trailing multiplier. No trailing "*<number>" -> the whole text is the base at
-- 1x. The base may itself be an expression; only the final "*<number>" is peeled,
-- so "60*45*2" -> ("60*45", 2). The caller evaluates the base expression.
---@param text string
---@return string base_expr
---@return number multiplier
local function split_base_multiplier(text)
    local base_expr, mult = text:match("^(.-)%s*%*%s*([%d.]+)%s*$")
    if base_expr and base_expr ~= "" and mult then
        return base_expr, tonumber(mult) --[[@as number]]
    end
    return text, 1
end

-- Set the popup slider's multiplier + base from an amount-field text ("base*mult"),
-- so the slider follows the field. is_recipe skips the time-scale conversion.
---@param slider LuaGuiElement
---@param field_text string
---@param is_recipe boolean
---@param player_data PlayerLocalData
local function sync_slider_from_field(slider, field_text, is_recipe, player_data)
    local base_expr, mult = split_base_multiplier(field_text)
    local base_amount = eval_amount_expression(base_expr)
    if not is_recipe then
        base_amount = fs_util.from_scale(base_amount, player_data.time_scale)
    end
    slider.slider_value = math.min(math.max(mult, SLIDER_MIN), SLIDER_MAX)
    local slider_tags = slider.tags
    slider_tags.base = base_amount
    slider.tags = slider_tags
end

local handlers = {}

---@class ThroughputEntry
---@field name string
---@field order string
---@field localised_name LocalisedString
---@field rate number  Items (belt) or fluid units (pump) per second.

---Full belt throughput = belt_speed (tiles/tick) × 480 (60 ticks × 8 items per
---tile across both lanes). Verified against vanilla yellow belt = 15/s.
---get_entity_filtered's result is engine-cached per filter, so this leans on
---that rather than a module-local cache; the list is tiny and built cheaply.
---@return ThroughputEntry[]
local function get_belt_throughputs()
    local list = {}
    local belts = prototypes.get_entity_filtered { { filter = "type", type = "transport-belt" } }
    for name, proto in pairs(belts) do
        if helpers.is_valid_sprite_path("entity/" .. name) then
            flib_table.insert(list, {
                name = name,
                order = proto.order,
                localised_name = proto.localised_name,
                rate = proto.belt_speed * 480,
            })
        end
    end
    return fs_util.sort_prototypes(list)
end

---Pump throughput = pumping_speed (fluid units/tick) × 60. The static
---`pumping_speed` property is read (not the get_pumping_speed(quality?) method)
---to keep the normal-quality reference rate and dodge the self-bound-call trap;
---verified against vanilla pump = 20/tick → 1200/s.
---@return ThroughputEntry[]
local function get_pump_throughputs()
    local list = {}
    local pumps = prototypes.get_entity_filtered { { filter = "type", type = "pump" } }
    for name, proto in pairs(pumps) do
        if helpers.is_valid_sprite_path("entity/" .. name) then
            flib_table.insert(list, {
                name = name,
                order = proto.order,
                localised_name = proto.localised_name,
                rate = proto.pumping_speed * 60,
            })
        end
    end
    return fs_util.sort_prototypes(list)
end

---Locate the constraint a popup/field belongs to and write its per-second
---amount. The identity (type/name/quality/temperatures) rides the element tags;
---`limit_amount_per_second` is always stored unscaled, so callers pass the raw
---per-second value regardless of the player's display time scale.
---@param player_index integer
---@param tags Tags
---@param amount_per_second number
local function commit_amount(player_index, tags, amount_per_second)
    local typed_name = tn.create_typed_name(
        tags.type --[[@as FilterType]],
        tags.name --[[@as string]],
        tags.quality --[[@as string?]],
        tags.minimum_temperature --[[@as number?]],
        tags.maximum_temperature --[[@as number?]])
    local solution = assert(save.get_selected_solution(player_index))
    local pos = assert(fs_util.find(solution.constraints, function(value)
        return tn.equals_typed_name(value, typed_name)
    end))
    save.update_constraint(solution, pos, { limit_amount_per_second = amount_per_second })
end

---Display value for the amount textfield: recipe / virtual_recipe amounts are
---machine-count rates shown raw; item / fluid amounts are scaled to the
---player's display time scale (matching how the row is built).
---@param filter_type FilterType
---@param amount_per_second number
---@param player_data PlayerLocalData
---@return number
local function amount_to_display(filter_type, amount_per_second, player_data)
    if filter_type == "recipe" or filter_type == "virtual_recipe" then
        return amount_per_second
    end
    return fs_util.to_scale(amount_per_second, player_data.time_scale)
end

---Stash `base` (per-second) on the popup slider and commit it, keeping the
---slider's current multiplier; the row textfield then shows "base*mult". Shared
---by the default and throughput buttons.
---@param player_index integer
---@param button LuaGuiElement
---@param base number
---@param player_data PlayerLocalData
local function apply_base(player_index, button, base, player_data)
    local tags = button.tags
    commit_amount(player_index, tags, base)
    local popup = button.parent.parent
    local field = popup.parent["controls"]["amount_field"]
    -- Keep the current multiplier from the field, NOT the slider: the slider can
    -- be clamped to its max, which would drop a multiplier like "*45" down to 10.
    local _, multiplier = split_base_multiplier(field and field.text or "")
    if field then
        field.text = tostring(amount_to_display(tags.type --[[@as FilterType]], base, player_data)) .. "*" .. multiplier
    end
    local slider = popup["amount_slider"]
    if slider then
        local slider_tags = slider.tags
        slider_tags.base = base
        slider.tags = slider_tags
        slider.slider_value = math.min(math.max(multiplier, SLIDER_MIN), SLIDER_MAX)
    end
end

---Quick-set button row: a "default" button (always) plus belt (item) / pump
---(fluid) throughput buttons appended for item / fluid constraints.
---@param filter_type FilterType
---@param identity Tags  Constraint identity, shared into each button's tags.
---@return fs.GuiElemDef
local function build_throughput_buttons(filter_type, identity)
    -- The default button always shows (it sets a type-appropriate base value);
    -- belt / pump throughput buttons are appended only for item / fluid.
    local flow = {
        type = "flow",
        direction = "horizontal",
        style_mods = { horizontal_spacing = 4 },
        {
            type = "sprite-button",
            style = "flib_slot_button_default",
            sprite = "utility/reset_white",
            tooltip = { "factory-solver-quickset-default" },
            tags = identity,
            handler = {
                [defines.events.on_gui_click] = handlers.on_default_click,
            },
        },
    }

    local entries
    if filter_type == "item" then
        entries = get_belt_throughputs()
    elseif filter_type == "fluid" then
        entries = get_pump_throughputs()
    end
    for _, entry in ipairs(entries or {}) do
        flib_table.insert(flow, {
            type = "sprite-button",
            style = "flib_slot_button_default",
            sprite = "entity/" .. entry.name,
            tooltip = { "", entry.localised_name, ": ", string.format("%g/s", entry.rate) },
            tags = flib_table.shallow_merge { identity, { rate_per_second = entry.rate } },
            handler = {
                [defines.events.on_gui_click] = handlers.on_throughput_click,
            },
        })
    end
    return flow
end

---Amount quick-set popup for one constraint row: a per-second slider plus the
---belt / pump throughput buttons. Built for every row (cheap) and shown/hidden
---through `visible`, so toggling it never destroys the focused textfield.
---@param index integer
---@param data Constraint
---@param is_expanded boolean
---@return fs.GuiElemDef
local function build_amount_popup(index, data, is_expanded)
    local identity = flib_table.shallow_merge { data, { constraint_index = index } }

    local popup = {
        type = "flow",
        name = "popup",
        direction = "vertical",
        visible = is_expanded,
        tags = { constraint_index = index },
        style_mods = { top_margin = 2, vertical_spacing = 4 },
        {
            type = "flow",
            direction = "horizontal",
            style_mods = { vertical_align = "center" },
            {
                type = "empty-widget",
                style_mods = { horizontally_stretchable = true },
            },
            {
                type = "sprite-button",
                style = "mini_tool_button_red",
                sprite = "utility/close",
                hovered_sprite = "utility/close_black",
                clicked_sprite = "utility/close_black",
                tags = { constraint_index = index },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_close_popup_click,
                },
            },
        },
        {
            type = "slider",
            name = "amount_slider",
            minimum_value = SLIDER_MIN,
            maximum_value = SLIDER_MAX,
            value = 1,
            value_step = SLIDER_STEP,
            discrete_slider = true,
            style_mods = { horizontally_stretchable = true },
            tags = flib_table.shallow_merge { identity, { base = data.limit_amount_per_second } },
            handler = {
                [defines.events.on_gui_value_changed] = handlers.on_amount_slider_changed,
            },
        },
    }

    local throughput = build_throughput_buttons(data.type, identity)
    if throughput then
        flib_table.insert(popup, throughput)
    end

    return popup
end

---One constraint row: the controls line (move / icon / amount / limit type /
---remove) wrapped in a vertical flow above the amount quick-set popup. Replaces
---the old fixed 5-column table cell; every control keeps a fixed width, so the
---rows still line up as columns without the table.
---@param player_data PlayerLocalData
---@param index integer
---@param data Constraint
---@param is_expanded boolean
---@return fs.GuiElemDef
local function build_constraint_row(player_data, index, data, is_expanded)
    local typed_name = tn.create_typed_name(
        data.type, data.name, data.quality,
        data.minimum_temperature, data.maximum_temperature)

    local icon_def = common.create_decorated_sprite_button {
        typed_name = typed_name,
        tags = data,
        handler = {
            [defines.events.on_gui_click] = handlers.on_constraint_button_click,
        },
    }
    common.append_tooltip_line(icon_def, common.op_hints.constraint_icon())

    local display_amount = amount_to_display(data.type, data.limit_amount_per_second, player_data)

    local controls = {
        type = "flow",
        name = "controls",
        direction = "horizontal",
        style_mods = { vertical_align = "center", horizontal_spacing = 8 },
        {
            type = "flow",
            direction = "vertical",
            {
                type = "sprite-button",
                style = "mini_button",
                sprite = "utility/speed_up",
                tooltip = common.op_hints.move_row(),
                tags = { constraint_index = index, direction = "up" },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_move_constraint_click,
                },
            },
            {
                type = "sprite-button",
                style = "mini_button",
                sprite = "utility/speed_down",
                tooltip = common.op_hints.move_row(),
                tags = { constraint_index = index, direction = "down" },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_move_constraint_click,
                },
            },
        },
        icon_def,
        {
            type = "textfield",
            name = "amount_field",
            style = "factory_solver_limit_amount_textfield",
            clear_and_focus_on_right_click = true,
            text = tostring(display_amount),
            tooltip = { "factory-solver-limit-amount-tooltip" },
            tags = flib_table.shallow_merge { data, { constraint_index = index } },
            handler = {
                [defines.events.on_gui_text_changed] = handlers.on_limit_amount_confirmed,
                [defines.events.on_gui_click] = handlers.on_amount_field_click,
            },
        },
        {
            type = "drop-down",
            style = "factory_solver_limit_type_dropdown",
            selected_index = limit_type_to_index[data.limit_type],
            items = {
                { "factory-solver-upper-limit" },
                { "factory-solver-lower-limit" },
                { "factory-solver-equal" },
            },
            tags = data,
            handler = {
                [defines.events.on_gui_selection_state_changed] = handlers.on_limit_type_changed,
            },
        },
        {
            type = "sprite-button",
            style = "mini_tool_button_red",
            sprite = "utility/close",
            hovered_sprite = "utility/close_black",
            clicked_sprite = "utility/close_black",
            tooltip = { "factory-solver-remove-constraint" },
            tags = { constraint_index = index },
            handler = {
                [defines.events.on_gui_click] = handlers.on_remove_constraint_click,
            },
        },
    }

    return {
        type = "flow",
        direction = "vertical",
        style_mods = { vertical_spacing = 4 },
        controls,
        build_amount_popup(index, data, is_expanded),
    }
end

---@param event EventData.on_gui_click
function handlers.on_add_constraint_click(event)
    common.open_gui(event.player_index, true, constraint_adder)
end

---@param event EventDataTrait
function handlers.on_make_constraints_table(event)
    local list = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    -- Switching solutions drops the popup rather than carrying an open state
    -- onto an unrelated constraint set.
    if event.name == "on_selected_solution_changed" then
        player_data.expanded_constraint_index = nil
    end

    list.clear()
    if not solution then
        return
    end

    local expanded = player_data.expanded_constraint_index
    if expanded and expanded > #solution.constraints then
        expanded = nil
        player_data.expanded_constraint_index = nil
    end

    for index, data in ipairs(solution.constraints) do
        if index > 1 then
            fs_util.add_gui(list, { type = "line", direction = "horizontal" })
        end
        fs_util.add_gui(list, build_constraint_row(player_data, index, data, expanded == index))
    end
end

---@param event EventData.on_gui_click
function handlers.on_constraint_button_click(event)
    if common.try_open_factoriopedia(event) then return end
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local typed_name = tn.create_typed_name(
        tags.type --[[@as FilterType]],
        tags.name --[[@as string]],
        tags.quality --[[@as string?]],
        tags.minimum_temperature --[[@as number?]],
        tags.maximum_temperature --[[@as number?]])

    if typed_name.type == "recipe" or typed_name.type == "virtual_recipe" then
        save.new_production_line(event.player_index, solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_production_line_changed")
    else
        local data = {
            typed_name = typed_name,
            is_choose_product = true,
            is_choose_ingredient = true,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    end
end

---@param event EventDataTrait
function handlers.on_add_constraint_button_enabled(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)

    elem.enabled = solution ~= nil
end

---Open the amount quick-set popup for the clicked row's field. Open-only (no
---toggle): clicking the field to position the caret / edit text must not close
---the popup. Left-click only (right-click is the textfield's own
---clear-and-focus). The popup closes on an outside GuiElement click (global
---on_gui_click hook in control.lua) or its close button. Visibility is flipped
---in place — no rebuild — so the engine's focus on the clicked field survives.
---@param event EventData.on_gui_click
function handlers.on_amount_field_click(event)
    if event.button ~= defines.mouse_button_type.left then return end
    local field = event.element
    local player_data = save.get_player_data(event.player_index)
    local index = field.tags.constraint_index --[[@as integer]]

    if player_data.expanded_constraint_index == index then return end
    player_data.expanded_constraint_index = index

    local list = fs_util.find_upper(field, "constraint_list")
    if not list then return end
    local solution = save.get_selected_solution(event.player_index)
    for _, row in pairs(list.children) do
        local popup = row["popup"]
        if popup then
            local row_index = popup.tags.constraint_index
            local show = row_index == index
            popup.visible = show
            -- Restore the slider's multiplier from the row's textfield ("base*mult")
            -- on open, and stash the base on the slider so dragging scales from it.
            local slider = show and popup["amount_slider"] or nil
            local constraint = solution and solution.constraints[row_index --[[@as integer]]]
            if slider and constraint then
                local row_field = row["controls"]["amount_field"]
                local is_recipe = constraint.type == "recipe" or constraint.type == "virtual_recipe"
                sync_slider_from_field(slider, row_field and row_field.text or "", is_recipe, player_data)
            end
        end
    end
end

---Close the amount quick-set popup (close button): hide every row's popup and
---clear the expanded marker. An outside GuiElement click (control.lua global
---hook) does the same via a table rebuild.
---@param event EventData.on_gui_click
function handlers.on_close_popup_click(event)
    local player_data = save.get_player_data(event.player_index)
    player_data.expanded_constraint_index = nil
    local list = fs_util.find_upper(event.element, "constraint_list")
    if not list then return end
    for _, row in pairs(list.children) do
        local popup = row["popup"]
        if popup then
            popup.visible = false
        end
    end
end

---Slider drag: commit the raw per-second value and mirror it into the row's
---textfield. Updated in place (no rebuild) so the active drag is not dropped.
---@param event EventData.on_gui_value_changed
function handlers.on_amount_slider_changed(event)
    local slider = event.element
    local tags = slider.tags
    local player_data = save.get_player_data(event.player_index)
    local multiplier = slider.slider_value
    local base = tags.base --[[@as number]]
    local amount_per_second = base * multiplier

    commit_amount(event.player_index, tags, amount_per_second)

    local field = slider.parent.parent["controls"]["amount_field"]
    if field then
        field.text = tostring(amount_to_display(tags.type --[[@as FilterType]], base, player_data)) .. "*" .. multiplier
    end
end

---Belt / pump quick-set: set the prototype's throughput as the base value,
---keeping the field's current multiplier (like the default button).
---@param event EventData.on_gui_click
function handlers.on_throughput_click(event)
    local player_data = save.get_player_data(event.player_index)
    local button = event.element
    apply_base(event.player_index, button, button.tags.rate_per_second --[[@as number]], player_data)
end

---Set the type-appropriate default value as the base (keeping the slider's
---multiplier, like the throughput buttons).
---@param event EventData.on_gui_click
function handlers.on_default_click(event)
    local button = event.element
    local player_data = save.get_player_data(event.player_index)
    local base = save.default_base(button.tags.type --[[@as FilterType]], button.tags.name --[[@as string]])
    apply_base(event.player_index, button, base, player_data)
end

---@param event EventData.on_gui_text_changed
function handlers.on_limit_amount_confirmed(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)

    local amount, ok = eval_amount_expression(elem.text)
    -- Mid-typing partial expressions ("60*", "(1+") evaluate as failure; do
    -- not clobber the saved value with 0 just because the user is in the
    -- middle of a keystroke. The next valid text-changed event will commit.
    if not ok then return end
    if not (tags.type == "recipe" or tags.type == "virtual_recipe") then
        amount = fs_util.from_scale(amount, player_data.time_scale)
    end

    commit_amount(event.player_index, tags, amount)

    -- Keep the popup slider following the field: re-parse "base*mult" so editing
    -- the text moves the slider to the typed multiplier.
    local popup = elem.parent.parent["popup"]
    if popup and popup.visible then
        local slider = popup["amount_slider"]
        if slider then
            local is_recipe = tags.type == "recipe" or tags.type == "virtual_recipe"
            sync_slider_from_field(slider, elem.text, is_recipe, player_data)
        end
    end
end

---@param event EventData.on_gui_selection_state_changed
function handlers.on_limit_type_changed(event)
    local elem = event.element
    local tags = elem.tags
    local typed_name = tn.create_typed_name(
        tags.type --[[@as FilterType]],
        tags.name --[[@as string]],
        tags.quality --[[@as string?]],
        tags.minimum_temperature --[[@as number?]],
        tags.maximum_temperature --[[@as number?]])
    local solution = assert(save.get_selected_solution(event.player_index))

    local pos = assert(fs_util.find(solution.constraints, function(value)
        return tn.equals_typed_name(value, typed_name)
    end))
    local limit_type = flib_table.find(limit_type_to_index, elem.selected_index)

    save.update_constraint(solution, pos, { limit_type = limit_type })
end

---@param event EventData.on_gui_click
function handlers.on_move_constraint_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local from_constraint_index = tags.constraint_index --[[@as integer]]
    local direction = tags.direction

    -- Indices shift on a move, so a lingering open popup would attach to the
    -- wrong row; close it.
    save.get_player_data(event.player_index).expanded_constraint_index = nil

    if direction == "up" then
        local to_constraint_index
        if event.shift then
            to_constraint_index = 1
        elseif event.control then
            to_constraint_index = from_constraint_index - 5
        else
            to_constraint_index = from_constraint_index - 1
        end
        save.move_constraint(solution, from_constraint_index, to_constraint_index)
    elseif direction == "down" then
        local to_constraint_index
        if event.shift then
            to_constraint_index = #solution.constraints
        elseif event.control then
            to_constraint_index = from_constraint_index + 5
        else
            to_constraint_index = from_constraint_index + 1
        end
        save.move_constraint(solution, from_constraint_index, to_constraint_index)
    end

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_constraint_changed")
end

---@param event EventData.on_gui_click
function handlers.on_remove_constraint_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    -- Same index-shift reasoning as the move handler.
    save.get_player_data(event.player_index).expanded_constraint_index = nil

    save.delete_constraint(solution, tags.constraint_index --[[@as integer]])

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_constraint_changed")
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "solution_settings",
    style = "factory_solver_right_panel_half_frame",
    direction = "vertical",
    {
        type = "scroll-pane",
        style = "factory_solver_right_panel_scroll_pane",
        horizontal_scroll_policy = "never",
        vertical_scroll_policy = "auto",
        {
            type = "label",
            style = "caption_label",
            caption = { "factory-solver-constraints" },
        },
        {
            type = "flow",
            name = "constraint_list",
            direction = "vertical",
            style_mods = { vertical_spacing = 10, bottom_margin = 4 },
            handler = {
                on_added = handlers.on_make_constraints_table,
                on_selected_solution_changed = handlers.on_make_constraints_table,
                on_constraint_changed = handlers.on_make_constraints_table,
                on_amount_unit_changed = handlers.on_make_constraints_table,
            },
        },
        {
            type = "button",
            caption = { "factory-solver-add-constraint" },
            handler = {
                [defines.events.on_gui_click] = handlers.on_add_constraint_click,
                on_added = handlers.on_add_constraint_button_enabled,
                on_selected_solution_changed = handlers.on_add_constraint_button_enabled,
            },
        },
    },
}
