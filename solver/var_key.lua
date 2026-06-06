local tn = require "manage/typed_name"

-- Central place that builds and parses LP variable-key strings.
--
-- LP variables are content-addressed by name: independent loops build the same
-- string and collide by value onto one variable (no registry, no allocation).
-- The string representation is therefore load-bearing and intentionally kept --
-- integer interning was rejected (warm-start carries packed string keys across
-- Problem rebuilds and save/load, and the per-build .index would shuffle).
--
-- This module does NOT change the representation: every constructor returns the
-- exact byte string the old inline concatenations produced. It only removes the
-- scatter -- one definition per prefix, and construction paired with its parse
-- inverse so a future row-folding optimisation has a single place to update.
--
-- Reserved characters: the key namespace uses | % / @ < > as delimiters and
-- markers. Prototype names are assumed never to contain them; this is unchecked
-- (a collision-check assert belongs at the typed-name / pre_solve boundary, not
-- here -- see open_work_index).

-- Prefix literals (defined exactly once).
local LIMIT = "|limit|"
local SURPLUS_SINK = "|surplus_sink|"
local SHORTAGE_SOURCE = "|shortage_source|"
local FINAL_SINK = "|final_sink|"
local INITIAL_SOURCE = "|initial_source|"
local ELASTIC = "|elastic|"
local BRIDGE = "|bridge|"
local POS_SLACK = "%positive_slack%"
local NEG_SLACK = "%negative_slack%"
-- A bare |elastic| sits on a |limit| dual, so the composite a constraint
-- relaxation carries is |elastic||limit|<material>.
local ELASTIC_LIMIT = ELASTIC .. LIMIT
-- Recipe-prototype-name markers (NOT LP key prefixes): manage/virtual.lua writes
-- these into the virtual_recipe's `name` field, so they are matched against
-- recipe_typed_name.name, not against the LP variable name.
local SOURCE_RECIPE = "<source>"
local SINK_RECIPE = "<sink>"
-- Material-kind discriminators for source-cost tiering.
local HEAT_MATERIAL = "virtual_material/<heat>/"
local FLUID_MATERIAL = "fluid/"

local M = {}

--------------------------------------------------------------------------------
-- Construction. Every function returns the same bytes as the former inline
-- concatenation; callers must route all key building through here.
--------------------------------------------------------------------------------

---The base material/recipe variable key ("type/name/quality", or
---"fluid/name@[lo,hi]" for temperature-carrying fluids).
---@param typed_name TypedName
---@return string
function M.material(typed_name)
    return tn.typed_name_to_variable_name(typed_name)
end

---@param key string base material variable key
---@return string
function M.limit(key) return LIMIT .. key end

---@param key string base material variable key
---@return string
function M.surplus_sink(key) return SURPLUS_SINK .. key end

---@param key string base material variable key
---@return string
function M.final_sink(key) return FINAL_SINK .. key end

---@param key string base material variable key
---@return string
function M.initial_source(key) return INITIAL_SOURCE .. key end

---@param key string base material variable key
---@return string
function M.shortage_source(key) return SHORTAGE_SOURCE .. key end

---@param key string a dual/limit key the constraint relaxation rides on
---@return string
function M.elastic(key) return ELASTIC .. key end

---@param material string base material variable key
---@return string
function M.elastic_limit(material) return ELASTIC_LIMIT .. material end

---The bridge virtual-recipe prototype name converting one fluid temperature
---range into a wider accepted one (see create_problem.create_temperature_bridges).
---@param fluid string
---@param pmin number
---@param pmax number
---@param imin number
---@param imax number
---@return string
function M.bridge(fluid, pmin, pmax, imin, imax)
    return string.format("%sfluid/%s@[%g,%g]->[%g,%g]", BRIDGE, fluid, pmin, pmax, imin, imax)
end

---@param dual_variable string
---@return string
function M.pos_slack(dual_variable) return POS_SLACK .. dual_variable end

---@param dual_variable string
---@return string
function M.neg_slack(dual_variable) return NEG_SLACK .. dual_variable end

