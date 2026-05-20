local M = {}

---comment
---@param elem_type ElemType
---@param name string
---@param quality string?
---@return ElemID
function M.create_elem_id(elem_type, name, quality)
    return { type = elem_type, name = name, quality = quality }
end

---@type table<FilterType, ElemType>
local type_dictionary = {
    ["item"] = "item-with-quality",
    ["fluid"] = "fluid",
    ["recipe"] = "recipe",
    ["machine"] = "entity-with-quality",
}

---comment
---@param typed_name TypedName
---@return LocalisedString?
function M.typed_name_to_tooltip(typed_name)
    if not M.validate_typed_name(typed_name) then
        return nil
    end

    if typed_name.type == "virtual_material" then
        local material = storage.virtuals.material[typed_name.name]
        return material and material.tooltip
    elseif typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[typed_name.name]
        return recipe and recipe.tooltip
    else
        return nil
    end
end

---comment
---@param typed_name TypedName
---@return ElemID?
function M.typed_name_to_elem_id(typed_name)
    if not M.validate_typed_name(typed_name) then
        return nil
    end

    if typed_name.type == "virtual_material" then
        local material = storage.virtuals.material[typed_name.name]
        return material and material.elem_tooltip
    elseif typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[typed_name.name]
        return recipe and recipe.elem_tooltip
    else
        return { type = type_dictionary[typed_name.type], name = typed_name.name, quality = typed_name.quality }
    end
end

---Returns true when a fluid TypedName carries no temperature information.
---Non-fluid types always return false.
---@param typed_name TypedName
---@return boolean
function M.is_bare_fluid(typed_name)
    return typed_name.type == "fluid"
        and typed_name.temperature == nil
        and typed_name.minimum_temperature == nil
        and typed_name.maximum_temperature == nil
end

---Formats the trailing temperature suffix for an LP variable name.
---Returns "" for bare, "@<temperature>" for single, "@[<min>,<max>]" for range.
---@param typed_name TypedName
---@return string
function M.format_temperature_suffix(typed_name)
    if typed_name.temperature ~= nil then
        return string.format("@%g", typed_name.temperature)
    elseif typed_name.minimum_temperature ~= nil then
        return string.format("@[%g,%g]", typed_name.minimum_temperature, typed_name.maximum_temperature)
    else
        return ""
    end
end

---comment
---@param typed_name TypedName
---@return string
function M.typed_name_to_variable_name(typed_name)
    if typed_name.type == "fluid" then
        return string.format("fluid/%s%s", typed_name.name, M.format_temperature_suffix(typed_name))
    else
        return string.format("%s/%s/%s", typed_name.type, typed_name.name, typed_name.quality)
    end
end

---comment
---@param filter_type FilterType | "research-progress"
---@param name string
---@param quality string?
---@param temperature number?
---@param minimum_temperature number?
---@param maximum_temperature number?
---@return TypedName
function M.create_typed_name(filter_type, name, quality, temperature, minimum_temperature, maximum_temperature)
    if filter_type == "research-progress" then
        filter_type = "virtual_material"
    end
    if filter_type == "fluid" then
        quality = "normal"
    else
        quality = quality or "normal"
    end
    return {
        type = filter_type,
        name = name,
        quality = quality,
        temperature = temperature,
        minimum_temperature = minimum_temperature,
        maximum_temperature = maximum_temperature,
    }
end

---comment
---@param value1 TypedName
---@param value2 TypedName
---@param ignore_quality boolean?
---@return boolean
function M.equals_typed_name(value1, value2, ignore_quality)
    if value1.type ~= value2.type or value1.name ~= value2.name then
        return false
    end
    if not ignore_quality and value1.quality ~= value2.quality then
        return false
    end
    if value1.temperature ~= value2.temperature then
        return false
    end
    if value1.minimum_temperature ~= value2.minimum_temperature then
        return false
    end
    if value1.maximum_temperature ~= value2.maximum_temperature then
        return false
    end
    return true
end

---comment
---@param typed_name TypedName?
---@return boolean
function M.validate_typed_name(typed_name)
    if not typed_name then
        return false
    end

    local type = typed_name.type
    local name = typed_name.name
    if type == "item" then
        return prototypes.item[name] ~= nil
    elseif type == "fluid" then
        return prototypes.fluid[name] ~= nil
    elseif type == "recipe" then
        return prototypes.recipe[name] ~= nil
    elseif type == "machine" then
        return prototypes.entity[name] ~= nil
    elseif type == "virtual_material" then
        return storage.virtuals.material[name] ~= nil
    elseif type == "virtual_recipe" then
        return storage.virtuals.recipe[name] ~= nil
    else
        return false
    end
end

