local acc = require "manage/accessor"
local preset = require "manage/preset"

local M = {}

-- Fixed FP schema version advertised on every export. Pinning this (rather
-- than reading script.active_mods["factoryplanner"]) keeps our output stable
-- if FP later changes its on-disk shape — FP's own migrator will translate
-- this baseline forward, but a freshly-bumped version we never validated
-- against could silently drift our payload.
local FP_EXPORT_VERSION = "2.0.45"

---@class FPPackedPrototype
---@field name string
---@field category string?
---@field data_type string?
---@field simplified boolean?

---Decode-side: lift `proto.name` if present, otherwise treat the value itself
---as a name string (defensive — FP sometimes serializes minimal shapes).
---@param p any
---@return string?
local function proto_name(p)
    if type(p) == "table" then return p.name end
    if type(p) == "string" then return p end
    return nil
end

---@param p any
---@return string
local function quality_name(p)
    return proto_name(p) or "normal"
end

---Build an FPPackedPrototype for export. simplified=true marks the proto
---as a string-only reference; on the other side FP's validate_prototype_object
---calls prototyper.util.find(data_type, name, category) to resolve the
---actual prototype. data_type MUST be one of FP's DataType plurals
---("recipes" / "items" / "machines" / "fuels" / "modules" / "beacons" /
---"belts" / "pumps" / "wagons" / "locations" / "qualities") — that's the
---key into storage.prototypes[data_type]. We leave category=nil so the
---name-only lookup branch in find() does the work (xor(category, name)
---is true → relevant_map[name]).
---@param name string
---@param data_type "recipes"|"items"|"machines"|"fuels"|"modules"|"beacons"|"qualities"
---@return FPPackedPrototype
local function pack_proto(name, data_type)
    return { name = name, category = nil, data_type = data_type, simplified = true }
end

---@param name string
---@return FPPackedPrototype
local function pack_quality(name)
    return { name = name, category = nil, data_type = "qualities", simplified = true }
end

---Resolve the fuel `type` (item vs fluid) from an FP packed Fuel. Prefer
---the explicit `data_type`; fall back to a prototype lookup. Returns "item"
---if unresolved so the TypedName still has a valid FilterType (the
---prototype check downstream will catch genuinely missing fuels).
---@param fuel_proto any
---@return "item"|"fluid"
local function fuel_filter_type(fuel_proto)
    if type(fuel_proto) == "table" then
        if fuel_proto.data_type == "fluid" then return "fluid" end
        if fuel_proto.data_type == "item" then return "item" end
        local n = fuel_proto.name
        if n then
            if prototypes.fluid[n] then return "fluid" end
            if prototypes.item[n] then return "item" end
        end
    end
    return "item"
end

---Expand an FP PackedModuleSet (`{ class="ModuleSet", modules=[...] }`)
---into factory_solver's slot-keyed table. Each Module contributes `amount`
---consecutive slots so a {prod3 x2, speed3 x2} ModuleSet becomes
---{"1"=prod3, "2"=prod3, "3"=speed3, "4"=speed3}.
---@param module_set any
---@return table<string, TypedName>
local function unpack_module_set(module_set)
    local out = {}
    if type(module_set) ~= "table" or type(module_set.modules) ~= "table" then
        return out
    end
    local slot = 1
    for _, m in ipairs(module_set.modules) do
        local name = proto_name(m.proto)
        local quality = quality_name(m.quality_proto)
        local amount = tonumber(m.amount) or 0
        if name then
            for _ = 1, amount do
                out[tostring(slot)] = { type = "item", name = name, quality = quality }
                slot = slot + 1
            end
        end
    end
    return out
end

