local LibDeflate = require "lib/libdeflate"
local base64 = require "manage/base64"
local json = require "manage/json"
local acc = require "manage/accessor"
local preset = require "manage/preset"

local M = {}

-- YAFC-CE share strings are produced by ProjectPageSettingsPanel.ExportPageToClipboard:
--   base64( raw-DEFLATE( "YAFC\nProjectPage\n" .. <YafcLib.version> .. "\n\n\n" .. <JSON> ) )
-- The JSON is a serialized ProjectPage whose `content` is a ProductionTable
-- (`links[]` + `recipes[]`). Unlike FP / Helmod / the native codec, YAFC uses
-- *raw* DEFLATE (no zlib header), which `helpers.decode_string` cannot read, so
-- this codec inflates with the vendored LibDeflate and base64s by hand.
local HEADER = "YAFC\nProjectPage\n"

-- Version advertised on export. Pinned low so YAFC's importer
-- (LoadProjectPageFromClipboard) never trips its "saved with a newer version"
-- warning; YAFC only errors on a malformed header, not an old version.
local EXPORT_VERSION = "0.0.0.0"

-- A fixed page guid keeps export deterministic (no game.tick / random, which
-- would break multiplayer bit-identity and the smoke round-trip). A single
-- imported page never collides with itself, so a constant zero guid is fine.
local EXPORT_GUID = "00000000-0000-0000-0000-000000000000"

-- Object references serialize as "<TypePrefix>.<prototype-name>" (FactorioObject
-- .typeDotName). Map the YAFC type prefix to the factory_solver FilterType for
-- materials. Recipes / entities / qualities are handled separately.
local PREFIX_TO_FILTER_TYPE = {
    Item = "item",
    Fluid = "fluid",
}

--------------------------------------------------------------------------------
-- Low-level string helpers (no Factorio dependency)
--------------------------------------------------------------------------------

---Split a "Prefix.name" token into its parts on the FIRST dot. The remainder is
---returned whole, so "Mechanics.reactor.heat" yields ("Mechanics", "reactor.heat")
---while "Item.iron-ore" yields ("Item", "iron-ore"). Returns nil on a malformed
---token.
---@param token any
---@return string? prefix
---@return string? name
local function split_token(token)
    if type(token) ~= "string" then return nil, nil end
    return string.match(token, "^([^.]+)%.(.+)$")
end

---Read a "Quality.<name>" token down to the bare quality name. Defaults to
---"normal" for a missing / malformed value.
---@param q any
---@return string
local function read_quality(q)
    local _, name = split_token(q)
    return name or "normal"
end

---Read a YAFC object reference into (typeDotName, quality_name). Handles all
---three shapes YAFC has used:
---  * `{ target = "Item.x", quality = "Quality.normal" }` — object form;
---  * `"!Item.x!normal"` — the newer dictionary-key string form (2.19+), where
---    the leading "!" is the separator and the quality is the bare name;
---  * `"Item.x"` — the old quality-less bare string.
---@param ref any
---@return string? target
---@return string quality
local function read_ref(ref)
    if type(ref) == "string" then
        if string.sub(ref, 1, 1) == "!" then
            -- Common single-"!" separator; names never contain "!" in practice,
            -- so a non-greedy target up to the last "!" recovers (target, quality).
            local target, quality = string.match(ref, "^!(.+)!([^!]+)$")
            if target then
                return target, quality
            end
        end
        return ref, "normal"
    end
    if type(ref) ~= "table" then return nil, "normal" end
    return ref.target, read_quality(ref.quality)
end

---Split a fluid name that may carry YAFC's "@<temperature>" suffix into its bare
---name and the temperature. Returns (name, nil) when there is no suffix.
---@param name string
---@return string base_name
---@return number? temperature
local function split_fluid_temperature(name)
    local base, temp = string.match(name, "^(.+)@(%-?%d+)$")
    if base then
        return base, tonumber(temp)
    end
    return name, nil
end

---Split the inflated envelope into its version line and JSON body. Returns
---(version, json) or (nil, nil) when the header does not match. `.` matches
---newlines in Lua patterns, so the final capture grabs the whole JSON body.
---@param text string
---@return string? version
---@return string? json
local function split_envelope(text)
    return string.match(text, "^YAFC\nProjectPage\n([^\n]*)\n\n\n(.*)$")
