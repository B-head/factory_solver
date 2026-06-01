local flib_table = require "__flib__/table"
local flib_format = require "__flib__/format"
local fs_util = require "fs_util"
local acc = require "manage/accessor"
local nf = require "manage/number_format"
local pre_solve = require "manage/pre_solve"
local save = require "manage/save"
local tn = require "manage/typed_name"
local common = require "ui/common"
local machine_setup = require "ui/machine_setup"
local quality_variants_adder = require "ui/quality_variants_adder"
local production_line_adder = require "ui/production_line_adder"

local headers = {
    "",
    { "factory-solver-header-recipe" },
    { "factory-solver-header-required" },
    { "factory-solver-header-machine" },
    { "factory-solver-header-products" },
    { "factory-solver-header-ingredients" },
    { "factory-solver-header-power" },
    { "factory-solver-header-pollution" },
    "",
}

local handlers = {}

-- Dim color applied to label captions on lines that create_problem flagged as
-- inactive (= not graph-connected to any user Constraint). The numeric values
-- on those lines already collapse to 0 via get_quantity_of_machines_required,
-- but tinting the labels makes the disabled state read at a glance.
local inactive_font_color = { 0.5, 0.5, 0.5 }
local active_font_color = { 1, 1, 1 }

---@param solution Solution
---@param typed_name TypedName
---@return boolean
local function is_line_inactive(solution, typed_name)
    local set = solution.inactive_recipe_variables
    if not set then return false end
    local variable_name = string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
    return set[variable_name] == true
end