--------------------------------------------------------------------------------
-- Parse / predicates. Inverses live beside their constructors so the prefix
-- literals are shared.
--------------------------------------------------------------------------------

---True for a |bridge| variable (LP-internal temperature plumbing). The marker
---appears after the "virtual_recipe/" segment, so match by find, not prefix.
---@param key string
---@return boolean
function M.is_bridge(key)
    return string.find(key, BRIDGE, 1, true) ~= nil
end

---True for a real / virtual recipe variable, excluding |bridge| plumbing.
---@param key string an LP variable key
---@return boolean
function M.is_recipe(key)
    if M.is_bridge(key) then return false end
    return string.sub(key, 1, 7) == "recipe/" or string.sub(key, 1, 15) == "virtual_recipe/"
end

---True when a recipe PROTOTYPE NAME (recipe_typed_name.name, not the LP key) is
---a user-placed infinite-source virtual recipe.
---@param recipe_name string
---@return boolean
function M.is_source_recipe_name(recipe_name)
    return string.sub(recipe_name, 1, #SOURCE_RECIPE) == SOURCE_RECIPE
end

---True when a recipe PROTOTYPE NAME is an infinite-sink virtual recipe.
---@param recipe_name string
---@return boolean
function M.is_sink_recipe_name(recipe_name)
    return string.sub(recipe_name, 1, #SINK_RECIPE) == SINK_RECIPE
end

---Map a temperature-carrying fluid variable to the bare-fluid aggregation
---|limit| dual ("fluid/steam@[165,165]" -> "|limit|fluid/steam"). Returns nil
---for non-fluids and for already-bare fluid names (no aggregation to do).
---@param variable_name string
---@return string?
function M.bare_fluid_limit(variable_name)
    if string.sub(variable_name, 1, #FLUID_MATERIAL) ~= FLUID_MATERIAL then
        return nil
    end
    local at = string.find(variable_name, "@", #FLUID_MATERIAL + 1, true)
    if not at then
        return nil
    end
    return LIMIT .. string.sub(variable_name, 1, at - 1)
end

---Strip the |shortage_source| prefix back to the bare material key, or nil.
---@param key string
---@return string?
function M.strip_shortage(key)
    if string.sub(key, 1, #SHORTAGE_SOURCE) == SHORTAGE_SOURCE then
        return string.sub(key, #SHORTAGE_SOURCE + 1)
    end
    return nil
end

---Strip the |elastic||limit| prefix back to the bare material key, or nil. A
---bare |elastic|<dual> without a |limit| body is a constraint relaxation that
---maps to no single material and is intentionally not matched here.
---@param key string
---@return string?
function M.strip_elastic_limit(key)
    if string.sub(key, 1, #ELASTIC_LIMIT) == ELASTIC_LIMIT then
        return string.sub(key, #ELASTIC_LIMIT + 1)
    end
    return nil
end

---Source-cost tier of a material variable: heat / fluid / everything else.
---The cost VALUES stay in create_problem; this only classifies the string.
---@param variable_name string
---@return "heat"|"fluid"|"item"
function M.source_cost_kind(variable_name)
    if string.sub(variable_name, 1, #HEAT_MATERIAL) == HEAT_MATERIAL then
        return "heat"
    elseif string.sub(variable_name, 1, #FLUID_MATERIAL) == FLUID_MATERIAL then
        return "fluid"
    else
        return "item"
    end
end

---@param key string
---@return boolean
function M.has_shortage(key) return string.find(key, SHORTAGE_SOURCE, 1, true) ~= nil end

---@param key string
---@return boolean
function M.has_elastic(key) return string.find(key, ELASTIC, 1, true) ~= nil end

---@param key string
---@return boolean
function M.has_initial(key) return string.find(key, INITIAL_SOURCE, 1, true) ~= nil end

---@param key string
---@return boolean
function M.has_final(key) return string.find(key, FINAL_SINK, 1, true) ~= nil end

return M
