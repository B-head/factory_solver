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
        return "+" .. flib_format.number(-power, true, 5) .. "J"
    else
        return flib_format.number(power, true, 5) .. "J"
    end
end

---comment
---@return boolean
function M.is_active_quality()
    return script.active_mods["quality"] ~= nil
end

---comment
---@param data table
---@return flib.GuiElemDef
function M.create_decorated_sprite_button(data)
    local typed_name = assert(data.typed_name) --[[@as TypedName]]
    local is_hidden = data.is_hidden or false
    local is_unresearched = data.is_unresearched or false
    local children = {}

    if typed_name.quality ~= "normal" then
        local def = {
            type = "sprite",
            style = "factory_solver_slot_image_with_quality",
            sprite = "quality/" .. typed_name.quality,
        }
        flib_table.insert(children, def)
    end

    return {
        type = "sprite-button",
        style = M.get_style(is_hidden, is_unresearched, typed_name.type),
        sprite = tn.get_sprite_path(typed_name),
        tooltip = tn.typed_name_to_tooltip(typed_name),
        elem_tooltip = tn.typed_name_to_elem_id(typed_name),
        number = data.number,
        tags = data.tags,
        handler = data.handler,
        children = children
    }
end

---comment
---@param player_index integer
---@param is_dialog boolean
---@param gui_def flib.GuiElemDef
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
        local sentinel_name = "|sentinel|" .. name
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