end

--------------------------------------------------------------------------------
-- typeDotName builders (export side)
--------------------------------------------------------------------------------

---@param filter_type FilterType
---@param name string
---@return string
local function to_token(filter_type, name)
    if filter_type == "item" then return "Item." .. name end
    if filter_type == "fluid" then return "Fluid." .. name end
    if filter_type == "machine" then return "Entity." .. name end
    if filter_type == "recipe" then return "Recipe." .. name end
    -- Defensive fallback only. Virtual recipes are routed through
    -- virtual_recipe_to_yafc before reaching here, and machine / item / fluid
    -- cover every other to_ref caller, so this branch is not normally hit.
    return name
end

---Build a YAFC object reference in its "dictionary-key" STRING form
---`<sep><target><sep><quality>` (e.g. `!Recipe.iron-plate!normal`).
---
---YAFC accepts two wire forms for an `IObjectWithQuality` (recipe / entity /
---fuel / goods / module / beacon): this string form, and an object form
---`{ "target": ..., "quality": ... }`. We MUST use the string form, because
---YAFC's object-form reader (QualityObjectSerializer.ReadFromJson) is
---*positional* — it reads `target` then `quality` by slot, never by property
---name — while manage/json sorts object keys alphabetically, emitting `quality`
---before `target`. That mismatch makes YAFC read each value into the wrong slot,
---resolve both to nil, and silently drop the reference (no error, just a null
---recipe/entity), which empties every imported row. The string form has no key
---order to get wrong and is also exactly what current YAFC writes on export.
---
---`sep` starts at "!" and grows by alternating "@"/"!" until it collides with
---neither name, mirroring QualityObjectSerializer.GetJsonProperty. Factorio
---names never contain "!"/"@" outside a fluid's "@<temp>" suffix (which sits in
---the target, not at its start), so in practice `sep` is always "!".
---@param target string  FactorioObject typeDotName, e.g. "Recipe.iron-plate"
---@param quality string bare quality name, e.g. "normal"
---@return string
local function ref_string(target, quality)
    local sep = "!"
    while true do
        if target:find(sep, 1, true) or quality:find(sep, 1, true) or target:sub(1, 1) == "@" then
            sep = sep .. "@"
        else
            break
        end
        if target:find(sep, 1, true) or quality:find(sep, 1, true) or target:sub(1, 1) == "!" then
            sep = sep .. "!"
        else
            break
        end
    end
    return sep .. target .. sep .. quality
end

---@param typed_name TypedName
---@return string
local function to_ref(typed_name)
    local target = to_token(typed_name.type, typed_name.name)
    -- YAFC keys a fluid at a non-default temperature as "Fluid.<name>@<temp>"
    -- (FactorioDataDeserializer renames each variant `name += "@" + temperature`),
    -- and resolves the string form by an *exact* objectsByTypeName lookup. So the
    -- temperature must match a real YAFC variant. factory_solver stores a [min,max]
    -- range; take the lower bound, then clamp into the fluid's physical range
    -- [default_temperature, max_temperature] so a fuel whose factory_solver
    -- temperature sits below default (e.g. 0) maps to YAFC's default variant
    -- (e.g. uf6@39) instead of a non-existent uf6@0. A single-temperature fluid
    -- keeps a bare "Fluid.x" object, which resolves regardless of the suffix.
    if typed_name.type == "fluid" and typed_name.minimum_temperature then
        local temp = typed_name.minimum_temperature
        local proto = prototypes.fluid[typed_name.name]
        if proto then
            if temp < proto.default_temperature then temp = proto.default_temperature end
            if temp > proto.max_temperature then temp = proto.max_temperature end
        end
        target = string.format("%s@%d", target, math.floor(temp + 0.5))
    end
    return ref_string(target, typed_name.quality or "normal")
end

--------------------------------------------------------------------------------
-- Decode (YAFC string -> ProjectPage table)
--------------------------------------------------------------------------------

