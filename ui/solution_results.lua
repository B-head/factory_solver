local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local nf = require "manage/number_format"
local report = require "manage/report"
local save = require "manage/save"
local tn = require "manage/typed_name"
local bp = require "manage/blueprint"
local common = require "ui/common"
local production_line_adder = require "ui/production_line_adder"

local handlers = {}

---Reorder the results panel's Final products and Initial ingredients sections to
---match the row order (Initial ingredients first by default; the "Classic
---top-to-bottom order" setting opts out). The two
---sections are the first four children of the scroll-pane (final label/frame,
---then initial label/frame); the divider, totals and build-totals that follow
---stay put. Idempotent: it only swaps when the current first caption disagrees
---with the wanted order, so it can re-fire on on_production_line_changed when the
---setting is toggled without ping-ponging.
---@param event EventDataTrait
function handlers.on_arrange_result_sections(event)
    local scroll = event.element
    local want_initial_first = common.is_production_line_order_reversed(event.player_index)
    local first_is_initial = scroll.children[1].name == "initial_ingredients_caption"
    if want_initial_first ~= first_is_initial then
        scroll.swap_children(1, 3) -- label(final) <-> label(initial)
        scroll.swap_children(2, 4) -- frame(final) <-> frame(initial)
    end
end

---Run `add` over every entry of each total bucket, passing that bucket's
---largest gross_per_second so the callback can floor out IPM-residual materials
---(acc.is_residual_gross). max_gross is computed PER bucket rather than across
---all three because item / fluid / virtual throughputs live on unrelated scales
---(heat at thousands/s vs an item at 0.1/s); a cross-bucket max would let the
---largest bucket silently raise the floor on a smaller one and eat a genuine
---small flow.
---@param add fun(entry: { amount_per_second: number, gross_per_second: number, typed_name: TypedName }, max_gross: number)
---@param ... table<string, { amount_per_second: number, gross_per_second: number, typed_name: TypedName }>
local function add_each_bucket(add, ...)
    for _, bucket in ipairs({ ... }) do
        local max_gross = 0
        for _, entry in pairs(bucket) do
            if entry.gross_per_second > max_gross then
                max_gross = entry.gross_per_second
            end
        end
        for _, entry in pairs(bucket) do
            add(entry, max_gross)
        end
    end
end

---@param event EventDataTrait
function handlers.make_final_products_table(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution or solution.solver_state == "calculating" then
        return
    end
    local item_totals, fluid_totals, virtual_totals = report.get_total_amounts(save.get_research_bonuses(event.player_index), solution)

    local function add(entry, max_gross)
        local typed_name = entry.typed_name
        -- Final Products are net > 0. Hide a net that is negligible RELATIVE to
        -- the material's gross throughput (acc.is_negligible), so a recycling
        -- loop's residual noise doesn't surface as a phantom product while a
        -- genuine small surplus still shows. is_residual_gross adds the second
        -- floor for a material whose ENTIRE throughput is IPM noise (gross tiny
        -- against the bucket's real scale) -- is_negligible can't catch that
        -- because net/gross is then O(1).
        local number = entry.amount_per_second
        if number <= 0 or acc.is_negligible(number, entry.gross_per_second)
            or acc.is_residual_gross(entry.gross_per_second, max_gross) then
            return
        end
        number = fs_util.to_scale(number, player_data.time_scale)

        local craft = tn.typed_name_to_material(typed_name)
        local is_hidden = acc.is_hidden(craft)
        local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

        local def = common.create_decorated_sprite_button{
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            number = nf.round_for_kind(number, nf.kind_for_material(typed_name)),
            tags = {
                line_index = nil,
                typed_name = typed_name,
                is_product = true,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_total_inout_click,
            },
        }
        common.append_tooltip_line(def, common.op_hints.inout())
        fs_util.add_gui(elem, def)
    end

    add_each_bucket(add, item_totals, fluid_totals, virtual_totals)
end

---@param event EventDataTrait
function handlers.make_basic_ingredients_table(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution or solution.solver_state == "calculating" then
        return
    end
    local item_totals, fluid_totals, virtual_totals = report.get_total_amounts(save.get_research_bonuses(event.player_index), solution)

    local function add(entry, max_gross)
        local typed_name = entry.typed_name
        -- Basic Ingredients are net < 0 (consumed from outside). Hide a net
        -- that is negligible RELATIVE to gross throughput so a recycling loop's
        -- residual noise doesn't surface as a phantom ingredient.
        -- is_residual_gross adds the second floor for a material whose ENTIRE
        -- throughput is IPM noise (gross tiny against the bucket's real scale).
        local number = entry.amount_per_second
        if 0 <= number or acc.is_negligible(number, entry.gross_per_second)
            or acc.is_residual_gross(entry.gross_per_second, max_gross) then
            return
        end
        number = fs_util.to_scale(-number, player_data.time_scale)

        local craft = tn.typed_name_to_material(typed_name)
        local is_hidden = acc.is_hidden(craft)
        local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

        local def = common.create_decorated_sprite_button{
            typed_name = typed_name,
            is_hidden = is_hidden,
            is_unresearched = is_unresearched,
            number = nf.round_for_kind(number, nf.kind_for_material(typed_name)),
            tags = {
                line_index = nil,
                typed_name = typed_name,
                is_product = false,
            },
            handler = {
                [defines.events.on_gui_click] = handlers.on_total_inout_click,
            },
        }
        common.append_tooltip_line(def, common.op_hints.inout())
        fs_util.add_gui(elem, def)
    end

    add_each_bucket(add, item_totals, fluid_totals, virtual_totals)
end

---@param event EventData.on_gui_click
function handlers.on_total_inout_click(event)
    if common.try_open_factoriopedia(event) then return end
    local tags = event.element.tags
    local typed_name = tags.typed_name --[[@as TypedName]]
    if event.button == defines.mouse_button_type.left then
        local data = {
            typed_name = typed_name,
            is_choose_product = not tags.is_product,
            is_choose_ingredient = tags.is_product,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))
    
        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---@param event EventDataTrait
function handlers.update_total_power_label(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    if not solution then
        elem.caption = common.format_power(0)
        elem.tooltip = common.format_power(0, "W")
        return
    end

    local watts = report.get_total_power(save.get_research_bonuses(event.player_index), solution)
    elem.caption = common.format_power(fs_util.to_scale(watts, player_data.time_scale))
    -- Tooltip shows the scale-independent total in watts (the caption is energy
    -- per the selected time unit).
    elem.tooltip = common.format_power(watts, "W")
end

---@param event EventDataTrait
function handlers.update_total_pollution_label(event)
    local elem = event.element
    local player_data = save.get_player_data(event.player_index)
    local solution = save.get_selected_solution(event.player_index)

    if not solution then
        elem.caption = flib_format.number(0, true, 5)
        return
    end

    local total_pollution = fs_util.to_scale(report.get_total_pollution(save.get_research_bonuses(event.player_index), solution), player_data.time_scale)
    elem.caption = flib_format.number(total_pollution, true, 5)
end

---Aggregate, across the whole solution, the physical machines / modules /
---beacons the player must build and carry. Counts are PHYSICAL whole entities:
---each line's fractional machine count is rounded up (math.ceil), because a
---2.3-machine line still needs 3 machines' worth of slots filled. Beacon module
---counts use RAW slot occupancy (slots × beacon_quantity × machines), NOT the
---effectivity-scaled value acc.get_total_modules reports — the latter is an LP
---input, not a "how many items to fetch" count. Buckets are keyed by
---(name × quality) so e.g. normal vs rare modules are listed separately.
---@param event EventDataTrait
function handlers.make_build_totals_table(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution or solution.solver_state == "calculating" then
        return
    end

    local machines, modules, beacons = {}, {}, {}
    ---@param bucket table<string, { typed_name: TypedName, count: number }>
    ---@param typed_name TypedName
    ---@param amount number
    local function bump(bucket, typed_name, amount)
        local key = string.format("%s/%s", typed_name.name, typed_name.quality)
        local entry = bucket[key]
        if entry then
            entry.count = entry.count + amount
        else
            bucket[key] = { typed_name = typed_name, count = amount }
        end
    end

    for _, line in ipairs(solution.production_lines) do
        if bp.can_pipette(line) then
            -- Pad INWARD by the solver's relative residual before the ceil: the
            -- IPM converges to a relative tolerance, so a true 3-machine line can
            -- solve to 3.0000002 and a fixed `+ acc.tolerance` would push it to 4
            -- (worse, the larger the count). Multiplying by (1 - acc.tolerance)
            -- snaps that noise down to 3 while a genuine fractional excess (e.g.
            -- 3.00003, well above the relative tolerance) still ceils to 4.
            local phys = math.ceil(save.get_quantity_of_machines_required(solution, line.recipe_typed_name)
                * (1 - acc.tolerance))
            if 0 < phys then
                local machine = tn.typed_name_to_machine(line.machine_typed_name)
                bump(machines, line.machine_typed_name, phys)

                local size = machine.module_inventory_size
                if size and 0 < size then
                    local trimmed = acc.trim_modules(line.module_typed_names, size)
                    for index = 1, size do
                        local module = trimmed[tostring(index)]
                        if module then bump(modules, module, phys) end
                    end
                end

                if acc.is_use_beacon(machine) then
                    for _, affected_by_beacon in ipairs(line.affected_by_beacons) do
                        local beacon_typed_name = affected_by_beacon.beacon_typed_name
                        local beacon = beacon_typed_name and acc.get_beacon(beacon_typed_name.name)
                        if beacon and beacon_typed_name then
                            local total = phys * affected_by_beacon.beacon_quantity
                            bump(beacons, beacon_typed_name, total)
                            local beacon_size = beacon.module_inventory_size
                            if beacon_size and 0 < beacon_size then
                                local beacon_trimmed = acc.trim_modules(affected_by_beacon.module_typed_names, beacon_size)
                                for index = 1, beacon_size do
                                    local module = beacon_trimmed[tostring(index)]
                                    if module then bump(modules, module, total) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- One flat slot table for all three kinds (machines, then modules, then
    -- beacons). The icons themselves distinguish the kinds, so per-group labels
    -- and frames would only waste vertical space.
    ---@param bucket table<string, { typed_name: TypedName, count: number }>
    ---@param is_machine_kind boolean
    local function append(bucket, is_machine_kind)
        local list = {}
        for _, entry in pairs(bucket) do
            table.insert(list, entry)
        end
        table.sort(list, function(a, b)
            if a.typed_name.name ~= b.typed_name.name then
                return a.typed_name.name < b.typed_name.name
            end
            return a.typed_name.quality < b.typed_name.quality
        end)

        for _, entry in ipairs(list) do
            local craft = is_machine_kind
                and tn.typed_name_to_machine(entry.typed_name)
                or tn.typed_name_to_material(entry.typed_name)
            fs_util.add_gui(elem, common.create_decorated_sprite_button {
                typed_name = entry.typed_name,
                is_hidden = acc.is_hidden(craft),
                is_unresearched = acc.is_unresearched(craft, relation_to_recipes),
                number = entry.count,
            })
        end
    end

    append(machines, true)
    append(modules, false)
    append(beacons, true)
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "solution_result",
    style = "factory_solver_right_panel_result_frame",
    direction = "vertical",
    {
        type = "scroll-pane",
        name = "result_sections_scroll",
        style = "factory_solver_right_panel_result_scroll_pane",
        horizontal_scroll_policy = "never",
        vertical_scroll_policy = "auto",
        handler = {
            on_added = handlers.on_arrange_result_sections,
            on_production_line_changed = handlers.on_arrange_result_sections,
        },
        {
            type = "label",
            name = "final_products_caption",
            style = "caption_label",
            caption = { "factory-solver-final-products" },
        },
        {
            type = "frame",
            style = "factory_solver_result_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 8,
                handler = {
                    on_added = handlers.make_final_products_table,
                    on_selected_solution_changed = handlers.make_final_products_table,
                    on_machine_setups_changed = handlers.make_final_products_table,
                    on_amount_unit_changed = handlers.make_final_products_table,
                    on_calculation_changed = handlers.make_final_products_table,
                },
            },
        },
        {
            type = "label",
            name = "initial_ingredients_caption",
            style = "caption_label",
            caption = { "factory-solver-initial-ingredients" },
        },
        {
            type = "frame",
            style = "factory_solver_result_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 8,
                handler = {
                    on_added = handlers.make_basic_ingredients_table,
                    on_selected_solution_changed = handlers.make_basic_ingredients_table,
                    on_machine_setups_changed = handlers.make_basic_ingredients_table,
                    on_amount_unit_changed = handlers.make_basic_ingredients_table,
                    on_calculation_changed = handlers.make_basic_ingredients_table,
                },
            },
        },
        {
            type = "line",
            style = "factory_solver_line",
        },
        {
            type = "flow",
            style = "factory_solver_result_centering_flow",
            {
                type = "table",
                style = "factory_solver_result_layout_table",
                column_count = 2,
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-total-power" },
                },
                {
                    type = "label",
                    handler = {
                        on_added = handlers.update_total_power_label,
                        on_selected_solution_changed = handlers.update_total_power_label,
                        on_machine_setups_changed = handlers.update_total_power_label,
                        on_amount_unit_changed = handlers.update_total_power_label,
                        on_calculation_changed = handlers.update_total_power_label,
                    },
                },
                {
                    type = "label",
                    style = "caption_label",
                    caption = { "factory-solver-total-pollution" },
                },
                {
                    type = "label",
                    handler = {
                        on_added = handlers.update_total_pollution_label,
                        on_selected_solution_changed = handlers.update_total_pollution_label,
                        on_machine_setups_changed = handlers.update_total_pollution_label,
                        on_amount_unit_changed = handlers.update_total_pollution_label,
                        on_calculation_changed = handlers.update_total_pollution_label,
                    },
                },
            },
        },
        {
            type = "line",
            style = "factory_solver_line",
        },
        {
            type = "label",
            style = "caption_label",
            caption = { "factory-solver-build-totals" },
        },
        {
            type = "frame",
            style = "factory_solver_result_slot_background_frame",
            {
                type = "table",
                style = "filter_slot_table",
                column_count = 8,
                handler = {
                    on_added = handlers.make_build_totals_table,
                    on_selected_solution_changed = handlers.make_build_totals_table,
                    on_machine_setups_changed = handlers.make_build_totals_table,
                    on_calculation_changed = handlers.make_build_totals_table,
                },
            },
        },
    },
}
