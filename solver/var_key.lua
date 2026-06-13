local tn = require "manage/typed_name"

-- Central place that builds LP variable-key strings.
--
-- LP variables are content-addressed by name: independent loops build the same
-- string and collide by value onto one variable (no registry, no allocation).
-- The string representation is therefore load-bearing and intentionally kept --
-- integer interning was rejected (warm-start carries packed string keys across
-- Problem rebuilds and save/load, and the per-build .index would shuffle).
--
-- This module does NOT change the representation: every constructor returns the
-- exact byte string the old inline concatenations produced. It only removes the
-- scatter -- one definition per prefix. Building keys is the ONLY job here:
-- reading the solution back is not done by parsing these strings. Solution
-- readers classify a variable by its Primal.kind metadata and a production line
-- by its is_source / is_bridge / is_sink flags, so no prefix is ever sliced off
-- a key to recover what it means.
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
local TARGET_BUDGET = "|target_budget|"
-- Cascade staged-rescue rows (see solver/cascade.lua): one budget dual per
-- locked tier, and the synthetic demand probe / its dual the producibility /
-- consumability fix tests inject.
local CASCADE_BUDGET = "|cascade_budget|"
local CASCADE_PROBE = "|cascade_probe|"
local CASCADE_DEMAND = "|cascade_demand|"
-- A bare |elastic| sits on a |limit| dual, so the composite a constraint
-- relaxation carries is |elastic||limit|<material>.
local ELASTIC_LIMIT = ELASTIC .. LIMIT

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

---The single dual row capping the summed target elastics (the target-rescue
---lock; see create_problem's target_budget option).
---@return string
function M.target_budget() return TARGET_BUDGET end

---The dual row capping a cascade tier's summed escapes (the Vp / Vf / Vc
---budget locks; see solver/cascade.lua). One per tier so a build can carry
---several locks at once.
---@param tier string "vp" | "vf" | "vc"
---@return string
function M.cascade_budget(tier) return CASCADE_BUDGET .. tier end

---The free objective variable a cascade fix test forces one unit of demand
---through (sign picks the producibility / consumability mirror).
---@param material string base material variable key
---@return string
function M.cascade_probe(material) return CASCADE_PROBE .. material end

---The lower-limit dual that holds a cascade fix test's probe at one unit.
---@param material string base material variable key
---@return string
function M.cascade_demand(material) return CASCADE_DEMAND .. material end

---@param dual_variable string
---@return string
function M.pos_slack(dual_variable) return POS_SLACK .. dual_variable end

---@param dual_variable string
---@return string
function M.neg_slack(dual_variable) return NEG_SLACK .. dual_variable end

return M
