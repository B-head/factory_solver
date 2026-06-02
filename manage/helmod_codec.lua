local acc = require "manage/accessor"
local preset = require "manage/preset"

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

-- Virtual recipe interop. Helmod and factory_solver agree on the *concept* of
-- non-Recipe production sources (boilers, mining, offshore-pumping,
-- agriculture, spoilage, energy generation, rocket launches) but encode them
-- in incompatible namespaces:
--   * Helmod uses (lua_type, name) pairs, where lua_type is one of
--     `energy` / `resource` / `boiler` / `fluid` / `rocket` / `agricultural`
--     / `spoiling` (plus `recipe`, which is the vanilla real recipe path).
--     Names are bare (e.g. `solar-panel`, `iron-ore`) except for boilers,
--     which synthesize `"<input>-><output>#<target_temperature>"`, and rocket
--     recipes, which lose silo/part identity and keep only the cargo item name.
--   * factory_solver uses a single flat name with a kind prefix on the
--     virtual_recipe TypedName: `<run>...` / `<mine>...` / `<grow>...:<seed>`
--     / `<pump>...` / `<spoil>...` / `<research>...`. Lookup goes through
--     `storage.virtuals.recipe[name]` (see manage/typed_name.lua).
-- The two helpers below bridge the namespaces in both directions. Best-effort
-- only: research, burnt, customized, and Helmod's `type="energy"` pseudo-item
-- have no factory_solver equivalent and are intentionally dropped with a
-- warning rather than silently turned into wrong recipes.