---Decode a YAFC share string into its ProjectPage table. Returns
---(project_page, nil) on success or (nil, localised_error). Mirrors the
---fall-through contract of the other codecs: any structural mismatch returns
---the generic prefix error so `decode_any` can try the next codec.
---@param s string
---@return table?
---@return LocalisedString?
function M.decode(s)
    if type(s) ~= "string" or s == "" then
        return nil, { "factory-solver-import-error-prefix" }
    end

    local raw = base64.decode(s)
    if raw == "" then
        return nil, { "factory-solver-import-error-prefix" }
    end

    -- LibDeflate returns nil on a non-deflate stream (e.g. the zlib-wrapped FP /
    -- Helmod / native strings), so this naturally rejects them. pcall guards the
    -- argument-validation error path as well.
    local ok, text = pcall(function() return LibDeflate:DecompressDeflate(raw) end)
    if not ok or type(text) ~= "string" then
        return nil, { "factory-solver-import-error-prefix" }
    end

    local _, json_body = split_envelope(text)
    if not json_body then
        return nil, { "factory-solver-import-error-prefix" }
    end

    local parse_ok, page = pcall(helpers.json_to_table, json_body)
    if not parse_ok or type(page) ~= "table" then
        return nil, { "factory-solver-import-error-prefix" }
    end

    -- Confirm it really is a ProductionTable page rather than some other YAFC
    -- object that happens to share the envelope.
    if type(page.content) ~= "table" then
        return nil, { "factory-solver-import-error-structure" }
    end

    return page, nil
end

--------------------------------------------------------------------------------
-- YAFC -> factory_solver payload
--------------------------------------------------------------------------------

