local tn = require "manage/typed_name"

local M = {}

-- Embedded inside the JSON payload (not as a textual prefix) so the shared
-- string is pure base64+deflate, matching Factorio's blueprint convention.
-- Identification happens after decode by checking these fields.
local SIGNATURE = "factory_solver"
local CURRENT_VERSION = 1

---Walk every TypedName field inside a decoded payload and run the standard
---migration, matching the per-Solution walk in save.reinit_force_data. Kept in
---this module (not save.lua) so the codec's decode contract stays self-contained;
---reinit_force_data's walk handles legacy field-name transitions (module_names →
---module_typed_names etc.) that imports never need because the payload always
---ships the current field shape.
---@param payload table
local function migrate_typed_names(payload)
    for _, line in ipairs(payload.production_lines) do
        tn.typed_name_migration(line.recipe_typed_name)
        tn.typed_name_migration(line.machine_typed_name)
        tn.typed_name_migration(line.fuel_typed_name)
        if line.module_typed_names then
            for _, t in pairs(line.module_typed_names) do
                tn.typed_name_migration(t)
            end
        end
        if line.affected_by_beacons then
            for _, affected in ipairs(line.affected_by_beacons) do
                tn.typed_name_migration(affected.beacon_typed_name)
                if affected.module_typed_names then
                    for _, t in pairs(affected.module_typed_names) do
                        tn.typed_name_migration(t)
                    end
                end
            end
        end
    end
    for _, constraint in ipairs(payload.constraints) do
        tn.typed_name_migration(constraint)
    end
end

---Encode a Solution into a shareable string.
---Only user-input fields (name, constraints, production_lines) are serialized;
---solver-derived data (quantity_of_machines_required, problem, raw_variables,
---solver_state) is reconstructed on import via the on_tick solve pump.
---@param solution Solution
---@return string
function M.encode(solution)
    local payload = {
        signature = SIGNATURE,
        version = CURRENT_VERSION,
        name = solution.name,
        constraints = solution.constraints,
        production_lines = solution.production_lines,
    }
    return assert(helpers.encode_string(helpers.table_to_json(payload)))
end

---Decode a shared string into a payload table. Returns (payload, nil) on
---success or (nil, localised_error) on any failure. The payload's TypedNames
---are migrated to current field shapes before return.
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

    local payload = helpers.json_to_table(json)
    if type(payload) ~= "table" or payload.signature ~= SIGNATURE then
        return nil, { "factory-solver-import-error-prefix" }
    end

    if payload.version ~= CURRENT_VERSION then
        return nil, { "factory-solver-import-error-version", tostring(payload.version) }
    end

    if type(payload.name) ~= "string"
        or type(payload.constraints) ~= "table"
        or type(payload.production_lines) ~= "table"
    then
        return nil, { "factory-solver-import-error-structure" }
    end

    migrate_typed_names(payload)
    return payload, nil
end

return M