---Some Helmod virtual-recipe lua_types are marked `is_support_factory = false`
---(see Helmod's RecipePrototype.lua). For those, Helmod itself never sets a
---`factory` on the recipe child, and downstream code (`ModelCompute.lua`'s
---`recipe.factory.energy_total` etc.) only reads the factory when it's
---present. Writing a placeholder factory for these tripped the solver with
---arithmetic-on-nil errors, so we mirror Helmod's shape and omit it.
---@param lua_type string?
---@return boolean
local function helmod_lua_type_uses_factory(lua_type)
    return lua_type ~= "spoiling"
end

---factory_solver uses the plant entity itself as the "machine" for `<grow>`
---recipes (the plant occupies one tile slot, which is what the LP needs to
---track). Helmod expects the agricultural-tower as the machine, because its
---EntityPrototype:getCraftingSpeed reads energy_source_prototype — which
---plant entities don't have — and crashes with nil index when the recipe
---factory points at a plant. Find any non-hidden tower to substitute.
---@return string?
local function find_first_agricultural_tower_name()
    for _, proto in pairs(prototypes.entity) do
        if proto.type == "agricultural-tower" and not proto.hidden then
            return proto.name
        end
    end
    return nil
end

---For FS→Helmod export, swap FS-only machine identities with the real
---production entity Helmod's solver expects. Currently covers `<grow>`
---(plant entity → agricultural-tower); spoilage takes the no-factory path
---and never reaches this helper. Returns the original name when no
---substitution applies.
---@param fs_recipe_name string
---@param fs_machine_name string
---@return string
local function substitute_machine_for_helmod(fs_recipe_name, fs_machine_name)
    if fs_recipe_name:sub(1, 6) == "<grow>" then
        return find_first_agricultural_tower_name() or fs_machine_name
    end
    return fs_machine_name
end

---Helmod export sometimes writes virtual-recipe entries without an explicit
---rocket-silo identity (Player.buildRocketRecipe only stores the cargo item
---name; the silo is inferred from the first one with a fixed_recipe). Find
---one runtime silo to fill in `{silo}:{part}` for the factory_solver name.
---@return LuaEntityPrototype?, LuaRecipePrototype?
local function find_first_rocket_silo()
    local filters = {
        { filter = "type",   type = "rocket-silo", mode = "or" },
        { filter = "hidden", mode = "and",         invert = true },
    }
    for _, silo in pairs(prototypes.get_entity_filtered(filters)) do
        if silo.fixed_recipe then
            local part = prototypes.recipe[silo.fixed_recipe]
            if part then return silo, part end
        end
    end
    return nil, nil
end

---Convert a Helmod (lua_type, name) virtual-recipe pair into a factory_solver
---virtual recipe name. Returns nil + warning key when the lua_type has no
---factory_solver counterpart, or when the inferred name is not registered
---in storage.virtuals.recipe (e.g. the underlying boiler is hidden / from a
---disabled mod).
---@param lua_type string
---@param name string
---@return string? recipe_name
---@return string? warning_key
local function helmod_to_factory_recipe_name(lua_type, name)
    local pool = storage.virtuals.recipe

    if lua_type == "energy" then
        -- Helmod includes accumulator/electric-energy-interface here, which
        -- factory_solver intentionally excludes (no item I/O — see
        -- feedback_no_electricity_only_virtuals). The storage lookup naturally
        -- weeds those out and we surface the generic unmappable warning.
        local candidate = "<run>" .. name
        if pool[candidate] then return candidate end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "resource" then
        local candidate = "<mine>" .. name
        if pool[candidate] then return candidate end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "spoiling" then
        local candidate = "<spoil>" .. name
        if pool[candidate] then return candidate end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "fluid" then
        -- Helmod stores fluid recipes keyed by the output fluid name; the
        -- backing tile is whichever offshore-pump tile produces that fluid.
        -- Walk tiles and take the first match. (Tile candidates are usually
        -- 1:1 with their fluid in vanilla/SA, so the ambiguity is academic.)
        for _, tile in pairs(prototypes.tile) do
            local fluid = tile.fluid
            if fluid and fluid.name == name then
                local candidate = "<pump>" .. tile.name
                if pool[candidate] then return candidate end
            end
        end
        -- No tile produces this fluid: it may still be pumped by a filter-pinned
        -- offshore-pump, which factory_solver keys `<pump-fluid>{fluid}`.
        local filter_candidate = "<pump-fluid>" .. name
        if pool[filter_candidate] then return filter_candidate end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "agricultural" then
        -- Helmod names this recipe by the seed item; the plant is the seed's
        -- `plant_result`. factory_solver keys by `<grow>{plant}:{seed}`.
        local seed_item = prototypes.item[name]
        if seed_item and seed_item.plant_result then
            local candidate = string.format("<grow>%s:%s",
                seed_item.plant_result.name, name)
            if pool[candidate] then return candidate end
        end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "boiler" then
        -- Helmod synthesises `"input->output#target"` (Player.buildFluidRecipe).
        -- Parse, then iterate runtime boilers to find a match whose
        -- per-input virtual recipe registers the expected output + temperature.
        -- Non-greedy capture keeps fluid names containing `-` (heavy-oil,
        -- light-oil, sulfuric-acid …) intact instead of stopping at the
        -- first hyphen.
        local input_name, output_name, temp_str = string.match(name,
            "^(.-)%->(.-)#(.+)$")
        if not (input_name and output_name and temp_str) then
            return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
        end
        local target_temp = tonumber(temp_str)
        local boiler_filters = {
            { filter = "type",   type = "boiler", mode = "or" },
            { filter = "hidden", mode = "and",    invert = true },
        }
        for boiler_name, _ in pairs(prototypes.get_entity_filtered(boiler_filters)) do
            local candidate = string.format("<run>%s:%s", boiler_name, input_name)
            local recipe = pool[candidate]
            if recipe and recipe.products and recipe.products[1] then
                local p = recipe.products[1]
                local temp_ok = (target_temp == nil)
                    or (p.temperature and math.abs(p.temperature - target_temp) < 1e-3)
                if p.name == output_name and temp_ok then
                    return candidate
                end
            end
        end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "rocket" then
        -- Helmod keeps only the cargo item name; pick any silo + its part to
        -- fill in the factory_solver-side identity. Best-effort: vanilla has
        -- exactly one silo, so this is deterministic in the common case.
        local silo, part = find_first_rocket_silo()
        if silo and part then
            local candidate = string.format("<run>%s:%s:%s", silo.name, part.name, name)
            if pool[candidate] then return candidate end
        end
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
    elseif lua_type == "burnt" then
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-burnt"
    elseif lua_type == "technology" then
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-technology"
    elseif lua_type == "constant" then
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-customized"
    end
    -- Helmod-side customized recipes carry `lua_type == "recipe"` plus the
    -- `helmod_customized_` prefix; flag those before falling through.
    if string.find(name, "^helmod_customized_") then
        return nil, "factory-solver-helmod-import-warning-virtual-recipe-customized"
    end
    return nil, "factory-solver-helmod-import-warning-virtual-recipe-unmappable"
end

---Convert a factory_solver virtual recipe name into a Helmod (lua_type, name)
---pair. Returns nil + warning key when the prefix has no Helmod counterpart
---(`<research>`) or when the underlying recipe entry has gone missing.
---@param recipe_name string
---@return string? lua_type
---@return string? helmod_name
---@return string? warning_key
local function factory_to_helmod_recipe_name(recipe_name)
    local pool = storage.virtuals.recipe

    -- `<mine>{entity}` → Helmod (resource, entity)
    local mine_body = string.match(recipe_name, "^<mine>(.+)$")
    if mine_body then
        return "resource", mine_body
    end

    -- `<spoil>{item}` → Helmod (spoiling, item)
    local spoil_body = string.match(recipe_name, "^<spoil>(.+)$")
    if spoil_body then
        return "spoiling", spoil_body
    end

    -- `<grow>{plant}:{seed}` → Helmod (agricultural, seed)
    local _, grow_seed = string.match(recipe_name, "^<grow>([^:]+):(.+)$")
    if grow_seed then
        return "agricultural", grow_seed
    end

    -- `<pump-fluid>{fluid}` (filter-pinned pump, no backing tile) → Helmod
    -- (fluid, fluid): the output fluid name is carried directly in the key.
    -- Checked before `<pump>` since `^<pump>(.+)$` does not match the hyphen.
    local pump_fluid_body = string.match(recipe_name, "^<pump%-fluid>(.+)$")
    if pump_fluid_body then
        return "fluid", pump_fluid_body
    end

    -- `<pump>{tile}` → Helmod (fluid, fluid_name_from_tile)
    local pump_body = string.match(recipe_name, "^<pump>(.+)$")
    if pump_body then
        local tile = prototypes.tile[pump_body]
        if tile and tile.fluid then
            return "fluid", tile.fluid.name
        end
        return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe"
    end

    -- `<research>` has no Helmod analogue with matching semantics; tech
    -- recipes in Helmod produce a `technology` pseudo-item, not pack flow.
    if string.find(recipe_name, "^<research>") then
        return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe-research"
    end

    -- `<run>...` is overloaded across boilers / rocket silos / standalone
    -- energy entities; differentiate by colon count.
    local run_body = string.match(recipe_name, "^<run>(.+)$")
    if run_body then
        local first, second = string.match(run_body, "^([^:]+):([^:]+)$")
        if first and second then
            -- `<run>{boiler}:{input_fluid}` → (boiler, "input->output#temp")
            local recipe = pool[recipe_name]
            if recipe and recipe.products and recipe.products[1] then
                local p = recipe.products[1]
                local temp = p.temperature
                if temp then
                    return "boiler", string.format("%s->%s#%s", second, p.name, temp)
                end
            end
            return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe"
        end
        local silo, part, cargo = string.match(run_body, "^([^:]+):([^:]+):(.+)$")
        if silo and part and cargo then
            -- `<run>{silo}:{part}:{cargo}`. Helmod-side rocket recipes name
            -- themselves after the cargo item; `space-age` is the SA cargo-pod
            -- launch path which has no Helmod analogue.
            if cargo == "space-age" then
                return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe"
            end
            return "rocket", cargo
        end
        -- No colon → standalone energy entity. factory_solver builds a
        -- `<run>X` recipe for many entity types (generator, burner-generator,
        -- reactor, fusion-reactor, fusion-generator, thruster); Helmod's
        -- `lua_type == "energy"` is built off Player.getEnergyMachines, which
        -- accepts only the subset below. Anything outside it (notably
        -- thrusters) deserializes into a 0-W / 0-factory ghost recipe, so
        -- whitelist explicitly rather than blacklist by hand: an unknown
        -- entity type stays on the safe side and surfaces a warning instead
        -- of producing a degenerate entry.
        local entity = prototypes.entity[run_body]
        if entity then
            local t = entity.type
            if t == "generator" or t == "burner-generator"
                or t == "reactor" or t == "fusion-reactor"
                or t == "fusion-generator" or t == "solar-panel"
                or t == "accumulator" or t == "electric-energy-interface" then
                return "energy", run_body
            end
        end
        return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe"
    end

    return nil, nil, "factory-solver-helmod-export-warning-virtual-recipe"
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

---Decode a Helmod recipe entry into a factory_solver TypedName. Returns a
---second value (warning key) for non-fatal mapping issues — usually because
---the Helmod lua_type has no factory_solver counterpart, or the named
---virtual recipe isn't present in this save's prototype set.
---@param recipe_data any
---@return TypedName?
---@return string?
local function unpack_recipe_typed_name(recipe_data)
    local name = recipe_data.name
    if not name then return nil end
    local lua_type = recipe_data.type
    if lua_type == nil or lua_type == "recipe" then
        -- Helmod-side customized recipes share the "recipe" type tag but use
        -- a sentinel name prefix; factory_solver has no editable-recipe
        -- mechanism so they're flagged and dropped.
        if string.find(name, "^helmod_customized_") then
            return nil, "factory-solver-helmod-import-warning-virtual-recipe-customized"
        end
        return {
            type = "recipe",
            name = name,
            quality = read_quality(recipe_data.quality),
        }
    end
    local mapped, warning_key = helmod_to_factory_recipe_name(lua_type, name)
    if not mapped then
        return nil, warning_key
    end
    return {
        type = "virtual_recipe",
        name = mapped,
        quality = read_quality(recipe_data.quality),
    }
end

---@param factory any
---@param recipe_typed_name TypedName?
---@return TypedName?
local function unpack_machine_typed_name(factory, recipe_typed_name)
    if recipe_typed_name and recipe_typed_name.type == "virtual_recipe" then
        -- Helmod's own export omits `factory` for `is_support_factory = false`
        -- recipe types (notably `spoiling`). For those, synthesize the FS-side
        -- sentinel machine that pre_solve expects rather than dropping the line.
        if recipe_typed_name.name:sub(1, 7) == "<spoil>" then
            return {
                type = "machine",
                name = "entity-unknown",
                quality = "normal",
            }
        end
        -- `<grow>{plant}:{seed}`: Helmod's factory.name is the agricultural-tower
        -- (substituted on export). Restore the plant entity from the FS recipe
        -- name so pre_solve / get_machine_preset finds it via fixed_crafting_machine.
        local plant = recipe_typed_name.name:match("^<grow>([^:]+):")
        if plant then
            return {
                type = "machine",
                name = plant,
                quality = read_quality(factory and factory.quality),
            }
        end
    end
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
---
---Helmod uses the "steam-heat" / "energy" pseudo-item names for heat /
---electricity respectively (type="energy"). factory_solver instead carries
---heat as the `<heat>` virtual_material via `accessor.try_get_fixed_fuel`
---and has no electricity-as-fuel concept. Returning nil for these falls
---through to `save.new_production_line`'s preset lookup, which fills in
---the correct fuel TypedName from the machine prototype's energy source.
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
    -- Helmod-side pseudo-items ("steam-heat" / "energy") and any
    -- factory_solver virtual_material name (`<heat>`, etc., from a previous
    -- round-trip through an older codec version) have no `item`/`fluid`
    -- prototype to bind to. Returning nil lets the import-time preset
    -- ([save.lua] new_production_line → preset.get_fuel_preset) fill in
    -- the correct TypedName from the machine's energy source instead of
    -- materialising as an unresolved "?" fuel slot.
    if name == "steam-heat" or name == "energy"
        or name:sub(1, 1) == "<" then
        return nil
    end
    local fuel_type = infer_item_or_fluid(name)
    -- Helmod carries a single fuel temperature; the range-only model stores it as
    -- the degenerate range [T,T].
    local fuel_temp = (fuel_type == "fluid") and temperature or nil
    return {
        type = fuel_type,
        name = name,
        quality = read_quality(factory.fuel_quality),
        minimum_temperature = fuel_temp,
        maximum_temperature = fuel_temp,
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
---@param recipe_typed_name TypedName
---@return Constraint?
local function unpack_factory_limit_constraint(factory, recipe_typed_name)
    if type(factory) ~= "table" then return nil end
    local limit = tonumber(factory.limit)
    if not limit or limit == 0 then return nil end
    return {
        type = recipe_typed_name.type,
        name = recipe_typed_name.name,
        quality = recipe_typed_name.quality or "normal",
        limit_type = "upper",
        limit_amount_per_second = limit,
    }
end

---Decode a Helmod product / ingredient entry's fluid temperature into the
---range-only model. Helmod carries either a single `temperature` (collapsed to
---the degenerate range [T,T], mirroring unpack_fuel_typed_name) or, on a
---round-trip from factory_solver's own export, an explicit
---`minimum_temperature` / `maximum_temperature` pair. Only meaningful for
---fluids; callers gate on type. Returns (nil, nil) for a temperature-less entry
---so the resulting Constraint stays a bare fluid.
---@param entry any
---@return number? minimum_temperature
---@return number? maximum_temperature
local function unpack_fluid_temperature(entry)
    if type(entry) ~= "table" then return nil, nil end
    local temperature = tonumber(entry.temperature)
    if temperature then
        return temperature, temperature
    end
    return tonumber(entry.minimum_temperature), tonumber(entry.maximum_temperature)
end

---Convert Helmod's `block.products` / `block.ingredients` entries whose
---`input` is set into factory_solver Constraints. Helmod uses `input` as
---the user-specified target rate per `Model.time`, so we normalise to
---per-second by dividing through.
---
---Helmod's `type="energy"` pseudo-item (covering both electricity and
---`steam-heat`) has no factory_solver counterpart — the LP has no
---electricity channel — so we record a warning and drop the entry rather
---than letting `infer_item_or_fluid` coerce it into a non-existent item
---constraint that surfaces in the UI as a "?" placeholder.
---@param dict any
---@param time number
---@param out Constraint[]
---@param warnings LocalisedString[]
local function append_io_constraints(dict, time, out, warnings)
    if type(dict) ~= "table" then return end
    local divisor = (time and time > 0) and time or 1
    for _, p in pairs(dict) do
        local input = tonumber(p and p.input)
        local name = p and p.name
        if input and name then
            if p.type == "energy" then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-import-warning-energy-pseudo-item", name,
                }
            else
                local t = p.type
                if t ~= "item" and t ~= "fluid" then t = infer_item_or_fluid(name) end
                local min_temp, max_temp
                if t == "fluid" then
                    min_temp, max_temp = unpack_fluid_temperature(p)
                end
                out[#out + 1] = {
                    type = t,
                    name = name,
                    quality = read_quality(p.quality),
                    limit_type = "lower",
                    limit_amount_per_second = input / divisor,
                    minimum_temperature = min_temp,
                    maximum_temperature = max_temp,
                }
            end
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
---@param warnings LocalisedString[]
local function append_block_objectives(block, time, out, seen, warnings)
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
                    if raw_t == "energy" then
                        -- Helmod's `type="energy"` pseudo-item (electricity /
                        -- steam-heat) has no factory_solver counterpart; the
                        -- LP doesn't model an electricity channel. Drop the
                        -- objective so it doesn't materialise as a "?" item.
                        warnings[#warnings + 1] = {
                            "factory-solver-helmod-import-warning-energy-pseudo-item", name,
                        }
                    else
                        local t = (raw_t == "item" or raw_t == "fluid") and raw_t
                            or infer_item_or_fluid(name)
                        local quality = read_quality(entry and entry.quality)
                        local min_temp, max_temp
                        if t == "fluid" then
                            min_temp, max_temp = unpack_fluid_temperature(entry)
                        end
                        -- Temperature is part of the variable identity: two
                        -- objectives on the same fluid at different temperatures
                        -- are distinct constraints, so the dedup key must include
                        -- it (otherwise steam@500 and steam@165 collapse to one).
                        local seen_key = string.format("%s/%s/%s/%s/%s", t, name, quality,
                            tostring(min_temp), tostring(max_temp))
                        if not seen[seen_key] then
                            seen[seen_key] = true
                            out[#out + 1] = {
                                type = t,
                                name = name,
                                quality = quality,
                                limit_type = "lower",
                                limit_amount_per_second = value / divisor,
                                minimum_temperature = min_temp,
                                maximum_temperature = max_temp,
                            }
                        end
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
---@param player_index integer
---@return table, LocalisedString[]
function M.model_to_payload(model, player_index)
    local warnings = {}
    local constraints = {}
    local production_lines = {}

    -- Some Helmod features (per-recipe beacon multipliers, module priority
    -- ordering, mod-specific constraint rules) drop on import because
    -- factory_solver has no equivalent — but they fire on every recipe
    -- that uses the feature, drowning out the rare per-line warnings
    -- (duplicate recipe, production multiplier ≠ 1, unmappable virtual
    -- recipe). Accumulate counts and emit one aggregated warning per
    -- kind at the end; the recipe identity isn't actionable for these.
    local aggregated_warning_counts = {}
    local function add_aggregated_warning(locale_key)
        aggregated_warning_counts[locale_key] =
            (aggregated_warning_counts[locale_key] or 0) + 1
    end

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
            append_io_constraints(dict, time, pending, warnings)
            for _, c in ipairs(pending) do
                local key = string.format("%s/%s/%s", c.type, c.name, c.quality or "normal")
                if not seen_keys[key] then
                    seen_keys[key] = true
                    constraints[#constraints + 1] = c
                end
            end
        end
        for _, b in ipairs(visited_blocks) do
            append_block_objectives(b, time, constraints, seen_keys, warnings)
            append_unique_io(b.products)
            append_unique_io(b.ingredients)
        end
    end

    if flatten_seen.nested then
        warnings[#warnings + 1] = { "factory-solver-helmod-import-warning-flattened-blocks" }
    end

    -- Helmod's hierarchical model can hold the same recipe in multiple blocks
    -- (and walk_blocks flattens them into a single leaf list), but the LP keys
    -- one variable per (type, name, quality) tuple — feeding two ProductionLines
    -- with the same key trips an assert in problem_generator.add_objective.
    -- Dedupe on the same composite key the variable name uses so quality
    -- variants of the same recipe are kept distinct.
    local seen_recipes = {}
    for _, recipe_data in ipairs(leaf_recipes) do
        local recipe_typed_name, recipe_warning = unpack_recipe_typed_name(recipe_data)
        local machine_typed_name = unpack_machine_typed_name(recipe_data.factory,
            recipe_typed_name)
        if recipe_warning then
            warnings[#warnings + 1] = { recipe_warning, recipe_data.name or "?" }
        end
        if recipe_typed_name and machine_typed_name then
            local dedup_key = string.format("%s/%s/%s",
                recipe_typed_name.type,
                recipe_typed_name.name,
                recipe_typed_name.quality or "normal")
            if seen_recipes[dedup_key] then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-import-warning-duplicate-recipe",
                    recipe_typed_name.name,
                }
                goto continue_leaf
            end
            seen_recipes[dedup_key] = true
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
                add_aggregated_warning(
                    "factory-solver-helmod-import-warning-module-priority")
            end
            if type(recipe_data.beacons) == "table" then
                for _, b in ipairs(recipe_data.beacons) do
                    if (tonumber(b.per_factory) or 0) ~= 0
                        or (tonumber(b.per_factory_constant) or 0) ~= 0
                    then
                        add_aggregated_warning(
                            "factory-solver-helmod-import-warning-beacon-extras")
                        break
                    end
                end
            end
            if recipe_data.contraints then
                add_aggregated_warning(
                    "factory-solver-helmod-import-warning-unsupported-constraints")
            end

            -- `accessor.normalize_production_line` asserts that fuel-using
            -- machines carry a fuel_typed_name. Helmod itself omits the fuel
            -- field for heat-energy machines (heat goes in via the recipe's
            -- steam-heat ingredient, not factory.fuel), and our import side
            -- nil's out pseudo-item / virtual-material names. Fall back to
            -- the entity's fixed fuel (heat → `<heat>` virtual_material,
            -- filtered fluid energy → that fluid's TypedName), then for
            -- generic burners (stone-furnace, pY's burner family, ...) to
            -- the user's FS preset the same way the FP codec does, so the
            -- line arrives in storage in the shape pre_solve expects.
            local fuel_typed_name = unpack_fuel_typed_name(factory)
            if not fuel_typed_name then
                local machine_proto = prototypes.entity[machine_typed_name.name]
                if machine_proto and acc.is_use_fuel(machine_proto) then
                    fuel_typed_name = acc.try_get_fixed_fuel(machine_proto)
                        or preset.get_fuel_preset(player_index, machine_typed_name)
                end
            end

            production_lines[#production_lines + 1] = {
                recipe_typed_name = recipe_typed_name,
                machine_typed_name = machine_typed_name,
                module_typed_names = unpack_modules(factory.modules),
                affected_by_beacons = unpack_beacons(recipe_data.beacons),
                fuel_typed_name = fuel_typed_name,
            }

            local limit_constraint = unpack_factory_limit_constraint(
                factory, recipe_typed_name)
            if limit_constraint then
                constraints[#constraints + 1] = limit_constraint
            end
        end
        ::continue_leaf::
    end

    -- Flush aggregated counters into the warning list. Sort keys so the
    -- output is deterministic across loads (pairs() iteration order is
    -- not stable, and warnings surface in the import dialog).
    local sorted_keys = {}
    for key in pairs(aggregated_warning_counts) do
        sorted_keys[#sorted_keys + 1] = key
    end
    table.sort(sorted_keys)
    for _, key in ipairs(sorted_keys) do
        warnings[#warnings + 1] = { key, tostring(aggregated_warning_counts[key]) }
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
            end
            if c.minimum_temperature or c.maximum_temperature then
                warnings[#warnings + 1] = {
                    "factory-solver-helmod-export-warning-constraint-temperature", c.name,
                }
            end
            -- factory_solver is range-only; Helmod represents an exact temperature
            -- as a single `#T` key (Product:getTableKey), so collapse a degenerate
            -- range [T,T] back to Helmod's single form and keep real ranges as
            -- `#min#max`.
            local single_temp = nil
            if c.minimum_temperature and c.minimum_temperature == c.maximum_temperature then
                single_temp = c.minimum_temperature
            end
            local key = table_key(c.name, c.quality, single_temp,
                single_temp and nil or c.minimum_temperature,
                single_temp and nil or c.maximum_temperature)
            local entry = {
                key = key,
                name = c.name,
                type = c.type,
                quality = c.quality or "normal",
                temperature = single_temp,
                minimum_temperature = single_temp and nil or c.minimum_temperature,
                maximum_temperature = single_temp and nil or c.maximum_temperature,
                amount = 0,
                -- state=1 marks "main product" in Helmod (see
                -- ModelCompute.prepareBlockElements). It gets recomputed
                -- on the receiving side, but presetting it keeps the
                -- entry consistent with what Helmod itself would write.
                state = 1,
                input = c.limit_amount_per_second,
            }
            -- block_root.products is what Helmod surfaces as the block's
            -- output requirements when by_product=true (its default), which
            -- has "produce at least X" semantics. factory_solver's lower
            -- bound maps cleanly. upper / equal bounds have no equivalent
            -- on Helmod's side, so we write the amount through the same
            -- input field anyway: the value flows across so the user can
            -- retune in Helmod rather than rebuild from scratch, and the
            -- warning above flags the semantic shift. Dropping the entry
            -- entirely (the previous behaviour) was the worst option since
            -- factory_solver's default constraint is upper, meaning a
            -- typical export silently lost most of the user's targets.
            products[key] = entry
        elseif c.type == "recipe" or c.type == "virtual_recipe" then
            -- Virtual-recipe constraints reuse the same per-line `factory.limit`
            -- channel as real recipes; the LP variable is the same kind (one
            -- variable per ProductionLine) and Helmod has no concept-level
            -- distinction once the variable is realised as a Recipe child.
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
        local is_virtual_recipe = recipe_tn and recipe_tn.type == "virtual_recipe"

        -- For virtual recipes, resolve the Helmod (lua_type, name) pair up
        -- front; this either succeeds (commit to writing the line) or returns
        -- a warning key so we can drop the line with a category-specific
        -- message instead of the generic "unsupported" one.
        local helmod_lua_type, helmod_name, virtual_warning
        if is_virtual_recipe then
            helmod_lua_type, helmod_name, virtual_warning =
                factory_to_helmod_recipe_name(recipe_tn.name)
            if virtual_warning then
                warnings[#warnings + 1] = { virtual_warning, recipe_tn.name }
            end
        elseif recipe_tn and not is_real_recipe then
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-virtual-recipe", recipe_tn.name or "?",
            }
        end
        if pl.substrate_tile_name and is_real_recipe then
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-substrate", recipe_tn.name or "?",
            }
        end

        local emit_as_helmod_recipe = is_real_recipe
            or (is_virtual_recipe and helmod_lua_type and helmod_name)
        -- Diagnostic: a line that was eligible to emit but is missing a
        -- machine_typed_name would otherwise vanish silently. Surface it so
        -- the user can tell the difference between "no production lines"
        -- and "lines exist but were dropped because the machine field is
        -- empty / unresolved".
        if emit_as_helmod_recipe and not machine then
            warnings[#warnings + 1] = {
                "factory-solver-helmod-export-warning-no-machine",
                (recipe_tn and recipe_tn.name) or "?",
            }
        end
        if emit_as_helmod_recipe and machine then
            recipe_id = recipe_id + 1
            local id = "R" .. tostring(recipe_id)

            -- Spoilage (and any other Helmod `is_support_factory=false` type)
            -- carries no `factory` subtable in Helmod's own model: Helmod
            -- itself skips Model.setFactory for these (see ModelBuilder.lua's
            -- `if recipe_prototype:isSupportFactory()` gate), and downstream
            -- ModelCompute relies on the absence to skip count/energy math.
            -- Writing a placeholder factory causes `recipe.factory.energy_total`
            -- to be read as nil → arithmetic crash. Match Helmod's shape.
            local emit_factory = not is_virtual_recipe
                or helmod_lua_type_uses_factory(helmod_lua_type)

            -- For some virtual recipes, factory_solver's machine identity is
            -- the recipe's "host" entity (plant for <grow>, etc.) which lacks
            -- an energy source. Helmod's EntityPrototype:getCraftingSpeed
            -- assumes a real production entity, so substitute the entity
            -- Helmod's solver would associate with that recipe type.
            local helmod_machine_name = machine.name
            if is_virtual_recipe then
                helmod_machine_name = substitute_machine_for_helmod(
                    recipe_tn.name, machine.name)
            end

            local factory = nil
            if emit_factory then
                factory = {
                    class = "Factory",
                    name = helmod_machine_name,
                    type = "entity",
                    quality = machine.quality or "normal",
                    amount = 0,
                    energy = 0,
                    speed = 0,
                    limit = 0,
                    modules = pack_modules(pl.module_typed_names),
                }

                -- factory_solver carries fuel_typed_name from machine presets
                -- even for electric machines; Helmod treats `factory.fuel`
                -- literally and a stray fuel on a non-burner makes its solver
                -- fail. Mirror the same gating we apply to the FP codec.
                -- Also skip when the fuel is a factory_solver virtual_material
                -- (e.g. `<heat>` for heat-exchanger): Helmod models heat as an
                -- ingredient (steam-heat pseudo-item) rather than a factory.fuel
                -- value, so emitting our virtual name here would have Helmod
                -- write it back verbatim and our import side would later
                -- decode it as an unknown item ("?" in the UI).
                if pl.fuel_typed_name
                    and pl.fuel_typed_name.type ~= "virtual_material" then
                    local machine_proto = prototypes.entity[machine.name]
                    if machine_proto and acc.is_use_fuel(machine_proto) then
                        factory.fuel = {
                            name = pl.fuel_typed_name.name,
                            -- Range-only model: a fluid fuel's temperature is the
                            -- degenerate range [T,T]; Helmod wants the single T.
                            temperature = pl.fuel_typed_name.minimum_temperature,
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

            -- Virtual recipes go out with their mapped Helmod identity; real
            -- recipes keep the literal type/name pair. Either way, Helmod's
            -- own decoder reconstructs the rest of the entry from `type`.
            local child_type = is_virtual_recipe and helmod_lua_type or recipe_tn.type
            local child_name = is_virtual_recipe and helmod_name or recipe_tn.name
            children[id] = {
                class = "Recipe",
                id = id,
                index = recipe_id,
                name = child_name,
                type = child_type,
                quality = recipe_tn.quality or "normal",
                count = 0,
                production = 1,
                factory = factory,
                beacons = beacons,
            }
        end
    end

    -- An empty children dict usually means every production_line failed the
    -- emit gate (silently dropped because machine_typed_name was nil, or
    -- because the solution had no lines at all). Surface this explicitly so
    -- the user isn't left wondering why Helmod imports an empty model
    -- without any other diagnostic.
    if recipe_id == 0 and #solution.production_lines > 0 then
        warnings[#warnings + 1] = {
            "factory-solver-helmod-export-warning-no-recipes-emitted",
            tostring(#solution.production_lines),
        }
    elseif recipe_id < #solution.production_lines then
        -- Partial drop: at least one line was skipped. The per-line skip
        -- already added a specific warning above, but emit a summary so the
        -- user has an unmissable "N dropped" signal even if individual
        -- warnings scroll past in the chat history.
        warnings[#warnings + 1] = {
            "factory-solver-helmod-export-warning-partial-drop",
            tostring(#solution.production_lines - recipe_id),
            tostring(#solution.production_lines),
        }
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

    -- Self-test: Helmod's Converter.read crashes (Converter.lua:47, "attempt
    -- to call local 'data_table' (a nil value)") when its `loadstring` of our
    -- decoded payload returns nil. Either our serpent dump isn't valid Lua, or
    -- the encode/decode round-trip mangles the bytes. Catch both here so the
    -- failure surfaces on the factory_solver side with a clear message,
    -- instead of looking like a Helmod-internal crash later.
    -- load() returns nil + an error message on invalid source (it does not
    -- raise), so check the returned chunk directly; a pcall would report
    -- success even for a syntax error and never flag it.
    local chunk = load(serialised)
    if not chunk then
        warnings[#warnings + 1] = {
            "factory-solver-helmod-export-warning-self-test-loadstring",
        }
    end
    local encoded = assert(helpers.encode_string(serialised))
    local decode_ok, decoded = pcall(helpers.decode_string, encoded)
    if not decode_ok or type(decoded) ~= "string" or decoded ~= serialised then
        warnings[#warnings + 1] = {
            "factory-solver-helmod-export-warning-self-test-roundtrip",
        }
    end
    return encoded, warnings
end

return M
