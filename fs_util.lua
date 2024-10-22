local flib_gui = require "__flib__/gui"
local flib_table = require "__flib__/table"

local M = {}

---Returns an index of first element that matches the condition.
---@generic K, V
---@param tbl table<K, V>
---@param fun fun(value: V, key: K): boolean
---@return K?
function M.find(tbl, fun)
    for key, value in pairs(tbl) do
        if fun(value, key) then
            return key
        end
    end
    return nil
end

---Returns a table containing arrays with elements grouped
---according to values returned by the callback function.
---@generic K, V, R
---@param tbl table<K, V>
---@param fun fun(value: V, key: K): R
---@return table<R, V[]>
function M.group_by(tbl, fun)
    local grouping = {}
    for key, value in pairs(tbl) do
        local group_key = fun(value, key)
        if not grouping[group_key] then
            grouping[group_key] = {}
        end
        flib_table.insert(grouping[group_key], value)
    end
    return grouping
end

---Converts the table to list.
---@generic V
---@param tbl table<any, V>
---@return V[]
function M.to_list(tbl)
    local list = {}
    for _, value in pairs(tbl) do
        flib_table.insert(list, value)
    end
    return list
end

---Sorts prototypes by standard method of factorio.
---@generic V
---@param list (V | { order: string, name: string })[]
---@return V[]
function M.sort_prototypes(list)
    flib_table.sort(list, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        else
            return a.name < b.name
        end
    end)
    return list
end

---comment
---@param player_index integer
---@return LuaForce
function M.get_force(player_index)
    return game.players[player_index].force --[[@as LuaForce]]
end

---comment
---@param value number
---@return boolean
function M.is_nan(value)
    return value ~= value
end

---comment
---@param value number
---@return boolean
function M.is_infinite(value)
    return value == math.huge or value == -math.huge
end

---Add a new child or children to the given GUI element.
---@param parent LuaGuiElement
---@param def flib.GuiElemDef
---@param append_tags table?
---@return table<string, LuaGuiElement> elems
---@return LuaGuiElement first
function M.add_gui(parent, def, append_tags)
    local res_elems, first = flib_gui.add(parent, def)
    first.tags = flib_table.shallow_merge{
        first.tags,
        append_tags,
    }
    M.dispatch_to_subtree(first, "on_added")
    return res_elems, first
end

M.add_handlers = flib_gui.add_handlers

---Collect necessary data and create an event.
---@param element LuaGuiElement
---@param event_name string?
---@param data table?
---@return EventDataTrait
function M.create_gui_event(element, event_name, data)
    local event = {
        element = element,
        mod_name = element.get_mod(),
        name = event_name or "",
        player_index = element.player_index,
        tick = game.tick,
    }
    event = flib_table.deep_merge { event, data }
    return event
end

---Dispatch an event to the element.
---@param element LuaGuiElement
---@param event_name string
---@param data table?
function M.dispatch(element, event_name, data)
    local event = M.create_gui_event(element, event_name, data)
    ---@diagnostic disable-next-line: param-type-mismatch
    flib_gui.dispatch(event)
end

---Dispatches an event to all lower elements on the root element.
---@param root_element LuaGuiElement
---@param event_name string
---@param append_data table?
function M.dispatch_to_subtree(root_element, event_name, append_data)
    local elements = {}
    for e in M.dfs_lower(root_element) do
        flib_table.insert(elements, e)
    end

    for _, e in ipairs(elements) do
        if e.valid then
            local event = M.create_gui_event(e, event_name, append_data)
            ---@diagnostic disable-next-line: param-type-mismatch
            flib_gui.dispatch(event)
        end
    end
end

---Returns an element with matching name from upper elements.
---@param start_element LuaGuiElement
---@param name string
---@return LuaGuiElement?
function M.find_upper(start_element, name)
    for element in M.follow_upper(start_element) do
        if element.name == name then
            return element
        end
    end
    return nil
end

---Iterate over all lower elements of the starting element in depth-first search.
---Note that if elements are added or deleted in progress of iteration, they will not be iterated correctly.
---@param start_element LuaGuiElement
---@return fun(): LuaGuiElement?
function M.dfs_lower(start_element)
    local element_stack = { start_element }
    local index_stack = { 0 }

    function it()
        local tail = #element_stack
        if tail == 0 then
            return nil
        end

        local current = element_stack[tail]
        local children = current.children

        local index = index_stack[tail]
        index_stack[tail] = index + 1

        if index == 0 then
            return current
        elseif index <= #children then
            table.insert(element_stack, children[index])
            table.insert(index_stack, 0)
            return it()
        else
            table.remove(element_stack)
            table.remove(index_stack)
            return it()
        end
    end

    return it
end

---Iterates elements from the start element to the root element.
---@param start_element LuaGuiElement
---@return fun(): LuaGuiElement?
function M.follow_upper(start_element)
    local current = start_element

    function it()
        local ret = current
        if current then
            current = current.parent
        end
        return ret
    end

    return it
end

return M