---Inverse of unpack_module_set: collapse slot assignments into FP's
---PackedModuleSet shape (`{ class="ModuleSet", modules=[...] }`), grouping
---consecutive identical (name, quality) entries by amount. Slot order is
---preserved by iterating numeric keys in ascending order.
---@param module_typed_names table<string, TypedName>
---@return table
local function pack_module_set(module_typed_names)
    local slots = {}
    for k, v in pairs(module_typed_names) do
        local idx = tonumber(k)
        if idx and v and v.name then
            slots[#slots + 1] = { idx = idx, name = v.name, quality = v.quality or "normal" }
        end
    end
    table.sort(slots, function(a, b) return a.idx < b.idx end)

    ---@type table[]
    local modules = {}
    for _, s in ipairs(slots) do
        local last = modules[#modules]
        if last and last.proto.name == s.name and last.quality_proto.name == s.quality then
            last.amount = last.amount + 1
        else
            modules[#modules + 1] = {
                class = "Module",
                proto = pack_proto(s.name, "modules"),
                quality_proto = pack_quality(s.quality),
                amount = 1,
            }
        end
    end
    return { class = "ModuleSet", modules = modules }
end

---Recursively flatten a Floor's lines[] into a flat list of PackedLine
---tables (`class="Line"`). PackedFloor nodes don't carry recipe/machine
---themselves — their defining line already lives at `lines[1]` after FP
---moves the original Line into the subfloor. So a plain DFS collecting
---class=="Line" leaves the right set of recipes with no duplicate.
---@param lines any
---@param out table[]
---@param flatten_seen { [any]: any }? Sentinel table; `.nested` is set true
---when at least one Floor child is recursed into, so the caller can warn
---that the user's subfloor structure was flattened on import.
local function collect_leaf_lines(lines, out, flatten_seen)
    if type(lines) ~= "table" then return end
    for _, node in ipairs(lines) do
        if type(node) == "table" then
            if node.class == "Floor" then
                if flatten_seen then flatten_seen.nested = true end
                collect_leaf_lines(node.lines, out, flatten_seen)
            elseif node.class == "Line" or node.recipe then
                out[#out + 1] = node
            end
        end
    end
end

---Pick a deterministic rocket-part recipe for a rocket-silo. FP's
---impostor-launch / impostor-{silo}-rocket recipes drop the rocket_part
---identifier, so reverse mapping needs to reconstruct one. We mirror FP's
---own filtering in generator.lua: prefer `fixed_recipe`, otherwise the first
---recipe sharing one of the silo's `crafting_categories`. Sorted by name so
---two clients running this on the same prototype set agree.
---@param silo_proto LuaEntityPrototype?
---@return string?
local function best_effort_rocket_part(silo_proto)
    if not silo_proto then return nil end
    if silo_proto.fixed_recipe then return silo_proto.fixed_recipe end
    local cats = silo_proto.crafting_categories
    if not cats then return nil end
    local filters = {}
    for cat, _ in pairs(cats) do
        filters[#filters + 1] = { filter = "category", category = cat }
    end
    if #filters == 0 then return nil end
    local recipes = prototypes.get_recipe_filtered(filters)
    local sorted = {}
    for name, _ in pairs(recipes) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    return sorted[1]
end

---@param plant_name string
---@return string?
local function best_effort_seed_for_plant(plant_name)
    local seeds = prototypes.get_item_filtered({
        { filter = "plant-result", elem_filters = { { filter = "name", name = plant_name } } },
    })
    local sorted = {}
    for name, _ in pairs(seeds) do sorted[#sorted + 1] = name end
    table.sort(sorted)
    return sorted[1]
end

---Replicate FP's generator_util.get_boiler_data category synthesis so the
---string we emit matches what FP itself would have generated. Without this
---FP rejects the impostor recipe at validate_prototype_object time and the
---whole imported factory ends up invalid.
---@param boiler_proto LuaEntityPrototype?
---@return string?
local function derive_fp_boiler_category(boiler_proto)
    if not boiler_proto or boiler_proto.type ~= "boiler" then return nil end
    local input, output = nil, nil
    for _, fluid_box in pairs(boiler_proto.fluidbox_prototypes) do
        if fluid_box.production_type == "input-output" or fluid_box.production_type == "input" then
            input = fluid_box
        elseif fluid_box.production_type == "output" then
            output = fluid_box
        end
    end
    if not input then return nil end

    local category = "boiler"
    if boiler_proto.boiler_mode == "output-to-separate-pipe" then
        category = category .. "-target-" .. boiler_proto.target_temperature
    end
    if output and output.filter then
        category = category .. "-output-" .. output.filter.name
    end
    if input.filter then
        category = category .. "-filter-" .. input.filter.name
    end
    return category
end

---Map a factory_solver virtual recipe name to its FP impostor- equivalent.
---Returns nil if no FP equivalent exists (caller drops the line + warning).
---machine_name is currently unused but kept symmetric with the reverse
---direction so future variants that need it have a place to plug in.
---@param fs_name string
---@param machine_name string?
---@return string?
local function fs_virtual_to_fp_name(fs_name, machine_name)
    local s = fs_name:match("^<spoil>(.+)$")
    if s then return "impostor-spoiling-" .. s end

    s = fs_name:match("^<mine>(.+)$")
    if s then return "impostor-" .. s end

    s = fs_name:match("^<grow>([^:]+):")
    if s then return "impostor-" .. s end

    s = fs_name:match("^<pump>(.+)$")
    if s then
        local tile = prototypes.tile[s]
        if tile and tile.fluid then
            return "impostor-" .. tile.fluid.name .. "-" .. s
        end
        return nil
    end

    s = fs_name:match("^<run>(.+)$")
    if s then
        -- rocket-silo three-part: <run>{S}:{R}:{I} (cargo) or <run>{S}:{R}:space-age (platform)
        local silo, _part, third = s:match("^([^:]+):([^:]+):(.+)$")
        if silo and third then
            local silo_proto = prototypes.entity[silo]
            if silo_proto and silo_proto.type == "rocket-silo" then
                if third == "space-age" then
                    return "impostor-" .. silo .. "-rocket"
                end
                return "impostor-launch-" .. third .. "-from-" .. silo
            end
            return nil
        end
        -- boiler two-part: <run>{B}:{Fluid}
        local boiler, fluid = s:match("^([^:]+):([^:]+)$")
        if boiler and fluid then
            local boiler_proto = prototypes.entity[boiler]
            if boiler_proto and boiler_proto.type == "boiler" then
                local cat = derive_fp_boiler_category(boiler_proto)
                if cat then return "impostor-" .. cat .. "-fluid-" .. fluid end
            end
            return nil
        end
        -- single-token <run>{entity} — generator/burner-generator/reactor/
        -- fusion-*/thruster: no FP line concept, drop + warning.
        return nil
    end

    -- <research>X / <launch>X / unknown prefix: no FP equivalent
    return nil
end

---Map an FP impostor- recipe name back to a factory_solver virtual recipe
---name. machine_name is consulted for boiler reverse mapping: FP encodes
---boiler category (not entity) in the recipe name but the actual entity
---lives on Line.machine, so the machine name is the cleanest source of
---truth for recovering FS's entity-grained naming.
---@param fp_name string
---@param machine_name string?
---@return string?
local function fp_name_to_fs_virtual(fp_name, machine_name)
    local body = fp_name:match("^impostor%-(.+)$")
    if not body then return nil end

    -- impostor-spoiling-X → <spoil>X
    local s = body:match("^spoiling%-(.+)$")
    if s then return "<spoil>" .. s end

    -- impostor-launch-{I}-from-{S} → <run>S:R:I
    local item, silo = body:match("^launch%-(.+)%-from%-(.+)$")
    if item and silo then
        local silo_proto = prototypes.entity[silo]
        if silo_proto and silo_proto.type == "rocket-silo" then
            local part = best_effort_rocket_part(silo_proto)
            if part then
                return "<run>" .. silo .. ":" .. part .. ":" .. item
            end
        end
        return nil
    end

    -- impostor-{S}-rocket → <run>S:R:space-age — only if S resolves to a silo,
    -- otherwise fall through (a resource happening to end in "-rocket" should
    -- still take the mining branch).
    local silo_only = body:match("^(.+)%-rocket$")
    if silo_only then
        local silo_proto = prototypes.entity[silo_only]
        if silo_proto and silo_proto.type == "rocket-silo" then
            local part = best_effort_rocket_part(silo_proto)
            if part then
                return "<run>" .. silo_only .. ":" .. part .. ":space-age"
            end
        end
    end

    -- impostor-{cat}-fluid-{Fluid} → <run>{machine}:{Fluid}
    -- FP's derive_fp_boiler_category never embeds "-fluid-" inside the
    -- category portion (the separator is unique), so greedy "%.+%-fluid%-"
    -- isolates the trailing fluid name even when the category itself
    -- contains hyphens (e.g. boiler-output-steam-filter-water-fluid-water).
    if body:find("%-fluid%-") then
        local fluid = body:match("^.+%-fluid%-(.+)$")
        if fluid and machine_name then
            local mp = prototypes.entity[machine_name]
            if mp and mp.type == "boiler" then
                return "<run>" .. machine_name .. ":" .. fluid
            end
        end
        return nil
    end

    -- impostor-{F}-{T} (offshore pump from a tile) — enumerate tiles whose
    -- fluid name concatenated with the tile name reproduces the body. We
    -- avoid string splitting because both fluid and tile names may contain
    -- hyphens (e.g. crude-oil), making naive splits ambiguous.
    for tile_name, tile_proto in pairs(prototypes.tile) do
        if tile_proto.fluid then
            local candidate = tile_proto.fluid.name .. "-" .. tile_name
            if body == candidate then
                return "<pump>" .. tile_name
            end
        end
    end

    -- impostor-X (mining or planting) — disambiguate by entity type.
    local proto = prototypes.entity[body]
    if proto then
        if proto.type == "resource" then
            return "<mine>" .. body
        elseif proto.type == "plant" then
            local seed = best_effort_seed_for_plant(body)
            if seed then return "<grow>" .. body .. ":" .. seed end
        end
    end

    return nil
end

---For FS→FP export, substitute the machine name for virtual recipes whose
---FS-side machine identity is not what FP would have generated:
---  * `<spoil>X`: FS uses the sentinel "entity-unknown" because spoilage
---    has no real machine in the engine; FP pins it to the biggest
---    container ([generator.lua:890-905] picks max chest inventory).
---  * `<grow>P:S`: FS uses the plant entity itself as the "machine" because
---    the plant is what occupies one slot; FP uses the agricultural-tower
---    that processes the slot ([generator.lua:882-888]).
---Other virtual recipes already use the same machine entity FP would
---(boiler/mining drill/offshore pump/silo), so they pass through unchanged.
---@param fs_recipe_name string
---@param fs_machine_name string
---@return string
local function substitute_machine_for_fp(fs_recipe_name, fs_machine_name)
    if fs_recipe_name:sub(1, 7) == "<spoil>" then
        local biggest, biggest_size = nil, -1
        for _, proto in pairs(prototypes.entity) do
            if proto.type == "container" then
                local size = proto.get_inventory_size(defines.inventory.chest) or 0
                if size > biggest_size then
                    biggest, biggest_size = proto.name, size
                end
            end
        end
        if biggest then return biggest end
    elseif fs_recipe_name:sub(1, 6) == "<grow>" then
        local sorted = {}
        for _, proto in pairs(prototypes.entity) do
            if proto.type == "agricultural-tower" then
                sorted[#sorted + 1] = proto.name
            end
        end
        table.sort(sorted)
        if sorted[1] then return sorted[1] end
    end
    return fs_machine_name
end

---For FP→FS import, restore the machine identity FS's pre_solve expects:
---spoilage uses the "entity-unknown" sentinel, plant uses the plant entity
---(parsed back out of the `<grow>{plant}:{seed}` recipe name). Without
---this restoration, a re-imported factory carries the FP machine name
---through and breaks pre_solve assumptions like is_spoilage detection or
---the plant slot count.
---@param fs_recipe_name string
---@param fp_machine_name string
---@return string
local function substitute_machine_for_fs(fs_recipe_name, fp_machine_name)
    if fs_recipe_name:sub(1, 7) == "<spoil>" then
        return "entity-unknown"
    end
    local plant = fs_recipe_name:match("^<grow>([^:]+):")
    if plant then return plant end
    return fp_machine_name
end

---@param packed_line any
---@param machine_typed_name TypedName?
---@return { type: "recipe"|"virtual_recipe", name: string, quality: string }?
local function unpack_recipe_typed_name(packed_line, machine_typed_name)
    local name = proto_name(packed_line.recipe and packed_line.recipe.proto)
    if not name then return nil end
    if name:sub(1, 9) == "impostor-" then
        local fs_name = fp_name_to_fs_virtual(name,
            machine_typed_name and machine_typed_name.name)
        if not fs_name then return nil end
        return { type = "virtual_recipe", name = fs_name, quality = "normal" }
    end
    return { type = "recipe", name = name, quality = "normal" }
end

---@param packed_line any
---@return TypedName?
local function unpack_machine_typed_name(packed_line)
    local m = packed_line.machine
    if type(m) ~= "table" then return nil end
    local name = proto_name(m.proto)
    if not name then return nil end
    return { type = "machine", name = name, quality = quality_name(m.quality_proto) }
end

---@param packed_line any
---@return TypedName?
local function unpack_fuel_typed_name(packed_line)
    local m = packed_line.machine
    if type(m) ~= "table" or type(m.fuel) ~= "table" then return nil end
    local name = proto_name(m.fuel.proto)
    if not name then return nil end
    return {
        type = fuel_filter_type(m.fuel.proto),
        name = name,
        quality = quality_name(m.fuel.quality_proto),
    }
end

---@param packed_line any
---@return AffectedByBeacon[]
local function unpack_beacons(packed_line)
    local b = packed_line.beacon
    if type(b) ~= "table" then return {} end
    local name = proto_name(b.proto)
    if not name then return {} end
    return { {
        beacon_typed_name = {
            type = "machine",
            name = name,
            quality = quality_name(b.quality_proto),
        },
        beacon_quantity = tonumber(b.amount) or 0,
        module_typed_names = unpack_module_set(b.module_set),
    } }
end

---Convert FP's Machine.limit / force_limit into a recipe constraint on the
---Solution. Returns nil when no limit was set. factory_solver's recipe LP
---variable is already scaled so a value of N corresponds to N machines at
---the line's effective speed (accessor.normalize_production_line folds
---crafting_speed and crafting_energy into the per-craft amounts), so FP's
---raw machine count maps to limit_amount_per_second 1:1 without needing
---to multiply by crafting_speed.
---@param packed_line any
---@param recipe_name string
---@param recipe_type "recipe"|"virtual_recipe"
---@return Constraint?
local function unpack_machine_limit_constraint(packed_line, recipe_name, recipe_type)
    local m = packed_line.machine
    if type(m) ~= "table" then return nil end
    local limit = tonumber(m.limit)
    if not limit then return nil end

    return {
        type = recipe_type,
        name = recipe_name,
        quality = "normal",
        limit_type = m.force_limit and "equal" or "upper",
        limit_amount_per_second = limit,
    }
end

---@param product any
---@return Constraint?
local function unpack_product_constraint(product)
    if type(product) ~= "table" then return nil end
    local proto = product.proto
    if type(proto) ~= "table" then return nil end
    local name = proto.name
    if not name then return nil end

    local data_type = proto.data_type
    if data_type ~= "item" and data_type ~= "fluid" then
        if prototypes.fluid[name] then
            data_type = "fluid"
        else
            data_type = "item"
        end
    end

    local amount = tonumber(product.required_amount) or 0
    local defined_by = product.defined_by
    if defined_by == "belts" or defined_by == "lanes" then
        local throughput = nil
        if type(product.belt_proto) == "table" then
            local belt = prototypes.entity[product.belt_proto.name or ""]
            if belt and belt.belt_speed then
                throughput = belt.belt_speed * 480
            end
        end
        if throughput then
            amount = amount * throughput * (defined_by == "lanes" and 0.5 or 1.0)
        end
    end

    return {
        type = data_type,
        name = name,
        quality = "normal",
        limit_type = "lower",
        limit_amount_per_second = amount,
    }
end

---Convert one FP PackedFactory into a factory_solver Solution payload (the
---same shape import_solution() expects: name/constraints/production_lines).
---Returns the payload plus a list of localised warning strings describing
---features we could not preserve. player_index is consulted to pick the
---user's preset fuel for fuel-using machines whose FP payload carries no
---fuel (FP doesn't serialize fuel for heat machines, and even burner lines
---can land here without one).
---@param packed_factory any
---@param player_index integer
---@return table, LocalisedString[]
function M.factory_to_payload(packed_factory, player_index)
    local warnings = {}
    local constraints = {}
    local production_lines = {}
    local seen_recipes = {}

    if type(packed_factory.products) == "table" then
        for _, product in ipairs(packed_factory.products) do
            local c = unpack_product_constraint(product)
            if c then constraints[#constraints + 1] = c end
        end
    end

    local leaf_lines = {}
    local flatten_seen = { nested = false }
    if type(packed_factory.top_floor) == "table" then
        collect_leaf_lines(packed_factory.top_floor.lines, leaf_lines, flatten_seen)
    end
    if flatten_seen.nested then
        warnings[#warnings + 1] = { "factory-solver-fp-import-warning-flattened-subfloors" }
    end

    -- Per-line FP fields that factory_solver has no equivalent for. They
    -- fire on every line that uses the feature so the per-recipe identity
    -- would drown out the truly per-line warnings (duplicate-recipe);
    -- aggregate to one counted line each, mirroring the Helmod codec.
    local aggregated_warning_counts = {}
    local function add_aggregated_warning(locale_key)
        aggregated_warning_counts[locale_key] =
            (aggregated_warning_counts[locale_key] or 0) + 1
    end

    for _, packed_line in ipairs(leaf_lines) do
        -- Unpack the machine first so the recipe unpacker can consult
        -- machine_typed_name when reversing FP impostor- recipes whose name
        -- alone is ambiguous (notably boilers, where FP encodes a category
        -- and the actual entity only survives on Line.machine).
        local machine_typed_name = unpack_machine_typed_name(packed_line)
        local recipe_typed_name = unpack_recipe_typed_name(packed_line, machine_typed_name)
        if recipe_typed_name and machine_typed_name then
            -- For virtual recipes whose FS machine identity diverges from
            -- FP's (spoilage sentinel; plant entity), rewrite the machine
            -- name to what FS's pre_solve expects. Boiler/mining/silo/pump
            -- already share machine identity with FP so they pass through.
            if recipe_typed_name.type == "virtual_recipe" then
                machine_typed_name.name = substitute_machine_for_fs(
                    recipe_typed_name.name, machine_typed_name.name)
            end
            if seen_recipes[recipe_typed_name.name] then
                warnings[#warnings + 1] = {
                    "factory-solver-fp-import-warning-duplicate-recipe",
                    recipe_typed_name.name,
                }
            else
                seen_recipes[recipe_typed_name.name] = true
                -- FP per-line scalars that have no FS equivalent. percentage
                -- and active are load-bearing on FP's side (a 50% line emits
                -- half the products, a deactivated line emits none); FS
                -- always solves at the recipe's natural rate. priority_-
                -- product steers multi-product recipes — FS lets the LP
                -- balance byproducts instead of pinning a main output.
                local pct = tonumber(packed_line.percentage)
                if pct and pct ~= 100 then
                    add_aggregated_warning(
                        "factory-solver-fp-import-warning-percentage")
                end
                if packed_line.active == false then
                    add_aggregated_warning(
                        "factory-solver-fp-import-warning-inactive-line")
                end
                if packed_line.recipe and packed_line.recipe.priority_product then
                    add_aggregated_warning(
                        "factory-solver-fp-import-warning-priority-product")
                end
                local m = packed_line.machine or {}
                local fuel_typed_name = unpack_fuel_typed_name(packed_line)
                -- accessor.normalize_production_line asserts that any
                -- fuel-using machine carries a fuel_typed_name. FP omits
                -- fuel for heat machines (heat-exchanger) and may export
                -- burner lines without one if FP itself never resolved a
                -- default. Backfill from the user's FS preset so the
                -- imported line round-trips cleanly through pre_solve.
                if not fuel_typed_name then
                    local machine_proto = prototypes.entity[machine_typed_name.name]
                    if machine_proto and acc.is_use_fuel(machine_proto) then
                        fuel_typed_name = preset.get_fuel_preset(
                            player_index, machine_typed_name)
                    end
                end
                production_lines[#production_lines + 1] = {
                    recipe_typed_name = recipe_typed_name,
                    machine_typed_name = machine_typed_name,
                    module_typed_names = unpack_module_set(m.module_set),
                    affected_by_beacons = unpack_beacons(packed_line),
                    fuel_typed_name = fuel_typed_name,
                }
                local limit_constraint = unpack_machine_limit_constraint(
                    packed_line, recipe_typed_name.name, recipe_typed_name.type)
                if limit_constraint then
                    constraints[#constraints + 1] = limit_constraint
                end
            end
        end
    end

    -- Flush aggregated counters into the warning list. Sort keys so the
    -- output is deterministic across loads.
    local sorted_keys = {}
    for key in pairs(aggregated_warning_counts) do
        sorted_keys[#sorted_keys + 1] = key
    end
    table.sort(sorted_keys)
    for _, key in ipairs(sorted_keys) do
        warnings[#warnings + 1] = { key, tostring(aggregated_warning_counts[key]) }
    end

    local name = packed_factory.name
    if type(name) ~= "string" or name == "" then
        name = "Imported factory"
    end

    return {
        name = name,
        constraints = constraints,
        production_lines = production_lines,
    }, warnings
end

---@param solution Solution
---@return table, LocalisedString[]
local function solution_to_packed_factory(solution)
    local warnings = {}
    local products = {}
    local recipe_constraints = {}

    for _, c in ipairs(solution.constraints) do
        if c.type == "item" or c.type == "fluid" then
            -- FP's Product.required_amount has produce-at-least semantics
            -- (FP's solver treats it as a lower target), so an FS upper or
            -- equal bound on an item / fluid silently changes meaning when
            -- exported. Warn so the user knows the bound direction was lost.
            if c.limit_type and c.limit_type ~= "lower" then
                warnings[#warnings + 1] = {
                    "factory-solver-fp-export-warning-upper-bound-product", c.name,
                }
            end
            -- FP has no fluid-temperature dimension on products, so any
            -- temperature constraint factory_solver carries is discarded.
            if c.minimum_temperature or c.maximum_temperature then
                warnings[#warnings + 1] = {
                    "factory-solver-fp-export-warning-constraint-temperature", c.name,
                }
            end
            -- Product uses category_designation="type", so the category field
            -- holds prototype.type ("item" or "fluid"). Without it,
            -- validate_prototype_object skips the lookup and the product stays
            -- as a simplified placeholder on FP's side.
            local proto = pack_proto(c.name, "items")
            proto.category = c.type
            products[#products + 1] = {
                class = "Product",
                proto = proto,
                defined_by = "amount",
                required_amount = c.limit_amount_per_second,
            }
        elseif c.type == "recipe" or c.type == "virtual_recipe" then
            -- Key by FS-side recipe name so virtual_recipe constraints
            -- (e.g. "<spoil>egg") match by the same key the line lookup
            -- uses below — see the recipe_constraints[recipe_tn.name] read.
            recipe_constraints[c.name] = c
            if c.limit_type == "lower" then
                warnings[#warnings + 1] = {
                    "factory-solver-fp-export-warning-recipe-lower-bound", c.name,
                }
            end
        else
            warnings[#warnings + 1] = {
                "factory-solver-fp-export-warning-unsupported-constraint",
                c.type, c.name,
            }
        end
    end

    local lines = {}
    for _, pl in ipairs(solution.production_lines) do
        local recipe_tn = pl.recipe_typed_name
        local machine = pl.machine_typed_name
        -- factory_solver wraps engine-side conversions (boiler heating, mining,
        -- lab research, thruster propulsion, ...) as virtual_recipe entries.
        -- FP has its own runtime-synthesized impostor- recipes for the
        -- physical-extraction subset (mining/pumping/planting/spoiling) plus
        -- boilers and rocket launches, so we map those by name. Power/heat/
        -- research virtual recipes have no FP line equivalent and still
        -- drop + warning.
        local recipe_name = nil
        if recipe_tn and recipe_tn.type == "recipe" then
            recipe_name = recipe_tn.name
        elseif recipe_tn and recipe_tn.type == "virtual_recipe" then
            local mapped = fs_virtual_to_fp_name(recipe_tn.name,
                machine and machine.name)
            if mapped then
                recipe_name = mapped
            else
                warnings[#warnings + 1] = {
                    "factory-solver-fp-export-warning-virtual-recipe", recipe_tn.name,
                }
            end
        elseif recipe_tn then
            warnings[#warnings + 1] = {
                "factory-solver-fp-export-warning-virtual-recipe", recipe_tn.name or "?",
            }
        end
        if recipe_name and machine then
            -- Lookup uses the FS-side name (recipe_tn.name) which equals
            -- recipe_name for real recipes and stays "<verb>..." for virtual
            -- ones — matches the key recipe_constraints was populated with.
            local limit_constraint = recipe_constraints[recipe_tn.name]
            local limit = nil
            local force_limit = false
            if limit_constraint and limit_constraint.limit_type ~= "lower" then
                limit = limit_constraint.limit_amount_per_second
                force_limit = (limit_constraint.limit_type == "equal")
            end

            -- Substitute FS-only machine identities (spoilage sentinel,
            -- plant entity) with FP's expected machine entity before packing
            -- so FP's Machine:validate finds the prototype in its bucket.
            local fp_machine_name = machine.name
            if recipe_tn and recipe_tn.type == "virtual_recipe" then
                fp_machine_name = substitute_machine_for_fp(recipe_tn.name, machine.name)
            end

            local machine_packed = {
                class = "Machine",
                proto = pack_proto(fp_machine_name, "machines"),
                quality_proto = pack_quality(machine.quality or "normal"),
                limit = limit,
                force_limit = force_limit,
                module_set = pack_module_set(pl.module_typed_names or {}),
            }
            -- Only attach fuel when the machine actually burns one. factory_solver
            -- carries fuel_typed_name from defaults/presets even on electric
            -- machines (chemical-plant, etc.); FP rejects fuel on a non-burner
            -- and marks the whole factory invalid. Filter at the prototype
            -- level so the exported shape stays consistent with FP's model.
            -- Pack fuel only for machines FP itself treats as fuel-using:
            -- solid burner (burner_prototype) or fluid-burning energy source
            -- (fluid_energy_source.burns_fluid). FS additionally calls heat
            -- energy "fuel-using" because pre_solve injects `<heat>` as a
            -- virtual_material fuel, but FP doesn't model heat as a Fuel
            -- prototype — sending `<heat>` would land on a missing-prototype
            -- lookup and fail Fuel:validate → machine.valid=false → repair.
            -- We also defensively require the FS fuel to be a real item/fluid.
            if pl.fuel_typed_name
                and (pl.fuel_typed_name.type == "item" or pl.fuel_typed_name.type == "fluid") then
                local machine_proto = prototypes.entity[machine.name]
                local fp_fuel_compatible = machine_proto and (
                    machine_proto.burner_prototype
                    or (machine_proto.fluid_energy_source_prototype
                        and machine_proto.fluid_energy_source_prototype.burns_fluid)
                )
                if fp_fuel_compatible then
                    -- FP's Fuel:validate calls validate_prototype_object with
                    -- category_designation="combined_category"; without a
                    -- category on the packed proto the find() call is skipped
                    -- and the fuel stays simplified → fuel.valid=false →
                    -- machine.valid=false → line marked "repair needed". So we
                    -- replicate FP's own pack: include the burner's combined
                    -- fuel-category (sorted keys joined by "|") as the category
                    -- field. acc.try_get_fuel_categories returns the burner's
                    -- fuel_categories set; acc.join_categories canonicalizes.
                    -- Fluid-burning machines (no burner_prototype, but
                    -- fluid_energy_source_prototype.burns_fluid) get
                    -- "fluid-fuel" — FP's gen registers them under that
                    -- single-key bucket (generator.lua:740).
                    local fuel_proto = pack_proto(pl.fuel_typed_name.name, "fuels")
                    local cats = acc.try_get_fuel_categories(machine_proto)
                    if cats then
                        fuel_proto.category = acc.join_categories(cats)
                    elseif machine_proto.fluid_energy_source_prototype
                        and machine_proto.fluid_energy_source_prototype.burns_fluid then
                        fuel_proto.category = "fluid-fuel"
                    end
                    machine_packed.fuel = {
                        class = "Fuel",
                        proto = fuel_proto,
                        quality_proto = pack_quality(pl.fuel_typed_name.quality or "normal"),
                    }
                end
            end

            local beacon_packed = nil
            local beacons = pl.affected_by_beacons or {}
            if beacons[1] and beacons[1].beacon_typed_name then
                local b = beacons[1]
                beacon_packed = {
                    class = "Beacon",
                    proto = pack_proto(b.beacon_typed_name.name, "beacons"),
                    quality_proto = pack_quality(b.beacon_typed_name.quality or "normal"),
                    amount = b.beacon_quantity,
                    total_amount = nil,
                    module_set = pack_module_set(b.module_typed_names or {}),
                }
                if #beacons > 1 then
                    warnings[#warnings + 1] = {
                        "factory-solver-fp-export-warning-multiple-beacons", recipe_name,
                    }
                end
            end

            lines[#lines + 1] = {
                class = "Line",
                recipe = {
                    class = "Recipe",
                    proto = pack_proto(recipe_name, "recipes"),
                    production_type = "produce",
                    priority_product = nil,
                    temperatures = {},
                },
                machine = machine_packed,
                beacon = beacon_packed,
                done = false,
                active = true,
                percentage = 100,
                comment = "",
            }
        end
    end

    local packed_factory = {
        class = "Factory",
        name = solution.name,
        matrix_solver_active = false,
        matrix_free_items = nil,
        blueprints = {},
        notes = "",
        productivity_boni = {},
        products = products,
        top_floor = {
            class = "Floor",
            level = 1,
            lines = lines,
        },
    }
    return packed_factory, warnings
end

---@param decoded any
---@return boolean
function M.is_factoryplanner_shape(decoded)
    return type(decoded) == "table"
        and type(decoded.export_modset) == "table"
        and type(decoded.factories) == "table"
end

---Decode an FP shared string. Returns (export_table, nil) on success, or
---(nil, localised_error). The caller is expected to have already tried
---factory_solver's native codec first and fallen through to this one.
---@param s string
---@return table?
---@return LocalisedString?
function M.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, { "factory-solver-import-error-prefix" }
    end
    local json = helpers.decode_string(s)
    if not json then
        return nil, { "factory-solver-import-error-prefix" }
    end
    local decoded = helpers.json_to_table(json)
    if not M.is_factoryplanner_shape(decoded) then
        return nil, { "factory-solver-import-error-prefix" }
    end
    return decoded, nil
end

---Encode a list of Solutions as an FP shared string. Each Solution maps to
---one FP Factory; the export_modset["factoryplanner"] value is pinned (see
---FP_EXPORT_VERSION above). Per-solution warnings are concatenated in input
---order so the caller can surface them to the player without grouping logic.
---@param solutions Solution[]
---@return string, LocalisedString[]
function M.encode(solutions)
    local factories = {}
    local warnings = {}
    for i, solution in ipairs(solutions) do
        local packed_factory, factory_warnings = solution_to_packed_factory(solution)
        factories[i] = packed_factory
        for _, w in ipairs(factory_warnings) do
            warnings[#warnings + 1] = w
        end
    end
    local export_table = {
        export_modset = { ["factoryplanner"] = FP_EXPORT_VERSION },
        factories = factories,
    }
    return assert(helpers.encode_string(helpers.table_to_json(export_table))), warnings
end

return M
