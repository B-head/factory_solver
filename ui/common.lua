local flib_table = require "__flib__/table"
local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local save = require "manage/save"
local tn = require "manage/typed_name"

local M = {}

---comment
---@param is_hidden boolean
---@param is_unresearched boolean
---@param filter_type FilterType?
---@return string
function M.get_style(is_hidden, is_unresearched, filter_type)
    if is_hidden then
        return "flib_slot_button_grey"
    elseif is_unresearched then
        return "flib_slot_button_orange"
    else
        if filter_type == "recipe" or filter_type == "virtual_recipe" then
            return "flib_slot_button_blue"
        else
            return "flib_slot_button_default"
        end
    end
end

---comment
---@param is_hidden boolean
---@param is_unresearched boolean
---@param player_data PlayerLocalData
---@return boolean
function M.craft_visible(is_hidden, is_unresearched, player_data)
    if is_hidden then
        return player_data.hidden_craft_visible
    elseif is_unresearched then
        return player_data.unresearched_craft_visible
    end

    return true
end

---comment
---@param group_infos GroupInfos
---@param group_name string
---@param player_data PlayerLocalData
---@return boolean
function M.group_visible(group_infos, group_name, player_data)
    local group_info = group_infos[group_name]
    if not group_info then
        return false
    end

    if player_data.hidden_craft_visible and 0 < group_info.hidden_count then
        return true
    elseif player_data.unresearched_craft_visible and 0 < group_info.unresearched_count then
        return true
    elseif 0 < group_info.researched_count then
        return true
    else
        return false
    end
end

---comment
---@param power number
---@return string
function M.format_power(power)
    if power < 0 then
        local temp = flib_format.number(-power, true, 5)
        return string.format("+%sJ", temp)
    else
        local temp = flib_format.number(power, true, 5)
        return string.format("%sJ", temp)
    end
end

---comment
---@param data table
---@return fs.GuiElemDef
function M.create_decorated_sprite_button(data)
    local typed_name = assert(data.typed_name) --[[@as TypedName]]
    local is_hidden = data.is_hidden or false
    local is_unresearched = data.is_unresearched or false
    local children = {}

    if typed_name.temperature ~= nil then
        flib_table.insert(children, {
            type = "flow",
            direction = "vertical",
            style = "factory_solver_slot_temperature_flow",
            ignored_by_interaction = true,
            children = {
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = string.format("%g°", typed_name.temperature),
                    ignored_by_interaction = true,
                },
            },
        })
    elseif typed_name.minimum_temperature ~= nil then
        flib_table.insert(children, {
            type = "flow",
            direction = "vertical",
            style = "factory_solver_slot_temperature_flow",
            ignored_by_interaction = true,
            children = {
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = string.format("%g°~", typed_name.minimum_temperature),
                    ignored_by_interaction = true,
                },
                {
                    type = "label",
                    style = "factory_solver_slot_temperature_label",
                    caption = string.format("%g°", typed_name.maximum_temperature),
                    ignored_by_interaction = true,
                },
            },
        })
    end

    return {
        type = "sprite-button",
        style = M.get_style(is_hidden, is_unresearched, typed_name.type),
        sprite = tn.get_sprite_path(typed_name),
        quality = typed_name.quality,
        tooltip = tn.typed_name_to_tooltip(typed_name),
        elem_tooltip = tn.typed_name_to_elem_id(typed_name),
        number = data.number,
        tags = data.tags,
        handler = data.handler,
        children = children
    }
end

---Resolve an ElemID to the prototype that LuaPlayer.open_factoriopedia_gui
---accepts and open Factoriopedia. Quality is intentionally dropped: the
---Factoriopedia surface is per-prototype, not per-quality variant. Returns
---true on a successful open so callers can decide whether to suppress the
---button's normal click action. Branches here cover the ElemID types that
---factory_solver actually emits into elem_tooltip (item / fluid / entity /
---recipe / tile + their *-with-quality variants). item-group elem_tooltips
---exist on constraint_adder filter buttons but open_factoriopedia_gui does
---not accept LuaGroup; those return false so the normal filter switch still
---fires when the user holds Alt.
---@param player LuaPlayer
---@param elem_id ElemID
---@return boolean opened
function M.open_factoriopedia_from_elem_id(player, elem_id)
    local t = elem_id.type
    local name = elem_id.name
    local proto
    if t == "item" or t == "item-with-quality" then
        proto = prototypes.item[name]
    elseif t == "entity" or t == "entity-with-quality" then
        proto = prototypes.entity[name]
    elseif t == "fluid" then
        proto = prototypes.fluid[name]
    elseif t == "recipe" or t == "recipe-with-quality" then
        proto = prototypes.recipe[name]
    elseif t == "tile" then
        proto = prototypes.tile[name]
    end
    if proto then
        player.open_factoriopedia_gui(proto)
        return true
    end
    return false
end

---If the click is Alt+left on a sprite-button whose elem_tooltip resolves to
---a Factoriopedia-accepted prototype, open Factoriopedia and return true so
---the caller can short-circuit its normal click flow. When the elem_tooltip
---is missing or its type cannot be opened (e.g. item-group), returns false
---and the caller's regular click action proceeds.
---@param event EventData.on_gui_click
---@return boolean handled
function M.try_open_factoriopedia(event)
    if not event.alt then return false end
    if event.button ~= defines.mouse_button_type.left then return false end
    local elem = event.element
    if not (elem and elem.valid) then return false end
    local elem_id = elem.elem_tooltip
    if not elem_id then return false end
    return M.open_factoriopedia_from_elem_id(game.players[event.player_index], elem_id)
