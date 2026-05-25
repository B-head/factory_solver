local acc = require "manage/accessor"

local M = {}

-- Helmod's Model.version constant (src/data/Model.lua). Pinning the value we
-- advertise — rather than reading script.active_mods["helmod"] — keeps the
-- payload shape stable: Helmod's migration runner accepts an older version
-- (no-op) but a freshly-bumped version we never validated against could
-- silently change Helmod's expectations.
local HELMOD_EXPORT_VERSION = 2

-- Time window Helmod calculates within. We always normalise to per-second
-- (Model.time = 1) because factory_solver stores rates per-second internally
-- and there's no benefit to scaling.
local DEFAULT_TIME = 1

---@param p any
---@return string?
local function read_name(p)
    if type(p) == "table" then return p.name end
    if type(p) == "string" then return p end
    return nil
end

---@param q any
---@return string
local function read_quality(q)
    return q or "normal"
end

---Resolve item-vs-fluid for an arbitrary name. Falls back to "item" so a
---missing prototype still leaves the TypedName with a valid FilterType.
---@param name string
---@return "item"|"fluid"
local function infer_item_or_fluid(name)
    if prototypes.fluid and prototypes.fluid[name] then return "fluid" end
    return "item"
end

---Helmod keys block.products / block.ingredients by Product:getTableKey()
---(src/model/Product.lua). That format is:
---  - normal quality, no temperature: just `name`
---  - non-normal quality: `name#quality`
---  - fluid with temperature: `name#temperature`
---  - fluid with min/max range: `name#min#max`
---ModelCompute.prepareBlockElements rebuilds block.products from recipes
---on import and recovers user-set inputs via `block.products[key].input`,
---so a mismatching key here silently drops every constraint we export.
---@param name string
---@param quality string?
---@param temperature number?
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return string
local function table_key(name, quality, temperature, minimum_temperature, maximum_temperature)
    if temperature then
        return string.format("%s#%s", name, temperature)
    end
    if minimum_temperature or maximum_temperature then
        local lo = minimum_temperature or -1e300
        local hi = maximum_temperature or 1e300
        return string.format("%s#%s#%s", name, lo, hi)
    end
    if quality and quality ~= "normal" then
        return string.format("%s#%s", name, quality)
    end
    return name
end