---comment
---@param typed_name TypedName?
function M.typed_name_migration(typed_name)
    if not typed_name then
        return
    end

    local type = typed_name.type
    local name = typed_name.name
    local quality = typed_name.quality

    if type == "virtual-object" then
        type = "virtual_material"
    elseif type == "virtual-recipe" then
        type = "virtual_recipe"
    elseif type == "virtual-machine" or type == "virtual_machine" then
        type = "machine"
    end
    
    name = string.gsub(name, "<minable>", "<mine>")

    if not quality then
        quality = "normal"
    end

    typed_name.type = type
    typed_name.name = name
    typed_name.quality = quality
end

-- The fallback names below (item-unknown, fluid-unknown, recipe-unknown,
-- entity-unknown) are provided by __core__, not by this mod, so a TypedName
-- whose prototype is no longer present in any loaded mod still resolves to a
-- placeholder rather than nil. Note that entity-unknown is type=entity-ghost:
-- it has no module_inventory_size / effect_receiver / *_energy_source_prototype,
-- and methods like get_crafting_speed return nil. Callers must tolerate the
-- resulting nil/0 instead of asserting (see the unknown-energy fallbacks in
-- accessor.lua). The "<material-unknown>" placeholder is different: that one
-- lives in storage.virtuals and is registered by this mod (manage/virtual.lua).

---comment
---@param typed_name TypedName
---@return LuaItemPrototype | LuaFluidPrototype | VirtualMaterial
function M.typed_name_to_material(typed_name)
    local type = typed_name.type
    local name = typed_name.name
    if type == "item" then
        return prototypes.item[name] or prototypes.item["item-unknown"]
    elseif type == "fluid" then
        return prototypes.fluid[name] or prototypes.fluid["fluid-unknown"]
    elseif type == "virtual_material" then
        return storage.virtuals.material[name] or storage.virtuals.material["<material-unknown>"]
    else
        return storage.virtuals.material["<material-unknown>"]
    end
end

---comment
---@param typed_name TypedName
---@return LuaRecipePrototype | VirtualRecipe
function M.typed_name_to_recipe(typed_name)
    local type = typed_name.type
    local name = typed_name.name
    if type == "recipe" then
        return prototypes.recipe[name] or prototypes.recipe["recipe-unknown"]
    elseif type == "virtual_recipe" then
        return storage.virtuals.recipe[name] or prototypes.recipe["recipe-unknown"]
    else
        return prototypes.recipe["recipe-unknown"]
    end
end

---comment
---@param typed_name TypedName
---@return LuaEntityPrototype
function M.typed_name_to_machine(typed_name)
    local type = typed_name.type
    local name = typed_name.name
    if type == "machine" then
        return prototypes.entity[name] or prototypes.entity["entity-unknown"]
    else
        return prototypes.entity["entity-unknown"]
    end
end

---comment
---@param name string?
---@return LuaItemPrototype?
function M.get_module(name)
    if not name then
        return nil
    end

    local module = prototypes.item[name]
    if not module then
        return nil
    elseif module.type ~= "module" then
        return nil
    else
        return module
    end
end

---comment
---@param name string?
---@return LuaEntityPrototype?
function M.get_beacon(name)
    if not name then
        return nil
    end

    local beacon = prototypes.entity[name]
    if not beacon then
        return nil
    elseif beacon.type ~= "beacon" then
        return nil
    else
        return beacon
    end
end

---comment
---@param craft Craft
---@return TypedName
function M.craft_to_typed_name(craft)
    ---@diagnostic disable: param-type-mismatch
    if craft.object_name == "LuaItemPrototype" then
        return M.create_typed_name("item", craft.name)
    elseif craft.object_name == "LuaFluidPrototype" then
        return M.create_typed_name("fluid", craft.name)
    elseif craft.object_name == "LuaRecipe" then
        return M.create_typed_name("recipe", craft.name)
    elseif craft.object_name == "LuaRecipePrototype" then
        return M.create_typed_name("recipe", craft.name)
    elseif craft.object_name == "LuaEntityPrototype" then
        return M.create_typed_name("machine", craft.name)
    else
        return M.create_typed_name(craft.type, craft.name)
    end
    ---@diagnostic enable: param-type-mismatch
end

---comment
---@param typed_name TypedName
---@return string
function M.get_sprite_path(typed_name)
    if not M.validate_typed_name(typed_name) then
        return "utility/questionmark"
    end

    if typed_name.type == "virtual_material" then
        local material = storage.virtuals.material[typed_name.name]
        return material.sprite_path
    elseif typed_name.type == "virtual_recipe" then
        local recipe = storage.virtuals.recipe[typed_name.name]
        return recipe.sprite_path
    elseif typed_name.type == "machine" then
        return string.format("entity/%s", typed_name.name)
    else
        return string.format("%s/%s", typed_name.type, typed_name.name)
    end
end

return M
