local acc = require "manage/accessor"
local tn = require "manage/typed_name"

local M = {}

---Resolve the module inventory a machine's modules live in, for building
---BlueprintInsertPlan entries. Factorio 2.0 unified the per-machine module
---inventories under `crafter_modules`; the older type-specific names
---(`assembling_machine_modules`, `furnace_modules`, `rocket_silo_modules`)
---are deprecated but still present, so prefer the unified name and fall back
---to the legacy one when running on an engine that predates it. `lab` and
---`mining-drill` keep their own distinct inventories. Returns nil only if the
---machine type is not recognised (callers gate on module_inventory_size > 0
---before this matters).
---@param machine LuaEntityPrototype
---@return defines.inventory?
function M.module_inventory_for(machine)
    local inv = defines.inventory
    local t = machine.type
    if t == "beacon" then
        return inv.beacon_modules
    elseif t == "lab" then
        return inv.lab_modules
    elseif t == "mining-drill" then
        return inv.mining_drill_modules
    elseif t == "rocket-silo" then
        return inv.crafter_modules or inv.rocket_silo_modules or inv.assembling_machine_modules
    elseif t == "furnace" then
        return inv.crafter_modules or inv.furnace_modules
    else
        -- assembling-machine and any other module-bearing crafter
        return inv.crafter_modules or inv.assembling_machine_modules
    end
end

---Build the BlueprintInsertPlan `items` array for an entity's module slots, or
---nil when there are none. Slots are walked in ascending order so the result
---is deterministic across multiplayer clients; blueprint stack indices are
---0-based while this mod's module slot keys are 1-based.
---@param entity_proto LuaEntityPrototype
---@param module_typed_names table<string, TypedName>
---@return BlueprintInsertPlan[]?
local function build_module_items(entity_proto, module_typed_names)
    local size = entity_proto.module_inventory_size
    if not size or size <= 0 then
        return nil
    end
    local inventory = M.module_inventory_for(entity_proto)
    if not inventory then
        return nil
    end
    local trimmed = acc.trim_modules(module_typed_names, size)
    local items = {}
    for index = 1, size do
        local module = trimmed[tostring(index)]
        if module then
            table.insert(items, {
                id = { name = module.name, quality = module.quality },
                items = {
                    in_inventory = {
                        { inventory = inventory, stack = index - 1, count = 1 },
                    },
                },
            })
        end
    end
    return 0 < #items and items or nil
end

---True when a production line's machine can be handed to the player as a
---placeable, configured entity. Excludes the entity-unknown sentinel
---(type "entity-ghost", used for spoilage lines and missing prototypes) and
---plant lines, where the "machine" is the plant entity itself (1 craft = 1
---plant slot, not a placeable machine) — mirrors the machine-cell guard in
---ui/solution_editor.lua.
---@param line ProductionLine
---@return boolean
function M.can_pipette(line)
    local machine = tn.typed_name_to_machine(line.machine_typed_name)
    local t = machine.type
    return t ~= "entity-ghost" and t ~= "plant"
end

---Build the BlueprintEntity list for a single configured machine: the machine
---itself at the origin, carrying its quality, its recipe (assembling machines
---and rocket silos only — furnaces/labs/drills infer it, virtual recipes have
---none), and its machine-slot modules with their qualities. Beacons are
---intentionally excluded (shared infrastructure, not part of a single
---machine). Caller must ensure can_pipette(line) first. Slots are emitted in
---ascending order so the entity table is deterministic across multiplayer
---clients.
---@param line ProductionLine
---@return BlueprintEntity[]
function M.build_machine_blueprint_entities(line)
    local machine = tn.typed_name_to_machine(line.machine_typed_name)

    ---@type BlueprintEntity
    local entity = {
        entity_number = 1,
        name = machine.name,
        position = { x = 0, y = 0 },
    }

    if line.machine_typed_name.quality ~= "normal" then
        entity.quality = line.machine_typed_name.quality
    end

    local recipe_typed_name = line.recipe_typed_name
    if recipe_typed_name.type == "recipe"
        and prototypes.recipe[recipe_typed_name.name]
        and (machine.type == "assembling-machine" or machine.type == "rocket-silo")
    then
        entity.recipe = recipe_typed_name.name
        if recipe_typed_name.quality ~= "normal" then
            entity.recipe_quality = recipe_typed_name.quality
        end
    end

    entity.items = build_module_items(machine, line.module_typed_names)

    return { entity }
end

---Build the BlueprintEntity list for a single configured beacon: the beacon at
---the origin with its quality and its modules. Beacons have no recipe. One
---entity is returned (the badge tells the user how many to place), mirroring
---the single-machine pipette. Returns nil when the group has no resolvable
---beacon prototype.
---@param affected_by_beacon AffectedByBeacon
---@return BlueprintEntity[]?
function M.build_beacon_blueprint_entities(affected_by_beacon)
    local beacon_typed_name = affected_by_beacon.beacon_typed_name
    if not beacon_typed_name then
        return nil
    end
    local beacon = tn.typed_name_to_machine(beacon_typed_name)
    if beacon.type ~= "beacon" then
        return nil
    end

    ---@type BlueprintEntity
    local entity = {
        entity_number = 1,
        name = beacon.name,
        position = { x = 0, y = 0 },
    }

    if beacon_typed_name.quality ~= "normal" then
        entity.quality = beacon_typed_name.quality
    end

    entity.items = build_module_items(beacon, affected_by_beacon.module_typed_names)

    return { entity }
end

return M
