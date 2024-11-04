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
    ["recipe"] = "recipe-with-quality",
    ["machine"] = "entity-with-quality",
}

---comment
---@param typed_name TypedName
---@return ElemID?
function M.typed_name_to_elem_id(typed_name)
    local elem_type = type_dictionary[typed_name.type]
    if elem_type and M.validate_typed_name(typed_name) then
        return { type = elem_type, name = typed_name.name, quality = typed_name.quality }
    else
        return nil
    end
end

---comment
---@param filter_type FilterType | "research-progress"
---@param name string
---@param quality string?
---@return TypedName
function M.create_typed_name(filter_type, name, quality)
    quality = quality or "normal"
    if filter_type == "research-progress" then
        filter_type = "virtual_material"
    end
    return { type = filter_type, name = name, quality = quality }
end

---comment
---@param value1 TypedName
---@param value2 TypedName
---@return boolean
function M.equals_typed_name(value1, value2)
    return value1.type == value2.type and value1.name == value2.name
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
    elseif type == "virtual_machine" then
        return storage.virtuals.machine[name] ~= nil
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
    elseif type == "virtual-machine" then
        type = "virtual_machine"
    end

    if not quality then
        quality = "normal"
    end

    typed_name.type = type
    typed_name.name = name
    typed_name.quality = quality
end

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
        return prototypes.entity[name] or prototypes.entity["<entity-unknown>"]
    else
        return prototypes.entity["<entity-unknown>"]
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
    elseif typed_name.type == "virtual_machine" then
        local machine = storage.virtuals.machine[typed_name.name]
        return machine.sprite_path
    elseif typed_name.type == "machine" then
        return "entity" .. "/" .. typed_name.name
    else
        return typed_name.type .. "/" .. typed_name.name
    end
end

return M
