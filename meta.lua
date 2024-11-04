---@meta

---@alias FilterType "item"|"fluid"|"recipe"|"machine"|"virtual_material"|"virtual_recipe"|"virtual_machine"
---@alias LimitType "upper"|"lower"|"equal"
---@alias TimeScale "second"|"five_seconds"|"minute"|"ten_minutes"|"hour"|"ten_hours"|"fifty_hours"|"two_hundred_fifty_hours"|"thousand_hours"
---@alias AmountUnit "time"|"belt"|"storage"
---@alias EnergyType "electric"|"burner"|"heat"|"fluid"|"void"
---@alias SolverState integer|"ready"|"finished"|"unfinished"|"unbounded"|"unfeasible"
---@alias Craft LuaItemPrototype | LuaFluidPrototype | LuaRecipePrototype | LuaEntityPrototype | VirtualMaterial | VirtualRecipe | VirtualMachine
---@alias TypedName { type: FilterType, name: string, quality: string }

---@class EventDataTrait
---@field element LuaGuiElement
---@field mod_name string?
---@field name string | defines.events
---@field player_index integer
---@field tick integer
local EventDataTrait = {}

---@class Storage
---@field players table<integer, PlayerLocalData>
---@field forces table<integer, ForceLocalData>
---@field virtuals Virtuals
__factory_solver__storage = {}

---@class PlayerLocalData
---@field selected_solution string
---@field selected_filter_type FilterType
---@field selected_filter_group table<FilterType, string>
---@field unresearched_craft_visible boolean
---@field hidden_craft_visible boolean
---@field time_scale TimeScale
---@field amount_unit AmountUnit
---@field fuel_presets table<string, TypedName>
---@field machine_presets table<string, TypedName>
---@field opened_gui string[]
local PlayerLocalData = {}

---@class ForceLocalData
---@field relation_to_recipes RelationToRecipes
---@field relation_to_recipes_needs_updating boolean
---@field group_infos GroupInfos
---@field group_infos_needs_updating boolean
---@field solutions table<string, Solution>
local ForceLocalData = {}

---@class RelationToRecipes
---@field enabled_recipe table<string, boolean>
---@field item table<string, RelationToRecipe>
---@field fluid table<string, RelationToRecipe>
---@field virtual_recipe table<string, RelationToRecipe>
local RelationToRecipes = {}

---@class RelationToRecipe
---@field enabled_recipe_used_count integer
---@field recipe_for_product string[]
---@field recipe_for_ingredient string[]
local RelationToRecipe = {}

---@class GroupInfos
---@field item table<string, GroupInfo>
---@field fluid table<string, GroupInfo>
---@field recipe table<string, GroupInfo>
---@field virtual_recipe table<string, GroupInfo>
local GroupInfos = {}

---@class GroupInfo
---@field hidden_count integer
---@field unresearched_count integer
---@field researched_count integer
local GroupInfo = {}

---@class Solution
---@field name string
---@field constraints Constraint[]
---@field production_lines ProductionLine[]
---@field quantity_of_machines_required table<string, number>
---@field problem Problem?
---@field solver_state SolverState
---@field raw_variables PackedVariables?
local Solution = {}

---@class Constraint
---@field type FilterType
---@field name string
---@field limit_type LimitType
---@field limit_amount_per_second number
local Constraint = {}

---@class ProductionLine
---@field recipe_typed_name TypedName
---@field machine_typed_name TypedName
---@field module_typed_names table<string, TypedName>
---@field affected_by_beacons AffectedByBeacon[]
---@field fuel_typed_name TypedName?
local ProductionLine = {}

---@class AffectedByBeacon
---@field beacon_typed_name TypedName?
---@field beacon_quantity integer
---@field module_typed_names table<string, TypedName>
local AffectedByBeacons = {}

---@class PackedVariables
---@field x table<string, number>
---@field y table<string, number>
---@field s table<string, number>
local PackedVariables = {}

---@class NormalizedProductionLine
---@field recipe_typed_name TypedName
---@field products NormalizedAmount[]
---@field ingredients NormalizedAmount[]
---@field power_per_second number
---@field pollution_per_second number
local NormalizedProductionLine

---@class NormalizedAmount
---@field type FilterType
---@field name string
---@field amount_per_second number
local NormalizedAmount = {}

---@class Virtuals
---@field material table<string, VirtualMaterial>
---@field recipe table<string, VirtualRecipe>
---@field machine table<string, VirtualMachine>
---@field crafting_categories { [string]: boolean }
local Virtuals = {}

---@class VirtualMaterial
---@field type "virtual_material"
---@field name string
---@field localised_name LocalisedString
---@field sprite_path string
---@field order string
---@field group_name string
---@field subgroup_name string
local VirtualMaterial = {}

---@class VirtualRecipe
---@field type "virtual_recipe"
---@field name string
---@field localised_name LocalisedString
---@field sprite_path string
---@field order string
---@field group_name string
---@field subgroup_name string
---@field energy number
---@field products NormalizedAmount[]
---@field ingredients NormalizedAmount[]
---@field fixed_crafting_machine TypedName?
---@field resource_category string?
local VirtualRecipe = {}

---@class VirtualMachine
---@field type "virtual_machine"
---@field name string
---@field localised_name LocalisedString
---@field sprite_path string
---@field module_inventory_size integer
---@field crafting_speed number
---@field energy_source EnergySource
---@field crafting_categories { [string]: boolean }
local VirtualMachine = {}

---@class EnergySource
---@field type EnergyType
---@field is_generator boolean
---@field power_per_second number
---@field pollution_per_second number
---@field fuel_categories { [string]: boolean }?
---@field fixed_fuel_typed_name TypedName?
---@field alternative_fuel_value number?