---@param event EventDataTrait
function handlers.make_production_line_table(event)
    local elem = event.element
    local solution = save.get_selected_solution(event.player_index)
    local relation_to_recipes = save.get_relation_to_recipes(event.player_index)

    elem.clear()
    if not solution then
        return
    elseif #solution.production_lines == 0 then
        return
    end

    for _, value in ipairs(headers) do
        local def = {
            type = "label",
            style = "bold_label",
            caption = value,
        }
        fs_util.add_gui(elem, def)
    end

    local bonuses = save.get_research_bonuses(event.player_index)
    for line_index, line in ipairs(solution.production_lines) do
        local recipe = tn.typed_name_to_recipe(line.recipe_typed_name)
        local machine = tn.typed_name_to_machine(line.machine_typed_name)
        local n, effectivity = acc.normalize_production_line(line, bonuses)
        -- Resolve bare fluid temperatures (product -> default, ingredient ->
        -- [default,max]) the same way the LP does, so the per-line slots show the
        -- concrete temperature instead of a blank "bare" label. A blank
        -- temperature then means only one thing in the UI: a temperature-agnostic
        -- (aggregate) constraint. normalize_production_line returns a fresh table,
        -- so the in-place mutation is local to this render.
        pre_solve.resolve_bare_fluids({ n })
        local recipe_tags = flib_table.deep_merge { { line_index = line_index }, line }

        do
            local def = {
                type = "flow",
                direction = "vertical",
                {
                    type = "sprite-button",
                    style = "mini_button",
                    sprite = "utility/speed_up",
                    tags = {
                        line_index = line_index,
                        direction = "up",
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_move_production_line_click,
                    },
                },
                {
                    type = "sprite-button",
                    style = "mini_button",
                    sprite = "utility/speed_down",
                    tags = {
                        line_index = line_index,
                        direction = "down",
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_move_production_line_click,
                    },
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local typed_name = line.recipe_typed_name
            local is_hidden = acc.is_hidden(recipe)
            local is_unresearched = acc.is_unresearched(recipe, relation_to_recipes)

            -- Recipe button intentionally has no paste_target tag: Shift+
            -- Click flows past the early-return below and falls into the
            -- existing left/right handling (open machine_setup / add
            -- constraint). Copying machine settings off the recipe icon
            -- would be ambiguous (which mode?), so the entry points are
            -- restricted to the machine / substrate / module icons.
            local def = common.create_decorated_sprite_button {
                typed_name = typed_name,
                is_hidden = is_hidden,
                is_unresearched = is_unresearched,
                tags = flib_table.deep_merge { recipe_tags, { is_recipe_icon = true } },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def = {
                type = "label",
                tags = {
                    result_typed_name = line.recipe_typed_name,
                },
                handler = {
                    on_added = handlers.update_machines_required,
                    on_amount_unit_changed = handlers.update_machines_required,
                    on_calculation_changed = handlers.update_machines_required,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            local machine_typed_name = line.machine_typed_name
            local is_hidden = acc.is_hidden(machine)
            local is_unresearched = acc.is_unresearched(machine, relation_to_recipes)

            -- Plant lines display the selected substrate tile instead of the
            -- plant entity here; the substrate button further below replaces
            -- it. Showing the plant entity as a "machine" misleads the user
            -- (1 craft = 1 plant slot, not 1 tower or 1 plant). The plant
            -- entity is still bound as machine_typed_name internally.
            --
            -- Spoilage virtual recipes share the same convention: there is
            -- no real machine that performs spoilage, so virtual.lua plugs
            -- an entity-unknown sentinel into machine_typed_name and we hide
            -- it here. The recipe icon mirrors the spoil_result item so the
            -- picker entry looks like "this thing turns into <result>".
            --
            -- Guard with `object_name == nil` first: real LuaRecipePrototype
            -- userdata raises on access to unknown keys, so probing
            -- `recipe.is_spoilage` directly would crash for every non-virtual
            -- recipe. Plain-table VirtualRecipes have no `object_name`.
            local is_spoilage_recipe = recipe and recipe.object_name == nil
                and recipe.is_spoilage == true
            -- Source / sink virtual recipes are equally machineless (entity-
            -- unknown sentinel). Hide the machine button like spoilage, but
            -- they get no placeholder sprite below -- the source/sink overlay
            -- on the recipe icon already conveys what the row does.
            local is_source_sink_recipe = recipe and recipe.object_name == nil
                and (recipe.is_source == true or recipe.is_sink == true)
            if machine.type ~= "plant" and not is_spoilage_recipe and not is_source_sink_recipe then
                local def = common.create_decorated_sprite_button {
                    typed_name = machine_typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                        tags = flib_table.deep_merge { recipe_tags, { paste_target = "machine_fuel" } },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local total_modules = acc.get_total_modules(machine, line.module_typed_names, line.affected_by_beacons)
            local split = acc.split_total_modules_by_effectiveness(recipe, machine, total_modules)

            for name, qualities in pairs(split) do
                for quality, counts in pairs(qualities) do
                    local module_typed_name = tn.create_typed_name("item", name, quality)
                    local module_tags = flib_table.deep_merge { recipe_tags, { paste_target = "module_beacon" } }
                    -- Effective contribution first, then the ineffective
                    -- sub-count as a separate slot so partial masking is
                    -- visible at-a-glance without collapsing into one
                    -- ambiguous total.
                    if counts.effective > 0 then
                        flib_table.insert(buttons, common.create_decorated_sprite_button {
                            typed_name = module_typed_name,
                            number = counts.effective,
                                        tags = module_tags,
                            handler = {
                                [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                            },
                        })
                    end
                    if counts.ineffective > 0 then
                        local def = common.create_decorated_sprite_button {
                            typed_name = module_typed_name,
                            number = counts.ineffective,
                            top_right_sprite = "utility/warning_icon",
                                        tags = module_tags,
                            handler = {
                                [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                            },
                        }
                        def.tooltip = { "", def.tooltip or "", "\n",
                            { "factory-solver-module-no-effect-here" } }
                        flib_table.insert(buttons, def)
                    end
                end
            end

            if line.substrate_tile_name then
                -- Plant production lines surface their selected substrate as
                -- a tile sprite in the machine cell so it's readable at a
                -- glance without opening machine_setup. Clicking routes
                -- through the same recipe-click handler so the same dialog
                -- opens, where Substrate section lets the user switch.
                local def = {
                    type = "sprite-button",
                    style = "flib_slot_button_default",
                    sprite = "tile/" .. line.substrate_tile_name,
                    elem_tooltip = { type = "tile", name = line.substrate_tile_name },
                    tags = flib_table.deep_merge { recipe_tags, { paste_target = "machine_fuel" } },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                    },
                }
                flib_table.insert(buttons, def)
            end

            if is_spoilage_recipe then
                -- Spoilage virtual recipes use a clock sprite in place of a
                -- real machine: there is no entity that performs spoilage,
                -- so the clock conveys "time-driven decay" while still
                -- filling the machine cell so the row visually lines up
                -- with the rest of the table. Same click target as the
                -- substrate button above for consistency.
                local def = {
                    type = "sprite-button",
                    style = "flib_slot_button_default",
                    sprite = "utility/clock",
                    tags = recipe_tags,
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_recipe_click,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local def = {
                type = "table",
                column_count = 4,
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            -- Mirror pre_solve.to_normalized_production_lines: split each
            -- product into the per-quality cascade the LP actually sees, so the
            -- UI reflects what the solver is solving. Decomposition is output-
            -- only — ingredients/fuel below stay single-quality.
            local unlocked = bonuses and bonuses.unlocked_qualities or nil
            for _, product in ipairs(n.products) do
                for _, amount in ipairs(pre_solve.quality_decomposition(product, effectivity.quality, unlocked)) do
                    local typed_name = tn.create_typed_name(
                        amount.type, amount.name, amount.quality,
                        amount.minimum_temperature, amount.maximum_temperature)
                    local craft = tn.typed_name_to_material(typed_name)
                    local is_hidden = acc.is_hidden(craft)
                    local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

                    local def = common.create_decorated_sprite_button {
                        typed_name = typed_name,
                        is_hidden = is_hidden,
                        is_unresearched = is_unresearched,
                                tags = {
                            line_index = line_index,
                            typed_name = typed_name,
                            is_product = true,
                            result_typed_name = line.recipe_typed_name,
                            raw_amount = amount.amount_per_second,
                        },
                        handler = {
                            [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                            on_added = handlers.update_amount,
                            on_amount_unit_changed = handlers.update_amount,
                            on_calculation_changed = handlers.update_amount,
                        },
                    }
                    flib_table.insert(buttons, def)
                end
            end

            -- Spent fuel (burnt_result) is a produced item, so it shares the
            -- Products column with recipe outputs. Unlike recipe products it is
            -- NOT quality-decomposed: the spent cell is a deterministic 1:1
            -- byproduct of the fuel burned, not a module-quality cascade (it
            -- lives in its own line field for exactly this reason).
            if n.fuel_burnt_result then
                local amount = n.fuel_burnt_result
                local typed_name = tn.create_typed_name("item", amount.name, amount.quality)
                local craft = tn.typed_name_to_material(typed_name)
                local is_hidden = acc.is_hidden(craft)
                local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                    tags = {
                        line_index = line_index,
                        typed_name = typed_name,
                        is_product = true,
                        result_typed_name = line.recipe_typed_name,
                        raw_amount = amount.amount_per_second,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local def = {
                type = "table",
                column_count = 4,
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local buttons = {}
            for _, amount in ipairs(n.ingredients) do
                local typed_name = tn.create_typed_name(
                    amount.type, amount.name, amount.quality,
                    amount.minimum_temperature, amount.maximum_temperature)
                local craft = tn.typed_name_to_material(typed_name)
                local is_hidden = acc.is_hidden(craft)
                local is_unresearched = acc.is_unresearched(craft, relation_to_recipes)

                local def = common.create_decorated_sprite_button {
                    typed_name = typed_name,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                        tags = {
                        line_index = line_index,
                        typed_name = typed_name,
                        is_product = false,
                        result_typed_name = line.recipe_typed_name,
                        raw_amount = amount.amount_per_second,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(buttons, def)
            end

            local def = {
                type = "table",
                column_count = 4,
                children = buttons,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local children = {}

            if not n.fuel_ingredient or acc.is_generator(machine) then
                local def = {
                    type = "label",
                    -- Rocket silos report a full-power figure: the launch
                    -- animation toggles full / no draw in phases we can't time
                    -- at runtime, so the real average is lower. Flag it right
                    -- on the power cell where the inflated number is shown.
                    tooltip = machine.type == "rocket-silo"
                        and { "factory-solver-rocket-silo-power-note" } or nil,
                    tags = {
                        result_typed_name = line.recipe_typed_name,
                        raw_amount = n.power_per_second,
                    },
                    handler = {
                        on_added = handlers.update_power,
                        on_amount_unit_changed = handlers.update_power,
                        on_calculation_changed = handlers.update_power,
                    },
                }
                flib_table.insert(children, def)
            end

            if n.fuel_ingredient then
                local ftn = assert(line.fuel_typed_name)
                local fuel = tn.typed_name_to_material(ftn)
                local is_hidden = acc.is_hidden(fuel)
                local is_unresearched = acc.is_unresearched(fuel, relation_to_recipes)

                local def = common.create_decorated_sprite_button {
                    typed_name = ftn,
                    is_hidden = is_hidden,
                    is_unresearched = is_unresearched,
                        tags = {
                        line_index = line_index,
                        typed_name = ftn,
                        is_product = false,
                        result_typed_name = line.recipe_typed_name,
                        raw_amount = n.fuel_ingredient.amount_per_second,
                    },
                    handler = {
                        [defines.events.on_gui_click] = handlers.on_production_line_inout_click,
                        on_added = handlers.update_amount,
                        on_amount_unit_changed = handlers.update_amount,
                        on_calculation_changed = handlers.update_amount,
                    },
                }
                flib_table.insert(children, def)
            end

            local def = {
                type = "flow",
                style = "factory_solver_centering_horizontal_flow",
                children = children,
            }
            fs_util.add_gui(elem, def)
        end

        do
            local pollution = n.pollution_per_second

            local def = {
                type = "label",
                tags = {
                    result_typed_name = line.recipe_typed_name,
                    raw_amount = pollution,
                },
                handler = {
                    on_added = handlers.update_pollution,
                    on_amount_unit_changed = handlers.update_pollution,
                    on_calculation_changed = handlers.update_pollution,
                },
            }
            fs_util.add_gui(elem, def)
        end

        do
            local def = {
                type = "sprite-button",
                style = "mini_tool_button_red",
                sprite = "utility/close",
                hovered_sprite = "utility/close_black",
                clicked_sprite = "utility/close_black",
                tags = {
                    line_index = line_index,
                },
                handler = {
                    [defines.events.on_gui_click] = handlers.on_remove_production_line
                },
            }
            fs_util.add_gui(elem, def)
        end
    end
end

---@param event EventDataTrait
function handlers.update_machines_required(event)
    local elem = event.element
    local tags = elem.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_typed_name = tags.result_typed_name --[[@as TypedName]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_typed_name)
    elem.caption = flib_format.number(quantity_of_machines_required, true, 5)
    elem.style.font_color = is_line_inactive(solution, result_typed_name)
        and inactive_font_color or active_font_color
end

---@param event EventDataTrait
function handlers.update_amount(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_typed_name = tags.result_typed_name --[[@as TypedName]]
    local typed_name = tags.typed_name --[[@as TypedName]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_typed_name)
    -- Pre-round to the material kind's display grid (nf.round_for_kind) so the
    -- slot's engine number formatting -- which SI-abbreviates and FLOORS -- is
    -- a no-op: a true 60 solved to 59.9999996 lands on 60, not "59.9". An
    -- inactive line solves to 0, which round_for_kind keeps a clean 0.
    elem.number = nf.round_for_kind(
        fs_util.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required,
        nf.kind_for_material(typed_name))
end

---@param event EventDataTrait
function handlers.update_power(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_typed_name = tags.result_typed_name --[[@as TypedName]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_typed_name)
    local amount = fs_util.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required
    elem.caption = common.format_power(amount)
    elem.style.font_color = is_line_inactive(solution, result_typed_name)
        and inactive_font_color or active_font_color
end

---@param event EventDataTrait
function handlers.update_pollution(event)
    local elem = event.element
    local tags = elem.tags
    local player_data = save.get_player_data(event.player_index)
    local solution = assert(save.get_selected_solution(event.player_index))

    local result_typed_name = tags.result_typed_name --[[@as TypedName]]
    local raw_amount = tags.raw_amount --[[@as number]]
    local quantity_of_machines_required = save.get_quantity_of_machines_required(solution, result_typed_name)
    local amount = fs_util.to_scale(raw_amount, player_data.time_scale) * quantity_of_machines_required
    elem.caption = flib_format.number(amount, true, 5)
    elem.style.font_color = is_line_inactive(solution, result_typed_name)
        and inactive_font_color or active_font_color
end

---@param event EventData.on_gui_click
function handlers.on_production_line_recipe_click(event)
    -- Shift+Click is the Factorio copy/paste vocabulary (Shift+Right=copy,
    -- Shift+Left=paste) and we route those before anything else — including
    -- the Factoriopedia / open-dialog / add-constraint paths — so the
    -- modifier is unambiguous. Buttons that carry a paste_target tag
    -- (machine / substrate / aggregated module icons) dispatch to the
    -- copy/paste handler; the recipe and clock icons land on the
    -- disabled-feedback path so Shift+Click doesn't silently fall through
    -- to "open dialog" / "add constraint", which feels misleading on an
    -- icon that visually resembles the copy/paste-capable ones.
    if event.shift then
        if event.element.tags.paste_target then
            handlers.on_clipboard_shift_click(event)
        else
            handlers.on_clipboard_disabled_click(event)
        end
        return
    end

    -- Alt+Right has no defined meaning here (Alt+Left is Factoriopedia),
    -- but the normal right-click branch below would otherwise add a
    -- constraint — surprising when the user clearly held a modifier to
    -- signal a different intent. The engine's press-down click sound has
    -- already fired by the time this handler runs; layering cannot_build
    -- on top distinguishes the rejection from a regular click.
    if event.alt and event.button == defines.mouse_button_type.right then return end

    -- Factoriopedia and the normal left/right branches rely on the engine's
    -- press-down `left_click_sound` for click feedback — no handler-side
    -- play_sound is needed here. Only the shift/alt rejection paths layer
    -- their own sound on top of the engine click.
    if common.try_open_factoriopedia(event) then return end

    local tags = event.element.tags
    if event.button == defines.mouse_button_type.left then
        if tags.is_recipe_icon and script.feature_flags.quality then
            local recipe_typed_name = tags.recipe_typed_name --[[@as TypedName]]
            common.open_gui(event.player_index, true, quality_variants_adder, {
                line_index = tags.line_index,
                recipe_typed_name = recipe_typed_name,
                source_quality = recipe_typed_name.quality,
            })
        else
            common.open_gui(event.player_index, true, machine_setup, tags)
        end
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))

        local typed_name = tags.recipe_typed_name --[[@as TypedName]]
        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---Feedback path for Shift+Click on a sprite-button that doesn't participate
---in the copy/paste flow (recipe / clock / products / ingredients / fuel).
---The icons share the slot-button look with the copy/paste-capable ones,
---so silently falling through to "open dialog" / "add constraint" reads as
---a bug. This handler matches the cannot-build audio cue and surfaces a
---short flying text so the user understands the action was intentionally
---rejected, not just ignored.
---@param event EventData.on_gui_click
function handlers.on_clipboard_disabled_click(event)
    local player = game.players[event.player_index]
    player.create_local_flying_text {
        text = { "factory-solver-clipboard-not-applicable" },
        create_at_cursor = true,
    }
    player.play_sound { path = "utility/cannot_build" }
end

---Shift+Right copies machine settings off the clicked button's row, with
---the mode pinned by which icon was clicked (machine/substrate → machine
---and fuel; module → modules and beacons). Shift+Left pastes the previously
---copied clipboard onto the clicked row, applying only the subset the
---clipboard's mode designates. Click target at paste time does *not*
---influence the applied subset — the clipboard remembers what was copied.
---Feedback runs through create_local_flying_text (Factorio 2.0 replacement
---for the removed flying-text entity); the call is per-player local and
---safe to invoke unconditionally on every client.
---@param event EventData.on_gui_click
function handlers.on_clipboard_shift_click(event)
    local tags = event.element.tags
    local line_index = tags.line_index --[[@as integer]]
    local paste_target = tags.paste_target --[[@as "machine_fuel"|"module_beacon"]]
    local solution = assert(save.get_selected_solution(event.player_index))
    local line = solution.production_lines[line_index]
    if not line then return end
    local player = game.players[event.player_index]

    if event.button == defines.mouse_button_type.right then
        save.set_machine_clipboard(event.player_index, line, paste_target)
        local message_key = paste_target == "machine_fuel"
            and "factory-solver-clipboard-copied-machine-fuel"
            or "factory-solver-clipboard-copied-module-beacon"
        player.create_local_flying_text {
            text = { message_key },
            create_at_cursor = true,
        }
        -- Mirror vanilla's audio feedback so copy/paste in factory_solver
        -- feels consistent with the engine's own entity-settings clipboard.
        player.play_sound { path = "utility/entity_settings_copied" }
    elseif event.button == defines.mouse_button_type.left then
        local result = save.apply_machine_clipboard(event.player_index, solution, line_index)
        local message_key
        if result == "ok" then
            local clipboard = assert(save.get_machine_clipboard(event.player_index))
            message_key = clipboard.mode == "machine_fuel"
                and "factory-solver-clipboard-pasted-machine-fuel"
                or "factory-solver-clipboard-pasted-module-beacon"
        elseif result == "empty" then
            message_key = "factory-solver-clipboard-empty"
        elseif result == "incompatible_machine" then
            message_key = "factory-solver-clipboard-incompatible-machine"
        elseif result == "no_module_or_beacon_slot" then
            message_key = "factory-solver-clipboard-no-module-or-beacon-slot"
        else
            message_key = "factory-solver-clipboard-empty"
        end
        player.create_local_flying_text {
            text = { message_key },
            create_at_cursor = true,
        }
        player.play_sound {
            path = result == "ok"
                and "utility/entity_settings_pasted"
                or "utility/cannot_build",
        }
        if result == "ok" then
            local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
            fs_util.dispatch_to_subtree(root, "on_production_line_changed")
        end
    end
end

---@param event EventData.on_gui_click
function handlers.on_production_line_inout_click(event)
    -- Same disabled-feedback gate as on_production_line_recipe_click:
    -- product / ingredient / fuel icons sit in the row alongside the
    -- copy/paste-eligible icons and look indistinguishable from them,
    -- so Shift+Click intercepts here too and emits the "not applicable"
    -- feedback instead of falling through to open production_line_adder
    -- or add a constraint.
    if event.shift then
        handlers.on_clipboard_disabled_click(event)
        return
    end

    -- See on_production_line_recipe_click: Alt+Right has no defined action
    -- here either, so reject it audibly instead of falling through to the
    -- right-click branch and adding a constraint.
    if event.alt and event.button == defines.mouse_button_type.right then return end

    if common.try_open_factoriopedia(event) then return end

    local tags = event.element.tags
    local typed_name = tags.typed_name --[[@as TypedName]]
    local is_product = tags.is_product --[[@as boolean]]

    local line_index = tags.line_index --[[@as integer]]
    if not is_product then
        line_index = line_index + 1
    end

    if event.button == defines.mouse_button_type.left then
        local data = {
            typed_name = typed_name,
            is_choose_product = not is_product,
            is_choose_ingredient = is_product,
            line_index = line_index,
        }
        common.open_gui(event.player_index, true, production_line_adder, data)
    elseif event.button == defines.mouse_button_type.right then
        local solution = assert(save.get_selected_solution(event.player_index))

        save.new_constraint(solution, typed_name)

        local root = assert(common.find_root_element(event.player_index, "factory_solver_main_window"))
        fs_util.dispatch_to_subtree(root, "on_constraint_changed", data)
    end
end

---@param event EventData.on_gui_click
function handlers.on_move_production_line_click(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))
    local from_line_index = tags.line_index --[[@as integer]]
    local direction = tags.direction

    if direction == "up" then
        local to_line_index
        if event.shift then
            to_line_index = 1
        elseif event.control then
            to_line_index = from_line_index - 5
        else
            to_line_index = from_line_index - 1
        end

        save.move_production_line(solution, from_line_index, to_line_index)
    elseif direction == "down" then
        local line_index2
        if event.shift then
            line_index2 = #solution.production_lines
        elseif event.control then
            line_index2 = from_line_index + 5
        else
            line_index2 = from_line_index + 1
        end

        save.move_production_line(solution, from_line_index, line_index2)
    end

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

---@param event EventData.on_gui_click
function handlers.on_remove_production_line(event)
    local tags = event.element.tags
    local solution = assert(save.get_selected_solution(event.player_index))

    save.delete_production_line(solution, tags.line_index --[[@as integer]])

    local root = assert(fs_util.find_upper(event.element, "factory_solver_main_window"))
    fs_util.dispatch_to_subtree(root, "on_production_line_changed")
end

fs_util.add_handlers(handlers)

---@type fs.GuiElemDef
return {
    type = "frame",
    name = "solution_editor",
    style = "inside_deep_frame",
    direction = "vertical",
    {
        type = "scroll-pane",
        style = "factory_solver_solution_editor_scroll_pane",
        {
            type = "table",
            style = "factory_solver_production_line_table",
            column_count = 9,
            handler = {
                on_added = handlers.make_production_line_table,
                on_selected_solution_changed = handlers.make_production_line_table,
                on_production_line_changed = handlers.make_production_line_table,
            },
        }
    },
}
