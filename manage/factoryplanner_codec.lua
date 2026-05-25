local acc = require "manage/accessor"

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
local function collect_leaf_lines(lines, out)
    if type(lines) ~= "table" then return end
    for _, node in ipairs(lines) do
        if type(node) == "table" then
            if node.class == "Floor" then
                collect_leaf_lines(node.lines, out)
            elseif node.class == "Line" or node.recipe then
                out[#out + 1] = node
            end
        end
    end
end

---@param packed_line any
---@return TypedName?
local function unpack_recipe_typed_name(packed_line)
    local name = proto_name(packed_line.recipe and packed_line.recipe.proto)
    if not name then return nil end
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
---@return Constraint?
local function unpack_machine_limit_constraint(packed_line, recipe_name)
    local m = packed_line.machine
    if type(m) ~= "table" then return nil end
    local limit = tonumber(m.limit)
    if not limit then return nil end

    return {
        type = "recipe",
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
---features we could not preserve.
---@param packed_factory any
---@return table, LocalisedString[]
function M.factory_to_payload(packed_factory)
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
    if type(packed_factory.top_floor) == "table" then
        collect_leaf_lines(packed_factory.top_floor.lines, leaf_lines)
    end

    for _, packed_line in ipairs(leaf_lines) do
        local recipe_typed_name = unpack_recipe_typed_name(packed_line)
        local machine_typed_name = unpack_machine_typed_name(packed_line)
        if recipe_typed_name and machine_typed_name then
            if seen_recipes[recipe_typed_name.name] then
                warnings[#warnings + 1] = {
                    "factory-solver-fp-import-warning-duplicate-recipe",
                    recipe_typed_name.name,
                }
            else
                seen_recipes[recipe_typed_name.name] = true
                local m = packed_line.machine or {}
                production_lines[#production_lines + 1] = {
                    recipe_typed_name = recipe_typed_name,
                    machine_typed_name = machine_typed_name,
                    module_typed_names = unpack_module_set(m.module_set),
                    affected_by_beacons = unpack_beacons(packed_line),
                    fuel_typed_name = unpack_fuel_typed_name(packed_line),
                }
                local limit_constraint = unpack_machine_limit_constraint(
                    packed_line, recipe_typed_name.name)
                if limit_constraint then
                    constraints[#constraints + 1] = limit_constraint
                end
            end
        end
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
        elseif c.type == "recipe" then
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
        -- FP has no notion of virtual recipes, so the line would resolve to a
        -- missing prototype and the entire factory ends up invalid. Drop the
        -- whole line with a warning instead.
        local is_real_recipe = recipe_tn and recipe_tn.type == "recipe"
        if recipe_tn and not is_real_recipe then
            warnings[#warnings + 1] = {
                "factory-solver-fp-export-warning-virtual-recipe", recipe_tn.name or "?",
            }
        end
        local recipe_name = is_real_recipe and recipe_tn.name or nil
        if recipe_name and machine then
            local limit_constraint = recipe_constraints[recipe_name]
            local limit = nil
            local force_limit = false
            if limit_constraint and limit_constraint.limit_type ~= "lower" then
                limit = limit_constraint.limit_amount_per_second
                force_limit = (limit_constraint.limit_type == "equal")
            end

            local machine_packed = {
                class = "Machine",
                proto = pack_proto(machine.name, "machines"),
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
            if pl.fuel_typed_name then
                local machine_proto = prototypes.entity[machine.name]
                if machine_proto and acc.is_use_fuel(machine_proto) then
                    machine_packed.fuel = {
                        class = "Fuel",
                        proto = pack_proto(pl.fuel_typed_name.name, "fuels"),
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