---Recursively walk a Helmod block tree, collecting every Recipe leaf
---into `recipes_out` and yielding every visited Block (including the
---starting one) via `blocks_out`. Helmod blocks can nest arbitrarily
---deep (each `children` entry is either a Recipe or a Block); factory_solver
---has no subfloor concept, so we flatten to a flat list with no
---duplication. We also need the inner Block nodes so the caller can
---scan their `products` / `ingredients` for user-set `.input` values —
---Helmod stores those on whatever block the user navigated into when
---they typed the number, not always on `block_root`.
---@param block any
---@param recipes_out table[]
---@param blocks_out table[]
---@param flatten_seen { [any]: any }
local function walk_blocks(block, recipes_out, blocks_out, flatten_seen)
    if type(block) ~= "table" then return end
    blocks_out[#blocks_out + 1] = block
    if type(block.children) ~= "table" then return end
    for _, child in pairs(block.children) do
        if type(child) == "table" then
            if child.class == "Block" or child.children then
                flatten_seen.nested = true
                walk_blocks(child, recipes_out, blocks_out, flatten_seen)
            elseif child.class == "Recipe" or child.factory then
                recipes_out[#recipes_out + 1] = child
            end
        end
    end
end

---Expand Helmod's `modules: { [i]: { name, quality, amount, type } }` into
---factory_solver's slot-keyed dict. Each module entry contributes `amount`
---consecutive slots so a {prod3 x2, speed3 x1} expands to
---{"1"=prod3, "2"=prod3, "3"=speed3}.
---@param modules any
---@return table<string, TypedName>
local function unpack_modules(modules)
    local out = {}
    if type(modules) ~= "table" then return out end
    local slot = 1
    for _, m in pairs(modules) do
        local name = read_name(m)
        local quality = read_quality(m and m.quality)
        local amount = tonumber(m and m.amount) or 0
        if name then
            for _ = 1, amount do
                out[tostring(slot)] = { type = "item", name = name, quality = quality }
                slot = slot + 1
            end
        end
    end
    return out
end

---Inverse of unpack_modules: collapse factory_solver's slot dict into
---Helmod's array form, grouping consecutive (name, quality) entries by
---amount. Slot order is preserved by iterating numeric keys ascending.
---@param module_typed_names table<string, TypedName>?
---@return table[]
local function pack_modules(module_typed_names)
    if type(module_typed_names) ~= "table" then return {} end
    local slots = {}
    for k, v in pairs(module_typed_names) do
        local idx = tonumber(k)
        if idx and v and v.name then
            slots[#slots + 1] = { idx = idx, name = v.name, quality = v.quality or "normal" }
        end
    end
    table.sort(slots, function(a, b) return a.idx < b.idx end)

    local modules = {}
    for _, s in ipairs(slots) do
        local last = modules[#modules]
        if last and last.name == s.name and last.quality == s.quality then
            last.amount = last.amount + 1
        else
            modules[#modules + 1] = {
                type = "item",
                name = s.name,
                quality = s.quality,
                amount = 1,
            }
        end
    end
    return modules
end

---@param recipe_data any
---@return TypedName?
local function unpack_recipe_typed_name(recipe_data)
    local name = recipe_data.name
    if not name then return nil end
    -- Helmod stores `type` per recipe (usually "recipe"; non-recipe Helmod
    -- production sources are rare). factory_solver's FilterType enumeration
    -- only knows "recipe" / "virtual_recipe", so unknown values are coerced
    -- to "recipe" and dropped if the LP can't resolve them.
    return {
        type = "recipe",
        name = name,
        quality = read_quality(recipe_data.quality),
    }
end

---@param factory any
---@return TypedName?
local function unpack_machine_typed_name(factory)
    if type(factory) ~= "table" then return nil end
    local name = factory.name
    if not name then return nil end
    return {
        type = "machine",
        name = name,
        quality = read_quality(factory.quality),
    }
end

---Helmod's `factory.fuel` is `string | FuelData { name, temperature }` —
---reflecting two on-disk shapes Helmod itself accepts. Decode both so
---factory_solver receives a uniform TypedName regardless of which form
---Helmod chose to write.
---@param factory any
---@return TypedName?
local function unpack_fuel_typed_name(factory)
    if type(factory) ~= "table" then return nil end
    local fuel = factory.fuel
    if fuel == nil then return nil end
    local name, temperature
    if type(fuel) == "string" then
        name = fuel
    elseif type(fuel) == "table" then
        name = fuel.name
        temperature = tonumber(fuel.temperature)
    end
    if not name then return nil end
    local fuel_type = infer_item_or_fluid(name)
    return {
        type = fuel_type,
        name = name,
        quality = read_quality(factory.fuel_quality),
        temperature = (fuel_type == "fluid") and temperature or nil,
    }
end

---@param beacons_array any
---@return AffectedByBeacon[]
local function unpack_beacons(beacons_array)
    local out = {}
    if type(beacons_array) ~= "table" then return out end
    for _, b in ipairs(beacons_array) do
        local name = b and b.name
        if name then
            out[#out + 1] = {
                beacon_typed_name = {
                    type = "machine",
                    name = name,
                    quality = read_quality(b.quality),
                },
                beacon_quantity = tonumber(b.combo) or 0,
                module_typed_names = unpack_modules(b.modules),
            }
        end
    end
    return out
end

---@param factory any
---@param recipe_name string
---@return Constraint?
local function unpack_factory_limit_constraint(factory, recipe_name)
    if type(factory) ~= "table" then return nil end
    local limit = tonumber(factory.limit)
    if not limit or limit == 0 then return nil end
    return {
        type = "recipe",
        name = recipe_name,
        quality = "normal",
        limit_type = "upper",
        limit_amount_per_second = limit,
    }
end

---Convert Helmod's `block.products` / `block.ingredients` entries whose
---`input` is set into factory_solver Constraints. Helmod uses `input` as
---the user-specified target rate per `Model.time`, so we normalise to
---per-second by dividing through.
---@param dict any
---@param time number
---@param out Constraint[]
local function append_io_constraints(dict, time, out)
    if type(dict) ~= "table" then return end
    local divisor = (time and time > 0) and time or 1
    for _, p in pairs(dict) do
        local input = tonumber(p and p.input)
        local name = p and p.name
        if input and name then
            local t = p.type
            if t ~= "item" and t ~= "fluid" then t = infer_item_or_fluid(name) end
            out[#out + 1] = {
                type = t,
                name = name,
                quality = read_quality(p.quality),
                limit_type = "lower",
                limit_amount_per_second = input / divisor,
            }
        end
    end
end

---Convert a block's `objectives` table into factory_solver Constraints.
---Helmod fills `block.objectives` from two sources (see
---ModelCompute.prepareBlockObjectives): user-set `.input` values when
---`has_input == true`, or a default candidate (the first state==1
---product of the first child) with `value = 1` when `has_input == false`.
---Either way it's the value Helmod's own LP optimised against, so it is
---the most faithful constraint to map onto factory_solver. The type and
---quality aren't stored on the objective itself, so we look the entry up
---in `block.products` / `block.ingredients` to recover them.
---@param block any
---@param time number
---@param out Constraint[]
---@param seen { [string]: boolean }
local function append_block_objectives(block, time, out, seen)
    if type(block) ~= "table" then return end
    if type(block.objectives) ~= "table" then return end
    local divisor = (time and time > 0) and time or 1
    local lookup = (block.by_product == false) and block.ingredients or block.products
    for key, obj in pairs(block.objectives) do
        if type(obj) == "table" then
            local value = tonumber(obj.value)
            if value and value > 0 then
                local entry = (type(lookup) == "table") and lookup[key] or nil
                local name = (type(entry) == "table" and entry.name) or (type(key) == "string" and key)
                if type(name) == "string" then
                    local raw_t = entry and entry.type
                    local t = (raw_t == "item" or raw_t == "fluid") and raw_t
                        or infer_item_or_fluid(name)
                    local quality = read_quality(entry and entry.quality)
                    local seen_key = string.format("%s/%s/%s", t, name, quality)
                    if not seen[seen_key] then
                        seen[seen_key] = true
                        out[#out + 1] = {
                            type = t,
                            name = name,
                            quality = quality,
                            limit_type = "lower",
                            limit_amount_per_second = value / divisor,
                        }
                    end
                end
            end
        end
    end
end

---Convert a decoded Helmod Model into a factory_solver payload (the same
---shape `save.import_solution` expects: name / constraints / production_lines).
---Returns the payload plus a list of localised warning strings describing
---features that could not be preserved.
---@param model any
---@return table, LocalisedString[]
function M.model_to_payload(model)
    local warnings = {}
    local constraints = {}
    local production_lines = {}

    local time = tonumber(model.time) or DEFAULT_TIME
    local root = model.block_root
    if type(root) ~= "table" then
        -- Some Helmod variants only populate `blocks` (a flat dict). Fall
        -- back to the first entry there so we still surface *something*.
        if type(model.blocks) == "table" then
            for _, b in pairs(model.blocks) do root = b; break end
        end
    end

    local flatten_seen = { nested = false }
    local leaf_recipes = {}
    local visited_blocks = {}
    if root then
        walk_blocks(root, leaf_recipes, visited_blocks, flatten_seen)
        -- Two complementary sources feed Helmod's actual LP objective:
        --   1. block.objectives — populated by ModelCompute.prepareBlockObjectives
        --      from either explicit `.input` fields (has_input == true) or a
        --      default state==1 candidate (has_input == false, value = 1).
        --      This is the value Helmod's own solver targets, so it's the most
        --      faithful constraint to import.
        --   2. block.products[*].input / block.ingredients[*].input — the raw
        --      user-set targets, kept as a fallback for Helmod variants or
        --      hand-edited payloads where `objectives` wasn't built (e.g. the
        --      model was exported pre-solve).
        -- A shared dedup map across both sources prevents pile-ups when the
        -- same item shows up in nested-block flow tables and the root
        -- objective.
        local seen_keys = {}
        local function append_unique_io(dict)
            local pending = {}
            append_io_constraints(dict, time, pending)
            for _, c in ipairs(pending) do
                local key = string.format("%s/%s/%s", c.type, c.name, c.quality or "normal")
                if not seen_keys[key] then
                    seen_keys[key] = true
                    constraints[#constraints + 1] = c
                end
            end
        end
        for _, b in ipairs(visited_blocks) do
            append_block_objectives(b, time, constraints, seen_keys)
            append_unique_io(b.products)
            append_unique_io(b.ingredients)
        end
    end

    if flatten_seen.nested then
        warnings[#warnings + 1] = { "factory-solver-helmod-import-warning-flattened-blocks" }
    end

    for _, recipe_data in ipairs(leaf_recipes) do
        local recipe_typed_name = unpack_recipe_typed_name(recipe_data)
        local machine_typed_name = unpack_machine_typed_name(recipe_data.factory)
        if recipe_typed_name and machine_typed_name then
            -- Helmod's stored `.production` accumulates float noise from its
            -- own LP / Gauss solver (e.g. 0.99999999999999982 in a recycling
            -- loop). A strict `~= 1` check flags every loop participant, so
            -- gate the warning with a small epsilon and only surface values
            -- that diverge meaningfully (manual share split, fractional %).
            local production = tonumber(recipe_data.production)
            if production and math.abs(production - 1) > 1e-6 then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-import-warning-recipe-production",
                    recipe_typed_name.name, string.format("%g", production),
                }
            end
            local factory = recipe_data.factory or {}
            if factory.module_priority then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-import-warning-module-priority",
                    recipe_typed_name.name,
                }
            end
            if type(recipe_data.beacons) == "table" then
                for _, b in ipairs(recipe_data.beacons) do
                    if (tonumber(b.per_factory) or 0) ~= 0
                        or (tonumber(b.per_factory_constant) or 0) ~= 0
                    then
                        warnings[#warnings + 1] = {
                            "factory-solver-helmod-import-warning-beacon-extras",
                            recipe_typed_name.name,
                        }
                        break
                    end
                end
            end
            if recipe_data.contraints then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-import-warning-unsupported-constraints",
                    recipe_typed_name.name,
                }
            end

            production_lines[#production_lines + 1] = {
                recipe_typed_name = recipe_typed_name,
                machine_typed_name = machine_typed_name,
                module_typed_names = unpack_modules(factory.modules),
                affected_by_beacons = unpack_beacons(recipe_data.beacons),
                fuel_typed_name = unpack_fuel_typed_name(factory),
            }

            local limit_constraint = unpack_factory_limit_constraint(
                factory, recipe_typed_name.name)
            if limit_constraint then
                constraints[#constraints + 1] = limit_constraint
            end
        end
    end

    local name = (model.infos and model.infos.title)
        or (root and root.name)
        or "Imported from Helmod"
    if type(name) ~= "string" or name == "" then
        name = "Imported from Helmod"
    end

    return {
        name = name,
        constraints = constraints,
        production_lines = production_lines,
    }, warnings
end

---Build a single Helmod Model that holds all of `solution`'s production
---lines as direct children of `block_root`. factory_solver has no sub-block
---hierarchy, so the resulting Helmod model is intentionally flat.
---@param solution Solution
---@return table, LocalisedString[]
local function solution_to_packed_model(solution)
    local warnings = {}

    -- Bucket recipe-typed constraints by recipe name so we can attach them
    -- to the matching production line as factory.limit. item / fluid
    -- constraints flow into block_root.products / .ingredients via .input.
    local recipe_constraints = {}
    local products = {}
    local ingredients = {}

    for _, c in ipairs(solution.constraints) do
        if c.type == "item" or c.type == "fluid" then
            if c.limit_type ~= "lower" then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-export-warning-upper-bound-product", c.name,
                }
            else
                if c.temperature or c.minimum_temperature or c.maximum_temperature then
                    warnings[#warnings + 1] = {
                        "factory-solver-helmod-export-warning-constraint-temperature", c.name,
                    }
                end
                local key = table_key(c.name, c.quality, c.temperature,
                    c.minimum_temperature, c.maximum_temperature)
                local entry = {
                    key = key,
                    name = c.name,
                    type = c.type,
                    quality = c.quality or "normal",
                    temperature = c.temperature,
                    minimum_temperature = c.minimum_temperature,
                    maximum_temperature = c.maximum_temperature,
                    amount = 0,
                    -- state=1 marks "main product" in Helmod (see
                    -- ModelCompute.prepareBlockElements). It gets recomputed
                    -- on the receiving side, but presetting it keeps the
                    -- entry consistent with what Helmod itself would write.
                    state = 1,
                    input = c.limit_amount_per_second,
                }
                -- block_root.products is what Helmod surfaces as the block's
                -- output requirements when by_product=true (its default).
                -- Lower-bound constraints in factory_solver have the same
                -- "produce at least X" semantics, so this maps cleanly.
                products[key] = entry
            end
        elseif c.type == "recipe" then
            recipe_constraints[c.name] = c
            if c.limit_type == "lower" then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-export-warning-recipe-lower-bound", c.name,
                }
            elseif c.limit_type == "equal" then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-export-warning-recipe-equal-bound", c.name,
                }
            end
        else
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-unsupported-constraint",
                c.type, c.name,
            }
        end
    end

    local children = {}
    local recipe_id = 0
    for _, pl in ipairs(solution.production_lines) do
        local recipe_tn = pl.recipe_typed_name
        local machine = pl.machine_typed_name
        local is_real_recipe = recipe_tn and recipe_tn.type == "recipe"

        if recipe_tn and not is_real_recipe then
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-virtual-recipe", recipe_tn.name or "?",
            }
        end
        if pl.substrate_tile_name and is_real_recipe then
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-substrate", recipe_tn.name or "?",
            }
        end

        if is_real_recipe and machine then
            recipe_id = recipe_id + 1
            local id = "R" .. tostring(recipe_id)

            local factory = {
                class = "Factory",
                name = machine.name,
                type = "entity",
                quality = machine.quality or "normal",
                amount = 0,
                energy = 0,
                speed = 0,
                limit = 0,
                modules = pack_modules(pl.module_typed_names),
            }

            -- factory_solver carries fuel_typed_name from machine presets even
            -- for electric machines; Helmod treats `factory.fuel` literally
            -- and a stray fuel on a non-burner makes its solver fail. Mirror
            -- the same gating we apply to the FP codec.
            if pl.fuel_typed_name then
                local machine_proto = prototypes.entity[machine.name]
                if machine_proto and acc.is_use_fuel(machine_proto) then
                    factory.fuel = {
                        name = pl.fuel_typed_name.name,
                        temperature = pl.fuel_typed_name.temperature,
                    }
                    factory.fuel_quality = pl.fuel_typed_name.quality or "normal"
                end
            end

            -- factory_solver's recipe-typed constraint maps onto Helmod's
            -- per-line `factory.limit` (max machine count). Helmod has no
            -- equivalent for `equal`, so the warning above already flagged
            -- those; we still emit the value because Helmod will at least
            -- read it as an upper bound.
            local rc = recipe_constraints[recipe_tn.name]
            if rc and rc.limit_type ~= "lower" then
                factory.limit = rc.limit_amount_per_second
            end

            local beacons = {}
            for _, b in ipairs(pl.affected_by_beacons or {}) do
                if b.beacon_typed_name then
                    beacons[#beacons + 1] = {
                        class = "Beacon",
                        name = b.beacon_typed_name.name,
                        type = "entity",
                        quality = b.beacon_typed_name.quality or "normal",
                        amount = 0,
                        energy = 0,
                        limit = 0,
                        combo = b.beacon_quantity or 0,
                        per_factory = 0,
                        per_factory_constant = 0,
                        modules = pack_modules(b.module_typed_names),
                    }
                end
            end

            children[id] = {
                class = "Recipe",
                id = id,
                index = recipe_id,
                name = recipe_tn.name,
                type = recipe_tn.type,
                quality = recipe_tn.quality or "normal",
                count = 0,
                production = 1,
                factory = factory,
                beacons = beacons,
            }
        end
    end

    local model = {
        class = "Model",
        id = "model_export",
        index = 0,
        owner = "",
        version = HELMOD_EXPORT_VERSION,
        time = DEFAULT_TIME,
        block_id = 1,
        recipe_id = recipe_id,
        resource_id = 0,
        infos = {
            title = solution.name,
            primary_icon = nil,
            secondary_icon = nil,
        },
        parameters = {
            effects = {
                speed = 0, productivity = 0, consumption = 0, pollution = 0, quality = 0,
            },
        },
        block_root = {
            class = "Block",
            id = "block_1",
            index = 0,
            name = solution.name,
            type = "recipe",
            owner = "",
            parent_id = "model_export",
            count = 1,
            power = 0,
            pollution = 0,
            by_product = true,
            by_factory = false,
            by_limit = false,
            children = children,
            products = products,
            ingredients = ingredients,
        },
        blocks = {},
        ingredients = {},
        products = {},
    }
    return model, warnings