---Map a YAFC recipe token onto a factory_solver recipe TypedName. Real recipes
---(`Recipe.*`) map directly. Special "Mechanics.*" pseudo-recipes have no fixed
---cross-tool name, so they are resolved best-effort: item spoilage
---(`Mechanics.spoil.{item}`) is rebuilt from the token alone, since it has no
---crafting entity; the rest are resolved off the crafting `entity` --
---factory_solver keys most energy mechanics `<run>{entity}` (generator, reactor,
---fusion reactor/generator, thruster, burner-generator) and single-fluid boilers
---`<run>{entity}:{fluid}`. A factory_solver-native token (one starting with "<",
---produced by this codec's own export) is accepted verbatim for round-tripping.
---Anything else is dropped with a warning rather than guessed wrong.
---@param recipe_target string
---@param recipe_quality string
---@param entity_name string?
---@return TypedName? recipe_typed_name
---@return string? warning_key
local function map_recipe(recipe_target, recipe_quality, entity_name)
    local prefix, name = split_token(recipe_target)

    if prefix == "Recipe" and name then
        return { type = "recipe", name = name, quality = recipe_quality }, nil
    end

    local pool = storage.virtuals.recipe

    -- factory_solver-native virtual name round-trip channel.
    if string.sub(recipe_target, 1, 1) == "<" then
        if pool[recipe_target] then
            return { type = "virtual_recipe", name = recipe_target, quality = recipe_quality }, nil
        end
        return nil, "factory-solver-yafc-import-warning-recipe-unmappable"
    end

    -- Mechanics.spoil.{item} -> <spoil>{item}. YAFC keys its spoilage recipe by
    -- the spoiling item (CreateSpecialRecipe(item, SpecialNames.SpoilRecipe="spoil"))
    -- and crafts it with a synthetic "spoilage" entity that has no Factorio
    -- prototype. factory_solver has no such entity either (its spoilage line uses
    -- the entity-unknown sentinel), so -- unlike every other Mechanics.* recipe --
    -- this one resolves from the token, not the crafting entity, which our own
    -- export omits.
    if prefix == "Mechanics" and name then
        local spoil_item = string.match(name, "^spoil%.(.+)$")
        if spoil_item then
            local fs_name = "<spoil>" .. spoil_item
            if pool[fs_name] then
                return { type = "virtual_recipe", name = fs_name, quality = recipe_quality }, nil
            end
            return nil, "factory-solver-yafc-import-warning-recipe-unmappable"
        end
    end

    -- Mechanics.* (or anything else): resolve off the crafting entity.
    if entity_name then
        local run = "<run>" .. entity_name
        if pool[run] then
            return { type = "virtual_recipe", name = run, quality = recipe_quality }, nil
        end
        -- Single-fluid boiler: exactly one `<run>{entity}:{fluid}` key.
        local match, count = nil, 0
        local needle = "^<run>" .. string.gsub(entity_name, "[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%0") .. ":"
        for key in pairs(pool) do
            if string.find(key, needle) then
                match, count = key, count + 1
            end
        end
        if count == 1 then
            return { type = "virtual_recipe", name = match, quality = recipe_quality }, nil
        end
    end

    return nil, "factory-solver-yafc-import-warning-recipe-unmappable"
end

---Expand a YAFC module list (`[{ module = {target,quality}, fixedCount }]`) into
---factory_solver's slot-keyed dict. `fixedCount > 0` places exactly that many of
---the module in consecutive slots; `fixedCount == 0` is YAFC's "auto-fill", which
---we realise by filling the owner's remaining module slots with that module.
---@param list any
---@param owner_name string?
---@param owner_quality string
---@return table<string, TypedName>
local function unpack_module_list(list, owner_name, owner_quality)
    local out = {}
    if type(list) ~= "table" then return out end

    local owner_proto = owner_name and prototypes.entity[owner_name]
    local total_slots = (owner_proto and acc.get_machine_module_inventory_size(owner_proto, owner_quality)) or 0

    local slot = 1
    for _, entry in ipairs(list) do
        local target, quality = read_ref(entry.module)
        local _, mod_name = split_token(target)
        if mod_name then
            local count = tonumber(entry.fixedCount) or 0
            if count <= 0 then
                count = math.max(0, total_slots - (slot - 1))
            end
            for _ = 1, count do
                if slot > total_slots and total_slots > 0 then break end
                out[tostring(slot)] = { type = "item", name = mod_name, quality = quality }
                slot = slot + 1
            end
        end
    end
    return out
end

---Decode the YAFC `modules.beacon` / `modules.beaconList` / `modules.beaconCount`
---into factory_solver's AffectedByBeacon list. YAFC carries a single beacon
---entity for the row; absent beacon -> no beacon effects.
---@param modules any
---@return AffectedByBeacon[]
local function unpack_beacons(modules)
    if type(modules) ~= "table" then return {} end
    local target, quality = read_ref(modules.beacon)
    if not target then return {} end
    local _, beacon_name = split_token(target)
    if not beacon_name then return {} end

    return {
        {
            beacon_typed_name = { type = "machine", name = beacon_name, quality = quality },
            beacon_quantity = tonumber(modules.beaconCount) or 1,
            module_typed_names = unpack_module_list(modules.beaconList, beacon_name, quality),
        },
    }
end

---Resolve the fuel TypedName for a recipe row. `Power.electricity` (and any other
---`Power.*`) carries no factory_solver fuel. A missing fuel on a burner machine
---falls back to the entity's fixed fuel, then to the player's preset, matching
---the FP / Helmod codecs so the line reaches storage in the shape pre_solve wants.
---@param fuel_ref any
---@param machine_typed_name TypedName
---@param player_index integer
---@return TypedName?
local function unpack_fuel(fuel_ref, machine_typed_name, player_index)
    local target, quality = read_ref(fuel_ref)
    if target then
        local prefix, name = split_token(target)
        if prefix == "Item" and name then
            return { type = "item", name = name, quality = quality }
        elseif prefix == "Fluid" and name then
            local fluid_name, temp = split_fluid_temperature(name)
            return {
                type = "fluid",
                name = fluid_name,
                quality = "normal",
                minimum_temperature = temp,
                maximum_temperature = temp,
            }
        end
        -- Power.* and anything else: no fuel channel.
    end

    local machine_proto = prototypes.entity[machine_typed_name.name]
    if machine_proto and acc.is_use_fuel(machine_proto) then
        return acc.try_get_fixed_fuel(machine_proto)
            or preset.get_fuel_preset(player_index, machine_typed_name)
    end
    return nil
end

---factory_solver models item spoilage as a virtual recipe with no crafting
---machine -- the `entity-unknown` sentinel that pre_solve / is_spoilage detection
---expects. YAFC instead crafts its spoil recipe with a synthetic "spoilage"
---entity (no Factorio prototype), and factory_solver's own export omits the row's
---entity entirely. Either way the machine identity is reconstructed from the
---recipe rather than read off the row, so a spoilage line must not be gated on a
---present `entity`.
---@param recipe_typed_name TypedName
---@return boolean
local function is_spoilage_recipe(recipe_typed_name)
    return recipe_typed_name.type == "virtual_recipe"
        and string.match(recipe_typed_name.name, "^<spoil>") ~= nil
end

---Convert a YAFC ProjectPage into a factory_solver payload (the same
---{ name, constraints, production_lines } shape `save.import_solution` expects).
---Lossy by nature, so per-feature mapping failures are collected as warnings
---rather than aborting the import.
---@param page table
---@param player_index integer
---@return table
---@return LocalisedString[]
function M.yafc_to_payload(page, player_index)
    local warnings = {}
    local constraints = {}
    local production_lines = {}

    local content = page.content
    local links = (type(content.links) == "table") and content.links or {}
    local recipes = (type(content.recipes) == "table") and content.recipes or {}

    -- links[]: a non-zero `amount` is a user-pinned production target for that
    -- good. YAFC stores it signed (sign distinguishes the matched direction);
    -- factory_solver constraints are net-rate bounds, so we map |amount| to a
    -- lower bound. The sign nuance is best-effort: the user can retune the
    -- direction after import.
    for _, link in ipairs(links) do
        local amount = tonumber(link.amount)
        if amount and amount ~= 0 then
            local target, quality = read_ref(link.goods)
            local prefix, name = split_token(target)
            local filter_type = prefix and PREFIX_TO_FILTER_TYPE[prefix]
            if filter_type and name then
                local min_temp, max_temp
                if filter_type == "fluid" then
                    name, min_temp = split_fluid_temperature(name)
                    max_temp = min_temp
                end
                constraints[#constraints + 1] = {
                    type = filter_type,
                    name = name,
                    quality = quality,
                    limit_type = "lower",
                    limit_amount_per_second = math.abs(amount),
                    minimum_temperature = min_temp,
                    maximum_temperature = max_temp,
                }
            end
        end
    end

    -- recipes[]: one production line each. Dedupe on the (type, name, quality)
    -- tuple the LP keys variables by, matching the Helmod codec.
    local seen = {}
    for _, entry in ipairs(recipes) do
        local recipe_target, recipe_quality = read_ref(entry.recipe)
        local entity_target, machine_quality = read_ref(entry.entity)
        local _, entity_name = split_token(entity_target or "")

        if recipe_target then
            local recipe_typed_name, warning_key = map_recipe(recipe_target, recipe_quality, entity_name)
            if warning_key then
                warnings[#warnings + 1] = { warning_key, recipe_target }
            end

            -- Resolve the crafting machine before the gate. Spoilage carries no
            -- entity (see is_spoilage_recipe), so it gets the sentinel and is not
            -- dropped for an absent / synthetic `entity`; every other recipe still
            -- requires a real entity, so the row gate is unchanged for them.
            local machine_typed_name
            if recipe_typed_name and is_spoilage_recipe(recipe_typed_name) then
                machine_typed_name = { type = "machine", name = "entity-unknown", quality = machine_quality or "normal" }
            elseif entity_name then
                machine_typed_name = { type = "machine", name = entity_name, quality = machine_quality }
            end

            if recipe_typed_name and machine_typed_name then
                local dedup_key = string.format("%s/%s/%s",
                    recipe_typed_name.type, recipe_typed_name.name, recipe_typed_name.quality)
                if seen[dedup_key] then
                    warnings[#warnings + 1] = {
                        "factory-solver-yafc-import-warning-duplicate-recipe", recipe_typed_name.name,
                    }
                else
                    seen[dedup_key] = true

                    production_lines[#production_lines + 1] = {
                        recipe_typed_name = recipe_typed_name,
                        machine_typed_name = machine_typed_name,
                        module_typed_names = unpack_module_list(
                            type(entry.modules) == "table" and entry.modules.list or nil,
                            entity_name, machine_quality),
                        affected_by_beacons = unpack_beacons(entry.modules),
                        fuel_typed_name = unpack_fuel(entry.fuel, machine_typed_name, player_index),
                    }

                    -- A fixed building count is a machine-count cap on this recipe.
                    local fixed = tonumber(entry.fixedBuildings)
                    if fixed and fixed > 0 then
                        constraints[#constraints + 1] = {
                            type = recipe_typed_name.type,
                            name = recipe_typed_name.name,
                            quality = recipe_typed_name.quality,
                            limit_type = "upper",
                            limit_amount_per_second = fixed,
                        }
                    end
                end
            end
        end
    end

    local name = (type(page.name) == "string" and page.name ~= "" and page.name) or "Imported from YAFC"

    return {
        name = name,
        constraints = constraints,
        production_lines = production_lines,
    }, warnings
end

--------------------------------------------------------------------------------
-- factory_solver -> YAFC string (export)
--------------------------------------------------------------------------------

---Collapse a slot-keyed module dict into YAFC's `list` form, grouping
---consecutive identical (name, quality) slots into one `{ module, fixedCount }`
---entry. Slot order is taken from the ascending numeric keys.
---@param module_typed_names table<string, TypedName>?
---@return table[]
local function pack_module_list(module_typed_names)
    if type(module_typed_names) ~= "table" then return {} end
    local slots = {}
    for k, v in pairs(module_typed_names) do
        local idx = tonumber(k)
        if idx and v and v.name then
            slots[#slots + 1] = { idx = idx, name = v.name, quality = v.quality or "normal" }
        end
    end
    table.sort(slots, function(a, b) return a.idx < b.idx end)

    local list = {}
    for _, s in ipairs(slots) do
        local last = list[#list]
        if last and last._name == s.name and last._quality == s.quality then
            last.fixedCount = last.fixedCount + 1
        else
            list[#list + 1] = {
                module = ref_string("Item." .. s.name, s.quality),
                fixedCount = 1,
                _name = s.name,
                _quality = s.quality,
            }
        end
    end
    -- Strip the bookkeeping keys before serialization.
    for _, e in ipairs(list) do
        e._name = nil
        e._quality = nil
    end
    return list
end

---Build the `modules` value for a recipe row. Returns json.null for a row with
---no machine modules and no beacon (YAFC writes `"modules":null` for those),
---otherwise the full ModuleTemplate shape `{ beacon, list, beaconList }`. The
---explicit json.null beacon and json.array (even when empty) lists are exactly
---what YAFC's deserializer expects — Factorio's table_to_json cannot express
---either, which is why the export serializes through manage/json. `beaconCount`
---is intentionally not written: YAFC computes it from the module count and the
---beacon's slot count, it is not a serialized property.
---@param line ProductionLine
---@return table
local function pack_modules(line)
    local list = pack_module_list(line.module_typed_names)
    local beacons = line.affected_by_beacons
    local beacon = (type(beacons) == "table" and beacons[1] and beacons[1].beacon_typed_name)
        and beacons[1] or nil

    if #list == 0 and not beacon then
        return json.null
    end

    return {
        beacon = beacon and to_ref(beacon.beacon_typed_name) or json.null,
        list = json.array(list),
        beaconList = json.array(beacon and pack_module_list(beacon.module_typed_names) or {}),
    }
end

---Map a factory_solver virtual recipe to the YAFC special-recipe token YAFC's
---own parser produces, so the row imports into real YAFC instead of erroring.
---YAFC keys its special "Mechanics.*" recipes by mechanic + goods, and merges a
---set of stable former-alias names into its lookup table (Database.LoadBuiltData),
---so these tokens resolve on import. The mapped ones are reconstructable from the
---entity type, the virtual recipe's product, and its stored attributes (verified
---against YAFC-CE's SpecialNames / CreateSpecialRecipe): spoil, offshore pump
---(pump.tile), fluid pump, plant (by seed), mining (by category + resource),
---reactor, generator, and boiler. Mechanics whose YAFC name we cannot rebuild
---(rocket part / launch, fusion plasma, thruster, research) or that have no YAFC
---equivalent (source / sink) return nil, so the caller drops the row with a
---warning rather than emitting a token YAFC would reject.
---@param recipe_typed_name TypedName
---@return string?
local function virtual_recipe_to_yafc(recipe_typed_name)
    local name = recipe_typed_name.name
    local vr = storage.virtuals.recipe[name]
    local function first_product()
        return vr and vr.products and vr.products[1] and vr.products[1].name or nil
    end

    -- <spoil>{item} -> Mechanics.spoil.{item}
    local spoil = string.match(name, "^<spoil>(.+)$")
    if spoil then
        return "Mechanics." .. "spoil" .. "." .. spoil
    end

    -- <pump>{tile} is an offshore pump (pumps a fluid from a tile): YAFC keys it
    -- under the "pump.tile" category -> Mechanics.pump.tile.{fluid}.
    if string.match(name, "^<pump>") then
        local fluid = first_product()
        if fluid then
            return "Mechanics.pump.tile." .. fluid
        end
        return nil
    end

    -- <pump-fluid>{fluid} is a pump entity with a fluid filter: YAFC keys it under
    -- the "pump.{fluid}" category -> Mechanics.pump.{fluid}.{fluid}.
    if string.match(name, "^<pump%-fluid>") then
        local fluid = first_product()
        if fluid then
            return string.format("Mechanics.pump.%s.%s", fluid, fluid)
        end
        return nil
    end

    -- <grow>{plant}:{seed} -> Mechanics.plant.{seed}. YAFC's harvesting recipe is
    -- CreateSpecialRecipe(seed, "plant"), keyed by the planted seed item.
    local plant_seed = string.match(name, "^<grow>[^:]+:(.+)$")
    if plant_seed then
        return "Mechanics.plant." .. plant_seed
    end

    -- <mine>{resource} -> Mechanics.mining.{category}.{resource}. YAFC's mining
    -- recipe is CreateSpecialRecipe(resource, "mining." .. category), keyed by the
    -- resource's mining category and the resource entity name. The virtual recipe
    -- carries the category (resource_category); without it the token can't be
    -- rebuilt, so drop the row rather than guess.
    local resource = string.match(name, "^<mine>(.+)$")
    if resource then
        local category = vr and vr.resource_category
        if category then
            return string.format("Mechanics.mining.%s.%s", category, resource)
        end
        return nil
    end

    -- <run>{entity}[:...] -> dispatch by the crafting entity's type.
    local run = string.match(name, "^<run>(.+)$")
    if run then
        local entity_name = string.match(run, "^([^:]+)")
        local proto = entity_name and prototypes.entity[entity_name]
        local t = proto and proto.type
        if t == "reactor" then
            -- All reactors share YAFC's single heat recipe; the specific reactor
            -- rides on the row's `entity`. Former alias, stable across versions.
            return "Mechanics.reactor.heat"
        elseif t == "generator" or t == "burner-generator"
            or t == "electric-energy-interface" then
            return "Mechanics.generator.electricity"
        elseif t == "boiler" then
            local out = first_product()
            if out then
                return string.format("Mechanics.boiler.%s.%s", entity_name, out)
            end
        end
        -- fusion-reactor (plasma) / fusion-generator / thruster: no stable YAFC name.
        return nil
    end

    -- <mine>, <grow>, <research>, <launch>, rocket, source/sink: not reconstructable.
    return nil
end

---Encode a list of Solutions as a YAFC share string. YAFC's ProjectPage format
---carries a single page, so only the first solution is exported; extra
---selections are flagged. virtual_recipe lines are mapped to YAFC's "Mechanics.*"
---special recipes where reconstructable; the rest are dropped with a warning
---(emitting a factory_solver-native name would make YAFC reject the whole row).
---Returns (string, warnings).
---@param solutions Solution[]
---@return string
---@return LocalisedString[]
function M.encode(solutions)
    local warnings = {}
    local solution = solutions[1]
    if #solutions > 1 then
        warnings[#warnings + 1] = { "factory-solver-yafc-export-warning-single-page" }
    end

    local links = {}
    local recipe_caps = {} ---@type table<string, number> recipe name -> fixedBuildings
    for _, c in ipairs(solution.constraints) do
        if c.type == "item" or c.type == "fluid" then
            if c.limit_type ~= "lower" then
                warnings[#warnings + 1] = {
                    "factory-solver-yafc-export-warning-bound-direction", c.name,
                }
            end
            if c.minimum_temperature or c.maximum_temperature then
                warnings[#warnings + 1] = {
                    "factory-solver-yafc-export-warning-temperature", c.name,
                }
            end
            links[#links + 1] = {
                goods = to_ref(c),
                amount = c.limit_amount_per_second,
                algorithm = 0,
            }
        elseif c.type == "recipe" or c.type == "virtual_recipe" then
            -- A recipe/virtual-recipe bound becomes a fixedBuildings cap on the
            -- matching row. factory_solver keys these per (name); the LP has one
            -- variable per line, so the last one wins on a collision (rare).
            recipe_caps[c.name] = c.limit_amount_per_second
        end
    end

    local recipes = {}
    for _, line in ipairs(solution.production_lines) do
        local recipe_tn = line.recipe_typed_name

        local recipe_ref
        if recipe_tn.type == "virtual_recipe" then
            local token = virtual_recipe_to_yafc(recipe_tn)
            if token then
                recipe_ref = ref_string(token, recipe_tn.quality or "normal")
            else
                -- No YAFC recipe corresponds; drop the row rather than emit a
                -- token YAFC would reject (which broke the whole row's import).
                warnings[#warnings + 1] = {
                    "factory-solver-yafc-export-warning-virtual-recipe", recipe_tn.name,
                }
            end
        else
            recipe_ref = to_ref(recipe_tn)
        end

        if recipe_ref then
            local row = {
                recipe = recipe_ref,
                fixedBuildings = recipe_caps[recipe_tn.name] or 0,
                fixedFuel = false,
                enabled = true,
                modules = pack_modules(line),
            }

            -- Omit the crafting entity when it is not a YAFC EntityCrafter, so
            -- YAFC assigns a sensible default crafter instead of logging a
            -- not-found object:
            --   * "entity-unknown" -- factory_solver's no-crafter sentinel (spoilage).
            --   * a <grow> plant recipe -- factory_solver models the plant entity
            --     itself as the machine (yumako-tree, jellystem), but YAFC crafts
            --     plant harvesting in the agricultural tower.
            local machine = line.machine_typed_name
            local is_grow = recipe_tn.type == "virtual_recipe"
                and string.match(recipe_tn.name, "^<grow>") ~= nil
            if machine and machine.name ~= "entity-unknown" and not is_grow then
                row.entity = to_ref(machine)
            end

            local fuel = line.fuel_typed_name
            if fuel then
                if fuel.type == "item" or fuel.type == "fluid" then
                    -- Item and fluid fuels both map to a YAFC fuel object via the
                    -- string form. A fluid fuel carries its temperature: a YAFC
                    -- source round-trips to the exact same variant (e.g. py
                    -- encodes uranium enrichment as the fluid temperature, so
                    -- uf6@9999 lands back on uf6@9999), while an FS-native
                    -- acceptance temperature snaps to YAFC's closest variant -- a
                    -- minor temperature approximation, not the whole-row rejection
                    -- the old quality-first object form used to cause.
                    row.fuel = to_ref(fuel)
                else
                    -- Any other energy source (the <heat> virtual_material a
                    -- heat-exchanger / steam-turbine consumes) has no YAFC fuel
                    -- object. Emitting its raw token (e.g. "<heat>") makes YAFC
                    -- log a not-found object; drop it -- YAFC drives heat from the
                    -- reactor chain, not a fuel item.
                    warnings[#warnings + 1] = {
                        "factory-solver-yafc-export-warning-heat-fuel", fuel.name,
                    }
                end
            else
                row.fuel = ref_string("Power.electricity", "normal")
            end

            recipes[#recipes + 1] = row
        end
    end

    local page = {
        contentType = "Yafc.Model.ProductionTable",
        guid = EXPORT_GUID,
        name = solution.name,
        content = {
            expanded = true,
            -- json.array forces `[...]` (and `[]` when empty), which YAFC's
            -- deserializer requires and helpers.table_to_json cannot produce.
            links = json.array(links),
            recipes = json.array(recipes),
        },
    }

    local body = HEADER .. EXPORT_VERSION .. "\n\n\n" .. json.encode(page)
    local compressed = assert(LibDeflate:CompressDeflate(body))
    return base64.encode(compressed), warnings
end

return M