end

---Builds a horizontal row of `tool_button` sprite-buttons inside `parent`, one per
---non-hidden quality, matching Factorio's engine-side quality selector. The button
---whose quality matches `initial_value` starts toggled. Each button stores its
---quality name in `tags.quality_name` and dispatches `on_click` on left-click.
---@param parent LuaGuiElement
---@param initial_value string
---@param on_click fun(event: EventData.on_gui_click)
function M.make_quality_buttons(parent, initial_value, on_click)
    local qualities = fs_util.sort_prototypes(fs_util.to_list(prototypes.quality))
    for _, value in ipairs(qualities) do
        if not value.hidden then
            fs_util.add_gui(parent, {
                type = "sprite-button",
                name = "factory_solver_quality_button_" .. value.name,
                style = "tool_button",
                sprite = "quality/" .. value.name,
                tooltip = { "", "[quality=", value.name, "] ", value.localised_name },
                toggled = (value.name == initial_value),
                tags = { quality_name = value.name },
                handler = {
                    [defines.events.on_gui_click] = on_click,
                },
            })
        end
    end
end

---Untoggles sibling quality buttons and toggles the clicked one. Returns the
---selected quality name pulled from `tags.quality_name`.
---@param clicked LuaGuiElement
---@return string selected_quality_name
function M.on_quality_button_clicked(clicked)
    for _, sibling in pairs(clicked.parent.children) do
        sibling.toggled = (sibling == clicked)
    end
    return clicked.tags.quality_name --[[@as string]]
end

---comment
---@param player_index integer
---@param is_dialog boolean
---@param gui_def fs.GuiElemDef
---@param append_data table?
---@return table<string, LuaGuiElement>
---@return LuaGuiElement
function M.open_gui(player_index, is_dialog, gui_def, append_data)
    local player = game.players[player_index]
    local opened_gui = storage.players[player_index].opened_gui
    local name = gui_def.name --[[@as string?]]
    local screen = player.gui.screen

    assert(name, "The name is required.")

    if screen[name] then
        local duplicate = screen[name]
        local event = fs_util.create_gui_event(duplicate)
        M.on_close_self(event)
    end

    if is_dialog then
        local sentinel_name = "%sentinel%" .. name
        local sentinel_def = {
            type = "empty-widget",
            name = sentinel_name,
            elem_mods = {
                location = { x = 0, y = 0 }
            },
            style_mods = {
                width = player.display_resolution.width,
                height = player.display_resolution.height,
            },
            tags = {
                close_target = name,
            },
            handler = {
                [defines.events.on_gui_click] = M.on_close_target,
            },
        }
        fs_util.add_gui(screen, sentinel_def)
        flib_table.insert(opened_gui, sentinel_name)
    end

    local elems, added = fs_util.add_gui(screen, gui_def, append_data)
    added.force_auto_center()
    player.opened = added
    flib_table.insert(opened_gui, name)

    return elems, added
end

---comment
---@param player_index integer
---@param name string
---@return LuaGuiElement?
function M.find_root_element(player_index, name)
    local player = game.players[player_index]
    for _, second_root in pairs(player.gui.children) do
        if second_root[name] then
            return second_root[name]
        end
    end
    return nil
end

---comment
---@param event EventDataTrait
function M.on_init_drag_target(event)
    local elem = event.element
    local target_name = elem.tags.drag_target --[[@as string]]
    local target = M.find_root_element(event.player_index, target_name)
    elem.drag_target = target
end

---comment
---@param event EventDataTrait
function M.on_close_self(event)
    local elem = event.element
    local player = game.players[event.player_index]
    local opened_gui = storage.players[event.player_index].opened_gui

    if elem.name == opened_gui[#opened_gui] then
        fs_util.dispatch_to_subtree(elem, "on_close")
        flib_table.remove(opened_gui)
        elem.destroy()
        if opened_gui[#opened_gui] then
            local target = assert(M.find_root_element(event.player_index, opened_gui[#opened_gui]))
            if event.name == defines.events.on_gui_closed or target.type == "empty-widget" then
                local re_event = flib_table.shallow_copy(event)
                re_event.element = target
                M.on_close_self(re_event)
            else
                player.opened = target
            end
        end
    end
end

---comment
---@param event EventDataTrait
function M.on_close_target(event)
    local elem = event.element
    local target_name = elem.tags.close_target --[[@as string]]

    local target = M.find_root_element(event.player_index, target_name)
    if target then
        local re_event = flib_table.shallow_copy(event)
        re_event.element = target
        M.on_close_self(re_event)
    end
end

---comment
---@param event EventDataTrait
function M.on_craft_visible_switch_added(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local is_show = player_data[elem.tags.state_name]

    if is_show then
        event.element.switch_state = "left"
    else
        event.element.switch_state = "right"
    end
end

---comment
---@param event EventData.on_gui_switch_state_changed
function M.on_craft_visible_switch_state_changed(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local is_show = event.element.switch_state == "left"
    player_data[elem.tags.state_name] = is_show

    local root = assert(fs_util.find_upper(elem, elem.tags.root_gui --[[@as string]]))
    fs_util.dispatch_to_subtree(root, "on_craft_visible_changed")
end

fs_util.add_handlers(M)

return M