end

---Quick shape check: distinguish a Helmod Model from any other decoded
---table. Helmod always sets `class = "Model"` via `Model.newModel`, but a
---raw Helmod block (rare in shared strings) is also accepted to keep
---hand-edited / migrated payloads working.
---@param decoded any
---@return boolean
function M.is_helmod_shape(decoded)
    if type(decoded) ~= "table" then return false end
    if decoded.class == "Model" then return true end
    -- Defensive fallback: a Model in flight may have lost its class tag
    -- through a migration, but block_root + blocks + time is a Helmod
    -- fingerprint nothing else in our recognised formats uses.
    return type(decoded.block_root) == "table"
        and type(decoded.blocks) == "table"
        and decoded.time ~= nil
end

---Decode a Helmod shared string. Returns (model_table, nil) on success or
---(nil, localised_error). The caller is expected to have probed
---factory_solver / Factory Planner first.
---@param s string
---@return table?
---@return LocalisedString?
function M.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, { "factory-solver-import-error-prefix" }
    end
    -- Helmod's outer envelope is the same zlib+base64 as FP's, but the
    -- inner payload is serpent-dumped Lua source — not JSON — so we need a
    -- different inner decoder. helpers.decode_string itself swallows raw
    -- (un-decoded) text too; guard with pcall so we don't surface zlib
    -- errors to the user.
    local ok, decoded = pcall(helpers.decode_string, s)
    if not ok or type(decoded) ~= "string" then
        return nil, { "factory-solver-import-error-prefix" }
    end
    -- serpent.dump output always starts with `do local _=`; treat anything
    -- else as not-a-Helmod-string before paying the loadstring cost.
    if decoded:sub(1, 8) ~= "do local" then
        return nil, { "factory-solver-import-error-prefix" }
    end
    -- Factorio is on Lua 5.2; `loadstring` is still aliased to `load` but
    -- sumneko-lua flags it as deprecated. `load` accepts a chunk string in
    -- 5.2+ and gives us the same semantics, including the runtime sandbox.
    local chunk_ok, chunk = pcall(load, decoded)
    if not chunk_ok or type(chunk) ~= "function" then
        return nil, { "factory-solver-import-error-prefix" }
    end
    local exec_ok, model = pcall(chunk)
    if not exec_ok or not M.is_helmod_shape(model) then
        return nil, { "factory-solver-import-error-prefix" }
    end
    return model, nil
end

---Encode a single Solution as a Helmod shared string. Helmod's wire format
---holds at most one Model, so the caller is expected to pre-gate to a
---single-Solution selection via the UI. If more than one is provided we
---emit only the first and warn — keeping the contract permissive instead
---of erroring at this layer.
---@param solutions Solution[]
---@return string, LocalisedString[]
function M.encode(solutions)
    local warnings = {}
    if #solutions == 0 then
        return "", warnings
    end
    if #solutions > 1 then
        warnings[#warnings + 1] = { "factory-solver-helmod-export-warning-multiple-solutions" }
    end
    local model, model_warnings = solution_to_packed_model(solutions[1])
    for _, w in ipairs(model_warnings) do warnings[#warnings + 1] = w end
    local serialised = serpent.dump(model)
    return assert(helpers.encode_string(serialised)), warnings
end

return M
