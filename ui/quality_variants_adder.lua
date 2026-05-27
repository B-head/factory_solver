local flib_table = require "__flib__/table"
local fs_util = require "fs_util"
local save = require "manage/save"
local common = require "ui/common"

local handlers = {}

---Walk dialog descendants for the named quality-button flow.
---@param dialog LuaGuiElement
---@return LuaGuiElement
local function find_quality_flow(dialog)
    for e in fs_util.dfs_lower(dialog) do
        if e.name == "quality_button_flow" then
            return e
        end
    end
    error("quality_button_flow not found")
end

---Collect the qualities of every production line whose recipe matches the
---dialog's `recipe_typed_name` (same type + name, any quality).
---@param solution Solution
---@param recipe_typed_name TypedName
---@return table<string, true>
local function collect_existing_qualities(solution, recipe_typed_name)
    local existing = {}
    for _, line in ipairs(solution.production_lines) do
        local rtn = line.recipe_typed_name
        if rtn.type == recipe_typed_name.type and rtn.name == recipe_typed_name.name then
            existing[rtn.quality] = true
        end
    end
    return existing
end

---@param event EventDataTrait
function handlers.on_make_quality_buttons(event)
    local dialog = assert(fs_util.find_upper(event.element, "factory_solver_quality_variants_adder"))
    local tags = dialog.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local source_quality = tags.source_quality --[[@as string]]
    local recipe_typed_name = tags.recipe_typed_name --[[@as TypedName]]
    local source_proto = prototypes.quality[source_quality]
    local source_level = source_proto and source_proto.level or 0

    -- Initial set = (source quality and above) ∪ (qualities already in the
    -- solution for this recipe). The union ensures lower-level pre-existing
    -- lines (e.g. a normal line below an uncommon source) show up as checked
    -- so the user sees the full current state, not just the defaults.
    local existing = collect_existing_qualities(solution, recipe_typed_name)
    local initial_set = {}
    for _, q in pairs(prototypes.quality) do
        if not q.hidden and q.level >= source_level then
            initial_set[q.name] = true
        end
    end
    for quality_name in pairs(existing) do
        initial_set[quality_name] = true
    end
    initial_set[source_quality] = true

    common.make_quality_buttons_multi(event.element, initial_set, handlers.on_quality_clicked)
end

---@param event EventData.on_gui_click
function handlers.on_quality_clicked(event)
    common.on_quality_button_clicked_multi(event.element)
end

---Confirm = "this recipe should be present in the solution at exactly these
---qualities". Implementation: snapshot the existing lines for the recipe,
---delete them all, then re-insert at the anchor in quality-level order.
---Existing lines are re-inserted from the snapshot (preserving machine /
---module / fuel / substrate). Newly-added qualities clone the source line's
---configuration as a template (recipe quality is the only field that
---changes) so machines, modules, fuel, beacons, and substrate are
---inherited rather than reset to the machine preset.
---@param event EventData.on_gui_click
function handlers.on_confirm(event)
    local dialog = assert(common.find_root_element(event.player_index,
        "factory_solver_quality_variants_adder"))
    local tags = dialog.tags
    local recipe_typed_name = tags.recipe_typed_name --[[@as TypedName]]
    local source_quality = tags.source_quality --[[@as string]]
    local solution = assert(save.get_selected_solution(event.player_index))

    local quality_flow = find_quality_flow(dialog)
    local final_set = common.read_quality_button_set(quality_flow)

    local snapshot = {} --[[@as table<string, ProductionLine>]]
    local indices = {}
    for li, line in ipairs(solution.production_lines) do
        local rtn = line.recipe_typed_name
        if rtn.type == recipe_typed_name.type and rtn.name == recipe_typed_name.name then
            snapshot[rtn.quality] = flib_table.deep_copy(line)
            indices[#indices + 1] = li
        end
    end

    local source_template = snapshot[source_quality]

    local anchor = indices[1] or (#solution.production_lines + 1)
    for _, li in ipairs(indices) do
        if li < anchor then anchor = li end
    end

    -- Delete from the back so earlier indices stay stable while iterating.
    table.sort(indices, function(a, b) return a > b end)
    for _, li in ipairs(indices) do
        save.delete_production_line(solution, li)
    end

    local final_qualities = {}
    for name in pairs(final_set) do
        local proto = prototypes.quality[name]
        if proto then
            final_qualities[#final_qualities + 1] = proto
        end
    end
    table.sort(final_qualities, function(a, b) return a.level > b.level end)

    for i, q in ipairs(final_qualities) do
        local li = anchor + i - 1
        local restored = snapshot[q.name]
        if restored then
            -- The source quality was already correct; for any other restored
            -- line the quality matches the snapshot key by construction.
            restored.recipe_typed_name.quality = q.name
            flib_table.insert(solution.production_lines, li, restored)
        elseif source_template then
            local cloned = flib_table.deep_copy(source_template)
            cloned.recipe_typed_name.quality = q.name
            flib_table.insert(solution.production_lines, li, cloned)
        else
            local new_tn = flib_table.deep_copy(recipe_typed_name)
            new_tn.quality = q.name
            save.new_production_line(event.player_index, solution, new_tn, nil, li)
        end
    end
    solution.solver_state = "ready"

    local re_event = fs_util.create_gui_event(dialog)
    common.on_close_self(re_event)

    local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "factory_solver_quality_variants_adder",
    direction = "vertical",
    handler = {
        [defines.events.on_gui_closed] = common.on_close_self,
    },
    {
        type = "flow",
        name = "title_bar",
        style = "flib_titlebar_flow",
        tags = {
            drag_target = "factory_solver_quality_variants_adder",
        },
        handler = {
            on_added = common.on_init_drag_target
        },
        {
            type = "label",
            style = "frame_title",
            caption = { "factory-solver-quality-variants-title" },
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
                close_target = "factory_solver_quality_variants_adder",
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
            name = "quality_button_flow",
            style = "factory_solver_centering_horizontal_flow",
            style_mods = { horizontal_spacing = 0 },
            direction = "horizontal",
            handler = {
                on_added = handlers.on_make_quality_buttons,
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
                close_target = "factory_solver_quality_variants_adder",
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
                [defines.events.on_gui_click] = handlers.on_confirm,
            }
        },
    },
}
