-- Real chain-explorer captures (pyanodon, all tech) where the user CONSTRAINS a
-- raw / intermediate material rather than a final product -- a path the rest of
-- the suite barely exercises (most fixtures pin a terminal output). Captured
-- verbatim from the in-game create_problem dumps (dump_constraints /
-- dump_normalized_lines) over a full chain-explorer sweep (netneg / trapdown
-- configs aim the Constraint at a net-negative or trapped material deep in the
-- chain). Each pins one item with `equal = 1`.
--
-- Three groups, so a future improvement is DETECTABLE by which xfails flip:
--
--   SUCCESS -- the solver meets the pinned intermediate by importing the chain's
--   raws and shipping the by-products. Guards that the constrained-material path
--   (the produced+consumed branch, its surplus_sink, the per-material final_sink
--   a pinned material gets) keeps working on real topologies.
--
--   AVOIDABLE cheat (xfail) -- the cycle CAN net-produce the pinned material
--   (material_cycles.export_feasible is true) but the LP found fabrication
--   cheaper, so it cheats via |shortage_source| / |elastic| on a single solve.
--   The diagnose-then-reclassify two-pass closes these with NO prototype signal;
--   when it lands these XPASS.
--
--   UNAVOIDABLE cheat (xfail) -- no recipe flow yields the pinned material (a
--   pyanodon base resource trapped in a mass-losing loop, or a dead-end). The
--   pure LP cannot tell an importable base resource from a fabricated dead-end;
--   these need the base-resource import signal (the prototype layer declaring
--   the material suppliable) and flip only once that lands.
--
-- All cheat amounts are reproduced from the headless solve at capture time.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

-- cheat = shortage + elastic; ships = some final_sink active; imports = some
-- initial_source active.
local function classify(vars)
    local cheat, ships, imports = 0, false, false
    for k, v in pairs(vars.x) do
        if math.abs(v) > 1e-6 then
            if k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true) then
                cheat = cheat + math.abs(v)
            elseif k:find("|final_sink|", 1, true) then ships = true
            elseif k:find("|initial_source|", 1, true) then imports = true end
        end
    end
    return cheat, ships, imports
end

local cases = {}

local constraints_sodium_sulfate = {
  { type = "item", name = "sodium-sulfate", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_sodium_sulfate = {
  {
    recipe_typed_name = { type = "recipe", name = "u236-u237", quality = "normal" },
    products = {
      { type = "item", name = "u-236", quality = "normal", amount_per_second = 19.98 },
      { type = "item", name = "u-237", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "u-236", quality = "normal", amount_per_second = 20 },
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 20, minimum_temperature = 0, maximum_temperature = 5000 },
    },
    power_per_second = 1033333333.3333333,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "uranium-seperation", quality = "normal" },
    products = {
      { type = "item", name = "u-232", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "u-233", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "u-234", quality = "normal", amount_per_second = 0.0125 },
      { type = "item", name = "u-235", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "u-236", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "u-237", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "u-238", quality = "normal", amount_per_second = 0.475 },
    },
    ingredients = {
      { type = "item", name = "uranium-oxide", quality = "normal", amount_per_second = 0.5 },
    },
    power_per_second = 1033333333.3333333,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fuel-cell-mk04-dissolve", quality = "normal" },
    products = {
      { type = "item", name = "u-236", quality = "normal", amount_per_second = 2 },
    },
    ingredients = {
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "used-up-uranium-fuel-cell-mk04", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 25, maximum_temperature = 25 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sulfuric-acid-01", quality = "normal" },
    products = {
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 12.5, minimum_temperature = 25, maximum_temperature = 25 },
    },
    ingredients = {
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 217000,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sodium-sulfate-1", quality = "normal" },
    products = {
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 12.5, minimum_temperature = 25, maximum_temperature = 25 },
    },
    power_per_second = 217000,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "thermal-neutron", quality = "normal" },
    products = {
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 10, minimum_temperature = 1000, maximum_temperature = 1000 },
    },
    ingredients = {
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 10, minimum_temperature = 0, maximum_temperature = 5000 },
    },
    fuel_ingredient = { type = "item", name = "control-rod", quality = "normal", amount_per_second = 0.04 },
    fuel_burnt_result = { type = "item", name = "used-control-rod", quality = "normal", amount_per_second = 0.04 },
    power_per_second = 0,
    pollution_per_second = 0,
  },
  {
    recipe_typed_name = { type = "recipe", name = "chlorine", quality = "normal" },
    products = {
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "chlorine", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "water-saline", quality = "normal", amount_per_second = 50, minimum_temperature = 25, maximum_temperature = 100 },
    },
    power_per_second = 10333333.333333334,
    pollution_per_second = 0.001,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sulfur-void-water", quality = "normal" },
    products = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "sulfur", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "py-sodium-hydroxide", quality = "normal" },
    products = {
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.83333333333333339 },
    },
    ingredients = {
      { type = "item", name = "salt", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 8.3333333333333339, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 217000,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "u232-u233", quality = "normal" },
    products = {
      { type = "item", name = "u-233", quality = "normal", amount_per_second = 0.99900000000000002 },
    },
    ingredients = {
      { type = "item", name = "u-232", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 4, minimum_temperature = 0, maximum_temperature = 5000 },
    },
    power_per_second = 1033333333.3333333,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sulfuric-petgas", quality = "normal" },
    products = {
      { type = "fluid", name = "aromatics", quality = "normal", amount_per_second = 10.526315789473685, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 210.52631578947367, minimum_temperature = 150, maximum_temperature = 150 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 52.631578947368418, minimum_temperature = 25, maximum_temperature = 25 },
    },
    ingredients = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 0.52631578947368416 },
      { type = "fluid", name = "petroleum-gas", quality = "normal", amount_per_second = 26.315789473684209, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 210.52631578947367, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 15.789473684210526, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "acidgas-2", quality = "normal" },
    products = {
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 15, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 300, minimum_temperature = 150, maximum_temperature = 150 },
    },
    ingredients = {
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 1000, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 300, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "gasoline", quality = "normal", amount_per_second = 2.5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "deuterium-fusion", quality = "normal" },
    products = {
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 1250, minimum_temperature = 2000, maximum_temperature = 2000 },
      { type = "fluid", name = "helium", quality = "normal", amount_per_second = 37.5, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "tritium", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "helium3", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "deuterium", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "pressured-water", quality = "normal", amount_per_second = 2500, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "liquid-helium", quality = "normal", amount_per_second = 7.5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 5166666666.666666,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dt-he3", quality = "normal" },
    products = {
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 3750, minimum_temperature = 3000, maximum_temperature = 3000 },
      { type = "fluid", name = "helium", quality = "normal", amount_per_second = 87.5, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "proton", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "deuterium", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "helium3", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "liquid-helium", quality = "normal", amount_per_second = 17.5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 41333333333.333328,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fiberboard-3", quality = "normal" },
    products = {
      { type = "item", name = "fiberboard", quality = "normal", amount_per_second = 2.3999999999999999 },
    },
    ingredients = {
      { type = "item", name = "treated-wood", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "fiber", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 100, minimum_temperature = 15, maximum_temperature = 2000 },
      { type = "fluid", name = "anthraquinone", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 155000,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "u234-u235", quality = "normal" },
    products = {
      { type = "item", name = "u-235", quality = "normal", amount_per_second = 15.984 },
    },
    ingredients = {
      { type = "item", name = "u-234", quality = "normal", amount_per_second = 20 },
      { type = "fluid", name = "neutron", quality = "normal", amount_per_second = 40, minimum_temperature = 0, maximum_temperature = 5000 },
    },
    power_per_second = 1033333333.3333333,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fiberboard-mk02", quality = "normal" },
    products = {
      { type = "item", name = "fiberboard", quality = "normal", amount_per_second = 1.6000000000000001 },
    },
    ingredients = {
      { type = "item", name = "treated-wood", quality = "normal", amount_per_second = 0.6 },
      { type = "item", name = "raw-fiber", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 100, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    power_per_second = 155000,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "oleo-heavy", quality = "normal" },
    products = {
      { type = "item", name = "sulfur", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "fluid", name = "heavy-oil", quality = "normal", amount_per_second = 50, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 166.66666666666666, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 66.666666666666671, minimum_temperature = 25, maximum_temperature = 25 },
    },
    power_per_second = 930000,
    pollution_per_second = 0.016666666666666665,
  },
}

local constraints_yotoi_leaves = {
  { type = "item", name = "yotoi-leaves", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_yotoi_leaves = {
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-gmo-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 1.9877675840978593e-05 },
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 0.0019877675840978597 },
    },
    ingredients = {
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.019877675840978593 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.0079510703363914388 },
      { type = "item", name = "geostabilization-tissue", quality = "normal", amount_per_second = 0.0039755351681957194 },
      { type = "item", name = "yotoi-mk03", quality = "normal", amount_per_second = 0.015902140672782878 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 1.1926605504587156, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "simik-blood", quality = "normal", amount_per_second = 0.3975535168195719, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cysteine", quality = "normal" },
    products = {
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "fur", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.08 },
      { type = "fluid", name = "bacteria-2", quality = "normal", amount_per_second = 4, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 4, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-seeds-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-seeds-mk04", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 1.6666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.16666666666666665 },
    },
    ingredients = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "liquid-helium", quality = "normal", amount_per_second = 0.3333333333333333, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-simik", quality = "normal" },
    products = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "simik-blood", quality = "normal", amount_per_second = 2.6666666666666665, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-simik", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "pelt-processing", quality = "normal" },
    products = {
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "fur", quality = "normal", amount_per_second = 0.5 },
    },
    ingredients = {
      { type = "item", name = "pelt", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "sodium-aluminate", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "salt", quality = "normal", amount_per_second = 0.5 },
      { type = "fluid", name = "soda-ash", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.0079510703363914388 },
    },
    ingredients = {
      { type = "item", name = "pure-sand", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.0079510703363914388 },
      { type = "item", name = "yotoi-seeds-mk04", quality = "normal", amount_per_second = 0.019877675840978593 },
      { type = "item", name = "ag-biomass", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "item", name = "nacl-biomass", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "fluid", name = "liquid-manure", quality = "normal", amount_per_second = 0.2782874617737003, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-liquid-nitrogen-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "liquid-nitrogen-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "denatured-seismite-2", quality = "normal" },
    products = {
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bio-sample01", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "lithium", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "lithium-hydroxide", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "hyaline", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "nanofibrils", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "zymogens", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "dhilmos-egg", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "xeno-egg", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "cottongut", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "formic-acid", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "liquid-nitrogen", quality = "normal" },
    products = {
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 333.33333333333337, minimum_temperature = 150, maximum_temperature = 150 },
    },
    ingredients = {
      { type = "fluid", name = "nitrogen", quality = "normal", amount_per_second = 166.66666666666669, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 333.33333333333337, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "gasoline", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dedicated-oleochemicals", quality = "normal" },
    products = {
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 150, maximum_temperature = 150 },
    },
    ingredients = {
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cage-recycle-into-titanium", quality = "normal" },
    products = {
      { type = "item", name = "iron-stick", quality = "normal", amount_per_second = 0.9375 },
      { type = "item", name = "solder", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 0.3125 },
    },
    ingredients = {
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.25 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "antiviral", quality = "normal" },
    products = {
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "nanocarrier", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.06 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "mmp", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.04 },
      { type = "fluid", name = "zogna-bacteria", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 0.1, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "biomass-yotoi-mk04", quality = "normal" },
    products = {
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 15 },
    },
    ingredients = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.3333333333333333 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "liquid-nitrogen-barrel", quality = "normal" },
    products = {
      { type = "item", name = "liquid-nitrogen-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "antiviral-02", quality = "normal" },
    products = {
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.14000000000000002 },
    },
    ingredients = {
      { type = "item", name = "nanocarrier", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "solidified-sarcorus", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.06 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "mmp", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.04 },
      { type = "fluid", name = "zogna-bacteria", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 0.1, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cage", quality = "normal" },
    products = {
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.25 },
    },
    ingredients = {
      { type = "item", name = "iron-stick", quality = "normal", amount_per_second = 3.75 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 1.25 },
      { type = "item", name = "solder", quality = "normal", amount_per_second = 0.5 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-scafold-4", quality = "normal" },
    products = {
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.75 },
    },
    ingredients = {
      { type = "item", name = "nanofibrils", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "sodium-alginate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "boric-acid", quality = "normal", amount_per_second = 50, minimum_temperature = 0, maximum_temperature = 10 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
}

local constraints_biomass = {
  { type = "item", name = "biomass", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_biomass = {
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-gmo-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 1.9877675840978593e-05 },
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 0.0019877675840978597 },
    },
    ingredients = {
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.019877675840978593 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.0079510703363914388 },
      { type = "item", name = "geostabilization-tissue", quality = "normal", amount_per_second = 0.0039755351681957194 },
      { type = "item", name = "yotoi-mk03", quality = "normal", amount_per_second = 0.015902140672782878 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 1.1926605504587156, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "simik-blood", quality = "normal", amount_per_second = 0.3975535168195719, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cysteine", quality = "normal" },
    products = {
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "fur", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.08 },
      { type = "fluid", name = "bacteria-2", quality = "normal", amount_per_second = 4, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 4, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-seeds-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-seeds-mk04", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 1.6666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit-mk04", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.16666666666666665 },
    },
    ingredients = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "liquid-helium", quality = "normal", amount_per_second = 0.3333333333333333, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-simik", quality = "normal" },
    products = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "simik-blood", quality = "normal", amount_per_second = 2.6666666666666665, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-simik", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "pelt-processing", quality = "normal" },
    products = {
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "fur", quality = "normal", amount_per_second = 0.5 },
    },
    ingredients = {
      { type = "item", name = "pelt", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "sodium-aluminate", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "salt", quality = "normal", amount_per_second = 0.5 },
      { type = "fluid", name = "soda-ash", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-mk04", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.0079510703363914388 },
    },
    ingredients = {
      { type = "item", name = "pure-sand", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.0079510703363914388 },
      { type = "item", name = "yotoi-seeds-mk04", quality = "normal", amount_per_second = 0.019877675840978593 },
      { type = "item", name = "ag-biomass", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "item", name = "nacl-biomass", quality = "normal", amount_per_second = 0.039755351681957185 },
      { type = "fluid", name = "liquid-manure", quality = "normal", amount_per_second = 0.2782874617737003, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-liquid-nitrogen-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "liquid-nitrogen-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "denatured-seismite-2", quality = "normal" },
    products = {
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bio-sample01", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "lithium", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "lithium-hydroxide", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "hyaline", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "nanofibrils", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "zymogens", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "dhilmos-egg", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "xeno-egg", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "cottongut", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "formic-acid", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "liquid-nitrogen", quality = "normal" },
    products = {
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 333.33333333333337, minimum_temperature = 150, maximum_temperature = 150 },
    },
    ingredients = {
      { type = "fluid", name = "nitrogen", quality = "normal", amount_per_second = 166.66666666666669, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 333.33333333333337, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "gasoline", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dedicated-oleochemicals", quality = "normal" },
    products = {
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 150, maximum_temperature = 150 },
    },
    ingredients = {
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cage-recycle-into-titanium", quality = "normal" },
    products = {
      { type = "item", name = "iron-stick", quality = "normal", amount_per_second = 0.9375 },
      { type = "item", name = "solder", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 0.3125 },
    },
    ingredients = {
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.25 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "antiviral", quality = "normal" },
    products = {
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "nanocarrier", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.06 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "mmp", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.04 },
      { type = "fluid", name = "zogna-bacteria", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 0.1, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "biomass-yotoi-mk04", quality = "normal" },
    products = {
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 15 },
    },
    ingredients = {
      { type = "item", name = "yotoi-mk04", quality = "normal", amount_per_second = 0.3333333333333333 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "liquid-nitrogen-barrel", quality = "normal" },
    products = {
      { type = "item", name = "liquid-nitrogen-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "liquid-nitrogen", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "antiviral-02", quality = "normal" },
    products = {
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.14000000000000002 },
    },
    ingredients = {
      { type = "item", name = "nanocarrier", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "solidified-sarcorus", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.06 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "mmp", quality = "normal", amount_per_second = 0.002 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.04 },
      { type = "fluid", name = "zogna-bacteria", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 0.1, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cage", quality = "normal" },
    products = {
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.25 },
    },
    ingredients = {
      { type = "item", name = "iron-stick", quality = "normal", amount_per_second = 3.75 },
      { type = "item", name = "titanium-plate", quality = "normal", amount_per_second = 1.25 },
      { type = "item", name = "solder", quality = "normal", amount_per_second = 0.5 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-scafold-4", quality = "normal" },
    products = {
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.75 },
    },
    ingredients = {
      { type = "item", name = "nanofibrils", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "sodium-alginate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "boric-acid", quality = "normal", amount_per_second = 50, minimum_temperature = 0, maximum_temperature = 10 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
}

local constraints_guar_seeds_mk03 = {
  { type = "item", name = "guar-seeds-mk03", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_guar_seeds_mk03 = {
  {
    recipe_typed_name = { type = "recipe", name = "guar-mk04-breeder", quality = "normal" },
    products = {
      { type = "item", name = "guar-mk04", quality = "normal", amount_per_second = 0.0036764705882352944 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.0022058823529411766 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "sternite-lung", quality = "normal", amount_per_second = 0.0014705882352941178 },
      { type = "item", name = "dried-grods", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "guar-seeds-mk04", quality = "normal", amount_per_second = 0.0036764705882352944 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.14705882352941173, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "raw-ralesia-extract", quality = "normal", amount_per_second = 0.07352941176470587, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = -0.58333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "guar-seeds-mk04-breeder", quality = "normal" },
    products = {
      { type = "item", name = "guar-seeds-mk04", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "guar-seeds-mk04", quality = "normal", amount_per_second = 0.04 },
    },
    ingredients = {
      { type = "item", name = "guar-mk04", quality = "normal", amount_per_second = 0.2 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sternite-lung", quality = "normal" },
    products = {
      { type = "item", name = "sternite-lung", quality = "normal", amount_per_second = 0.025 },
    },
    ingredients = {
      { type = "item", name = "guts-arqad", quality = "normal", amount_per_second = 0.025 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "arqad-improve-4", quality = "normal" },
    products = {
      { type = "item", name = "guts-arqad", quality = "normal", amount_per_second = 0.0045454545454545459 },
    },
    ingredients = {
      { type = "item", name = "antitumor", quality = "normal", amount_per_second = 0.0045454545454545459 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0045454545454545459 },
      { type = "item", name = "arqad", quality = "normal", amount_per_second = 0.0045454545454545459 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fertilizer-fish-3", quality = "normal" },
    products = {
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.4 },
    },
    ingredients = {
      { type = "item", name = "fishmeal", quality = "normal", amount_per_second = 2 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "guar-mk04", quality = "normal" },
    products = {
      { type = "item", name = "guar-mk04", quality = "normal", amount_per_second = 5.882352941176471e-06 },
      { type = "item", name = "guar", quality = "normal", amount_per_second = 0.0013725490196078431 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.019607843137254902 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.019607843137254902 },
      { type = "item", name = "zinc-finger-proteins", quality = "normal", amount_per_second = 0.0019607843137254902 },
      { type = "item", name = "guar-mk03", quality = "normal", amount_per_second = 0.0039215686274509803 },
      { type = "item", name = "guar-seeds-mk03", quality = "normal", amount_per_second = 0.019607843137254902 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.5882352941176471, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 1.9607843137254902, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = -0.58333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "biomass-guts-arqad", quality = "normal" },
    products = {
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 1.6666666666666668 },
    },
    ingredients = {
      { type = "item", name = "guts-arqad", quality = "normal", amount_per_second = 0.3333333333333333 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "antitumor-2", quality = "normal" },
    products = {
      { type = "item", name = "antitumor", quality = "normal", amount_per_second = 9.6666666666666661 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 5 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 3.3333333333333335 },
      { type = "item", name = "nonconductive-phazogen", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "item", name = "propeptides", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "dynemicin", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "enediyne", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "superconductor-servomechanims", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "fluid", name = "gta", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "arthropod-blood", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 465000,
    pollution_per_second = 0.001,
  },
  {
    recipe_typed_name = { type = "recipe", name = "guar-mk03-breeder", quality = "normal" },
    products = {
      { type = "item", name = "guar-mk03", quality = "normal", amount_per_second = 0.0036764705882352944 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.0022058823529411766 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "dried-grods", quality = "normal", amount_per_second = 0.0073529411764705888 },
      { type = "item", name = "guar-seeds-mk03", quality = "normal", amount_per_second = 0.0036764705882352944 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.14705882352941173, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "raw-ralesia-extract", quality = "normal", amount_per_second = 0.07352941176470587, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = -0.58333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "pesticide-mk01", quality = "normal" },
    products = {
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 1.6666666666666668 },
    },
    ingredients = {
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "pre-pesticide-01", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 1.6666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "raw-ralesia-extract", quality = "normal" },
    products = {
      { type = "fluid", name = "raw-ralesia-extract", quality = "normal", amount_per_second = 8.3333333333333339, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "ralesia-powder", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.005333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-arqads", quality = "normal" },
    products = {
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.1 },
      { type = "fluid", name = "arthropod-blood", quality = "normal", amount_per_second = 1.3333333333333333, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 1, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "arqad", quality = "normal", amount_per_second = 0.1 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fertilizer-1", quality = "normal" },
    products = {
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 2 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 4 },
      { type = "item", name = "bones", quality = "normal", amount_per_second = 1.2 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "guar-seeds-mk03-breeder", quality = "normal" },
    products = {
      { type = "item", name = "guar-seeds-mk03", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "guar-seeds-mk03", quality = "normal", amount_per_second = 0.05 },
    },
    ingredients = {
      { type = "item", name = "guar-mk03", quality = "normal", amount_per_second = 0.2 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "arqad-improve-3", quality = "normal" },
    products = {
      { type = "item", name = "guts-arqad", quality = "normal", amount_per_second = 0.0015151515151515149 },
    },
    ingredients = {
      { type = "item", name = "antitumor", quality = "normal", amount_per_second = 0.0015151515151515149 },
      { type = "item", name = "arqad", quality = "normal", amount_per_second = 0.0015151515151515149 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-4", quality = "normal" },
    products = {
      { type = "item", name = "yotoi", quality = "normal", amount_per_second = 0.083486238532110093 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.0059633027522935773 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.014908256880733943 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.017889908256880735 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.023853211009174311 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.029816513761467887 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0029816513761467887 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0029816513761467887 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.029816513761467887 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 0.0029816513761467887 },
      { type = "item", name = "blood-meal", quality = "normal", amount_per_second = 0.014908256880733943 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.29816513761467887, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.29816513761467887, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-3", quality = "normal" },
    products = {
      { type = "item", name = "yotoi", quality = "normal", amount_per_second = 0.034076015727391873 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.0085190039318479691 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.010222804718217562 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.013630406290956751 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.017038007863695936 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0017038007863695938 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.010222804718217562 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 0.0017038007863695938 },
      { type = "item", name = "blood-meal", quality = "normal", amount_per_second = 0.0085190039318479691 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.17038007863695936, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.17038007863695936, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-4", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 0.15504587155963304 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.017889908256880735 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.047706422018348622 },
      { type = "item", name = "gravel", quality = "normal", amount_per_second = 0.059633027522935773 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.029816513761467887 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.023853211009174311 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.035779816513761471 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0059633027522935773 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0059633027522935773 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.059633027522935773 },
      { type = "item", name = "blood-meal", quality = "normal", amount_per_second = 0.011926605504587156 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.59633027522935773, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.35779816513761471, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "steam-heating", quality = "normal" },
    products = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 500, maximum_temperature = 500 },
    },
    ingredients = {
      { type = "item", name = "fuelrod-mk01", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cooling-water", quality = "normal" },
    products = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 400, minimum_temperature = 100, maximum_temperature = 100 },
    },
    ingredients = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 400, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    power_per_second = 0,
    pollution_per_second = 0,
  },
  {
    recipe_typed_name = { type = "recipe", name = "gh-2", quality = "normal" },
    products = {
      { type = "item", name = "gh", quality = "normal", amount_per_second = 1.1428571428571428 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.14285714285714284 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.057142857142857135 },
      { type = "item", name = "solidified-sarcorus", quality = "normal", amount_per_second = 0.14285714285714284 },
      { type = "item", name = "nonconductive-phazogen", quality = "normal", amount_per_second = 0.014285714285714284 },
      { type = "item", name = "petri-dish", quality = "normal", amount_per_second = 0.28571428571428568 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.28571428571428568 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.028571428571428568 },
      { type = "item", name = "plasmids", quality = "normal", amount_per_second = 0.071428571428571423 },
      { type = "item", name = "pineal-gland", quality = "normal", amount_per_second = 0.042857142857142865 },
      { type = "fluid", name = "bacteria-1", quality = "normal", amount_per_second = 2.8571428571428573, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
}

local constraints_scrondrix_mk03 = {
  { type = "item", name = "scrondrix-mk03", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_scrondrix_mk03 = {
  {
    recipe_typed_name = { type = "recipe", name = "zungror-mk03r", quality = "normal" },
    products = {
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.02 },
    },
    ingredients = {
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.032000000000000002 },
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.008 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-codex-mk03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.016000000000000001 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.004 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 9300000,
    pollution_per_second = 0.05,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-artificial-blood-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "artificial-blood-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "compile-zungror-im", quality = "normal" },
    products = {
      { type = "item", name = "zungror-codex-mk03", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    ingredients = {
      { type = "item", name = "neuromorphic-chip", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "zungror-codex-mk02", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 1240000,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "compile-zungror-codex", quality = "normal" },
    products = {
      { type = "item", name = "zungror-codex-mk02", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    ingredients = {
      { type = "item", name = "neuroprocessor", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "zungror-codex", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 1240000,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "format-neuromorphic-chip", quality = "normal" },
    products = {
      { type = "item", name = "neuromorphic-chip", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "empty-neuromorphic-chip", quality = "normal", amount_per_second = 0.1 },
    },
    power_per_second = 1240000,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-neuromorphic-chip", quality = "normal" },
    products = {
      { type = "item", name = "empty-neuromorphic-chip", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "biofilm", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "optical-fiber", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "nexelit-matrix", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "nano-cellulose", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "neuroprocessor", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "melamine", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "bakelite", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "micro-fiber", quality = "normal", amount_per_second = 0.26666666666666665 },
      { type = "item", name = "nylon-parts", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "capacitor2", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "paramagnetic-material", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "fluid", name = "vacuum", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 9300000,
    pollution_per_second = 0.05,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cottongut-science-prod-seeds", quality = "normal" },
    products = {
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "nonconductive-phazogen", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.7 },
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.9 },
      { type = "item", name = "solidified-sarcorus", quality = "normal", amount_per_second = 1.1000000000000001 },
    },
    ingredients = {
      { type = "item", name = "super-alloy", quality = "normal", amount_per_second = 1.5 },
      { type = "item", name = "nano-cellulose", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "neuromorphic-chip", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "enzyme-pks", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1.5 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "cottongut", quality = "normal", amount_per_second = 10 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "kicalk-seeds", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.5 },
      { type = "fluid", name = "arthropod-blood", quality = "normal", amount_per_second = 30, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "chelator", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 465000,
    pollution_per_second = 0.001,
  },
  {
    recipe_typed_name = { type = "recipe", name = "neuroprocessor", quality = "normal" },
    products = {
      { type = "item", name = "neuroprocessor", quality = "normal", amount_per_second = 1 },
    },
    ingredients = {
      { type = "item", name = "optical-fiber", quality = "normal", amount_per_second = 5 },
      { type = "item", name = "nexelit-matrix", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "agar", quality = "normal", amount_per_second = 1.5 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1.5 },
      { type = "item", name = "cermet", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "capacitor1", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "inductor1", quality = "normal", amount_per_second = 5 },
      { type = "item", name = "resistor1", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "pcb2", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "nickel-plate", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 1240000,
    pollution_per_second = 0.03333333333333333,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-sample", quality = "normal" },
    products = {
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bio-container", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 1.5 },
    },
    power_per_second = 620000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "zungror-codex", quality = "normal" },
    products = {
      { type = "item", name = "zungror-codex", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "processing-unit", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "glass", quality = "normal", amount_per_second = 0.4 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-vonix", quality = "normal" },
    products = {
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "venom-gland", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "arthropod-blood", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "vonix", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "scrondrix-mk03r", quality = "normal" },
    products = {
      { type = "item", name = "scrondrix-mk03", quality = "normal", amount_per_second = 0.026666666666666665 },
    },
    ingredients = {
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "sugar", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.013333333333333333 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "scrondrix-codex-mk03", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "scrondrix-mk03", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "fluid", name = "chelator", quality = "normal", amount_per_second = 0.66666666666666661, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 0.3333333333333333, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "arqad-jelly", quality = "normal", amount_per_second = 0.066666666666666661, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 9300000,
    pollution_per_second = 0.05,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cdna", quality = "normal" },
    products = {
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "fawogae-substrate", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "petri-dish-bacteria", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "moss-gen", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "plasmids", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "retrovirus", quality = "normal", amount_per_second = 0.1 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "biofilm-3", quality = "normal" },
    products = {
      { type = "item", name = "biofilm", quality = "normal", amount_per_second = 0.8 },
    },
    ingredients = {
      { type = "item", name = "lime", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "cellulose", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "fawogae-substrate", quality = "normal", amount_per_second = 3 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-zipir", quality = "normal" },
    products = {
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "arthropod-blood", quality = "normal", amount_per_second = 2.1666666666666665, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "zipir1", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "flyavan", quality = "normal" },
    products = {
      { type = "item", name = "flyavan", quality = "normal", amount_per_second = 0.02 },
    },
    ingredients = {
      { type = "item", name = "py-science-pack-2", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "neuroprocessor", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 10 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "earth-cow-sample", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "trits", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "small-parts-01", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 3, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "purine-analogues", quality = "normal" },
    products = {
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "serine", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-scafold-2", quality = "normal" },
    products = {
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.3333333333333333 },
    },
    ingredients = {
      { type = "item", name = "keratin", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "sodium-alginate", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "collagen", quality = "normal", amount_per_second = 0.4666666666666667 },
      { type = "fluid", name = "boric-acid", quality = "normal", amount_per_second = 13.333333333333334, minimum_temperature = 0, maximum_temperature = 10 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "animal-sample-01", quality = "normal" },
    products = {
      { type = "item", name = "animal-sample-01", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.7 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "plasmids", quality = "normal", amount_per_second = 0.1 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fluidflyavan", quality = "normal" },
    products = {
      { type = "item", name = "fluidflyavan", quality = "normal", amount_per_second = 0.02 },
    },
    ingredients = {
      { type = "item", name = "py-tank-10000", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "pump", quality = "normal", amount_per_second = 0.04 },
      { type = "item", name = "py-science-pack-2", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "neuroprocessor", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 10 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "earth-cow-sample", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "trits", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "small-parts-01", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 3, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "reca-2", quality = "normal" },
    products = {
      { type = "item", name = "reca", quality = "normal", amount_per_second = 4.2857142857142856 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.57142857142857135 },
      { type = "item", name = "denatured-seismite", quality = "normal", amount_per_second = 0.028571428571428568 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.014285714285714284 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.014285714285714284 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.042857142857142865 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.42857142857142856 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.42857142857142856 },
      { type = "fluid", name = "fetal-serum", quality = "normal", amount_per_second = 1.4285714285714286, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "gta", quality = "normal", amount_per_second = 0.71428571428571432, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
}

local constraints_soil = {
  { type = "item", name = "soil", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_soil = {
  {
    recipe_typed_name = { type = "recipe", name = "biomass-wood-seedling-mk04", quality = "normal" },
    products = {
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 13.333333333333334 },
    },
    ingredients = {
      { type = "item", name = "wood-seedling-mk04", quality = "normal", amount_per_second = 3.3333333333333335 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "wood-seedling-mk04", quality = "normal" },
    products = {
      { type = "item", name = "wood-seedling-mk04", quality = "normal", amount_per_second = 0.05 },
    },
    ingredients = {
      { type = "item", name = "ground-sample01", quality = "normal", amount_per_second = 0.25 },
      { type = "item", name = "cobalt-fluoride", quality = "normal", amount_per_second = 0.25 },
      { type = "item", name = "wood-seeds-mk04", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "moss", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "psc", quality = "normal", amount_per_second = 2.5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "chelator", quality = "normal", amount_per_second = 2.5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "ground-sample01", quality = "normal" },
    products = {
      { type = "item", name = "ground-sample01", quality = "normal", amount_per_second = 2 },
    },
    ingredients = {
      { type = "item", name = "rich-clay", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 2 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "rich-clay-2", quality = "normal" },
    products = {
      { type = "item", name = "rich-clay", quality = "normal", amount_per_second = 1.6666666666666668 },
    },
    ingredients = {
      { type = "item", name = "clay", quality = "normal", amount_per_second = 3.3333333333333335 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "muddy-sludge", quality = "normal" },
    products = {
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "soil", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "clay", quality = "normal" },
    products = {
      { type = "item", name = "clay", quality = "normal", amount_per_second = 0.75 },
    },
    ingredients = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "muddy-sludge-void-electrolyzer", quality = "normal" },
    products = {
      { type = "item", name = "soil", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "oxygen", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 10333333.333333334,
    pollution_per_second = 0.001,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cool-steam-500-to-250", quality = "normal" },
    products = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 41, minimum_temperature = 250, maximum_temperature = 250 },
    },
    ingredients = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 20, minimum_temperature = 500, maximum_temperature = 2000 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 22, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "steam-heating", quality = "normal" },
    products = {
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 500, maximum_temperature = 500 },
    },
    ingredients = {
      { type = "item", name = "fuelrod-mk01", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "soil-washing", quality = "normal" },
    products = {
      { type = "item", name = "sand", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "soil", quality = "normal", amount_per_second = 7.5 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 150, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "kicalk-3", quality = "normal" },
    products = {
      { type = "item", name = "kicalk", quality = "normal", amount_per_second = 0.0052910052910052912 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.00026455026455026456 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.0026455026455026456 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.0026455026455026456 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.0026455026455026456 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.0013227513227513228 },
      { type = "item", name = "kicalk-seeds", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "item", name = "clay", quality = "normal", amount_per_second = 0.0010582010582010581 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.13227513227513228, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.03968253968253968, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 930000,
    pollution_per_second = -0.25000000000000004,
  },
  {
    recipe_typed_name = { type = "recipe", name = "kicalk-4", quality = "normal" },
    products = {
      { type = "item", name = "kicalk", quality = "normal", amount_per_second = 0.012698412698412698 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.0003968253968253968 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.001984126984126984 },
      { type = "item", name = "kicalk-seeds", quality = "normal", amount_per_second = 0.0059523809523809508 },
      { type = "item", name = "clay", quality = "normal", amount_per_second = 0.0015873015873015872 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.1984126984126984, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.03968253968253968, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 930000,
    pollution_per_second = -0.25000000000000004,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tar-distilation", quality = "normal" },
    products = {
      { type = "item", name = "rich-clay", quality = "normal", amount_per_second = 0.4 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 40, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "aromatics", quality = "normal", amount_per_second = 40, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "tar", quality = "normal", amount_per_second = 140, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "aromatics", quality = "normal" },
    products = {
      { type = "fluid", name = "aromatics", quality = "normal", amount_per_second = 100, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "nexelit-plate", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "olefin", quality = "normal", amount_per_second = 100, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 100, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "filtration-dirty-water", quality = "normal" },
    products = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.63636363636363633 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.18181818181818183 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tar-to-carbolic", quality = "normal" },
    products = {
      { type = "item", name = "rich-clay", quality = "normal", amount_per_second = 0.06 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "coal-gas", quality = "normal", amount_per_second = 7, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "carbolic-oil", quality = "normal", amount_per_second = 2, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "raw-coal", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "tar", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 20, minimum_temperature = 250, maximum_temperature = 2000 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "kicalk-5", quality = "normal" },
    products = {
      { type = "item", name = "kicalk", quality = "normal", amount_per_second = 0.03968253968253968 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.00079365079365079358 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.00079365079365079358 },
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.0079365079365079358 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.0079365079365079358 },
      { type = "item", name = "phosphorous-acid-barrel", quality = "normal", amount_per_second = 0.00079365079365079358 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.015873015873015872 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.0087301587301587276 },
      { type = "item", name = "kicalk-seeds", quality = "normal", amount_per_second = 0.011904761904761902 },
      { type = "item", name = "clay", quality = "normal", amount_per_second = 0.011904761904761902 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.3968253968253968, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.079365079365079358, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 930000,
    pollution_per_second = -0.25000000000000004,
  },
  {
    recipe_typed_name = { type = "recipe", name = "extract-gas-from-coalbed-3", quality = "normal" },
    products = {
      { type = "fluid", name = "coalbed-gas", quality = "normal", amount_per_second = 20.833333333333332, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "fluid", name = "pressured-water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "oxygen", quality = "normal", amount_per_second = 41.666666666666664, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 775000,
    pollution_per_second = 0.83333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dirty-reaction", quality = "normal" },
    products = {
      { type = "fluid", name = "crude-oil", quality = "normal", amount_per_second = 43.01075268817204, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 215.05376344086019, minimum_temperature = 150, maximum_temperature = 150 },
      { type = "fluid", name = "olefin", quality = "normal", amount_per_second = 21.50537634408602, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "tailings", quality = "normal", amount_per_second = 86.021505376344081, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 215.05376344086019, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "aromatics", quality = "normal", amount_per_second = 21.50537634408602, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "Moss-5", quality = "normal" },
    products = {
      { type = "item", name = "moss", quality = "normal", amount_per_second = 0.125 },
    },
    ingredients = {
      { type = "item", name = "stone", quality = "normal", amount_per_second = 0.0625 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.046875 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.03125 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.015625 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 0.3125, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.3125, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 103333.33333333334,
    pollution_per_second = -0.58333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "limestone-void", quality = "normal" },
    products = {
      { type = "item", name = "soil", quality = "normal", amount_per_second = 6 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 4 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 6 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 4 },
    },
    power_per_second = 465000,
    pollution_per_second = 0.001,
  },
  {
    recipe_typed_name = { type = "recipe", name = "carbolic-oil-barrel", quality = "normal" },
    products = {
      { type = "item", name = "carbolic-oil-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "carbolic-oil", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
}

local constraints_fish = {
  { type = "item", name = "fish", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_fish = {
  {
    recipe_typed_name = { type = "recipe", name = "zungror-mk03r", quality = "normal" },
    products = {
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.02 },
    },
    ingredients = {
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.032000000000000002 },
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.008 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-codex-mk03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.016000000000000001 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.004 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 9300000,
    pollution_per_second = 0.05,
  },
  {
    recipe_typed_name = { type = "recipe", name = "purine-analogues", quality = "normal" },
    products = {
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "serine", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fish-mk02", quality = "normal" },
    products = {
      { type = "item", name = "fish-mk02", quality = "normal", amount_per_second = 2.0833333333333335e-05 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.02083333333333333 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "item", name = "fish-food-01", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "item", name = "seaweed", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "fluid", name = "phytoplankton", quality = "normal", amount_per_second = 0.25, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "alien-sample-03", quality = "normal" },
    products = {
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1.3333333333333333 },
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "dna-polymerase", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "primers", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "arthurian-egg", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "graphene-roll", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 13.333333333333334, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "formamide", quality = "normal" },
    products = {
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "ammonia", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "acetic-acid", quality = "normal" },
    products = {
      { type = "fluid", name = "acetic-acid", quality = "normal", amount_per_second = 12.5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 12.5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "methanol-from-hydrogen", quality = "normal" },
    products = {
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 40, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "nichrome", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 30, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "melamine", quality = "normal" },
    products = {
      { type = "item", name = "melamine", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 3, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "cyanic-acid", quality = "normal", amount_per_second = 2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "ammonia", quality = "normal", amount_per_second = 2, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "alien-sample-02", quality = "normal" },
    products = {
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "dna-polymerase", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "primers", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "micro-fiber", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "fluid", name = "milk", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "filtration-dirty-water", quality = "normal" },
    products = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.63636363636363633 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.18181818181818183 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "zungror-mk03", quality = "normal" },
    products = {
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 4.4444444444444438e-05 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "zungror", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.011111111111111112 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.11111111111111112 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.055555555555555554 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "caged-mukmoux", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "zungror", quality = "normal", amount_per_second = 0.022222222222222223 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "casein-mixture-01", quality = "normal" },
    products = {
      { type = "fluid", name = "casein-mixture", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "waste-water", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "milk", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "acetic-acid", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "chromium-01", quality = "normal" },
    products = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 1 },
    },
    ingredients = {
      { type = "item", name = "chromite-sand", quality = "normal", amount_per_second = 3 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.6 },
      { type = "item", name = "sand-casting", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 30, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-sample", quality = "normal" },
    products = {
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bio-container", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 1.5 },
    },
    power_per_second = 620000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-mutant-enzymes-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "mutant-enzymes-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "propeptides", quality = "normal" },
    products = {
      { type = "item", name = "propeptides", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "bonemeal", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "dingrit-spike", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "sea-sponge", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 1 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "micro-fiber", quality = "normal" },
    products = {
      { type = "item", name = "micro-fiber", quality = "normal", amount_per_second = 0.25 },
    },
    ingredients = {
      { type = "item", name = "fiber", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 0.375 },
    },
    power_per_second = 155000,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sodium-carbonate-1", quality = "normal" },
    products = {
      { type = "item", name = "sodium-carbonate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 1.25 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.75 },
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.25 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sea-sponge", quality = "normal" },
    products = {
      { type = "item", name = "sea-sponge", quality = "normal", amount_per_second = 0.0066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.013333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "earth-sea-sponge-sample", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "sea-sponge-codex", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bmp-2", quality = "normal" },
    products = {
      { type = "item", name = "bmp", quality = "normal", amount_per_second = 1.75 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.15 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.03 },
      { type = "item", name = "ticocr-alloy", quality = "normal", amount_per_second = 0.015 },
      { type = "item", name = "hyaline", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.075 },
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "pineal-gland", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "collagen", quality = "normal", amount_per_second = 0.125 },
      { type = "fluid", name = "bacteria-2", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "dms", quality = "normal", amount_per_second = 0.5, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
}

local constraints_bmp = {
  { type = "item", name = "bmp", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_bmp = {
  {
    recipe_typed_name = { type = "recipe", name = "zungror-mk03r", quality = "normal" },
    products = {
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.02 },
    },
    ingredients = {
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "bio-scafold", quality = "normal", amount_per_second = 0.032000000000000002 },
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.008 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-codex-mk03", quality = "normal", amount_per_second = 0.004 },
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 0.016000000000000001 },
      { type = "item", name = "adrenal-cortex", quality = "normal", amount_per_second = 0.004 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "artificial-blood", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 9300000,
    pollution_per_second = 0.05,
  },
  {
    recipe_typed_name = { type = "recipe", name = "purine-analogues", quality = "normal" },
    products = {
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "serine", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fish-mk02", quality = "normal" },
    products = {
      { type = "item", name = "fish-mk02", quality = "normal", amount_per_second = 2.0833333333333335e-05 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.02083333333333333 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "item", name = "fish-food-01", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "item", name = "seaweed", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "fluid", name = "phytoplankton", quality = "normal", amount_per_second = 0.25, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "alien-sample-03", quality = "normal" },
    products = {
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 1.3333333333333333 },
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "dna-polymerase", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "primers", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "arthurian-egg", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "graphene-roll", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 13.333333333333334, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "formamide", quality = "normal" },
    products = {
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "ammonia", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "acetic-acid", quality = "normal" },
    products = {
      { type = "fluid", name = "acetic-acid", quality = "normal", amount_per_second = 12.5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 12.5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "methanol-from-hydrogen", quality = "normal" },
    products = {
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 40, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "nichrome", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 30, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "melamine", quality = "normal" },
    products = {
      { type = "item", name = "melamine", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 3, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "cyanic-acid", quality = "normal", amount_per_second = 2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "ammonia", quality = "normal", amount_per_second = 2, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "alien-sample-02", quality = "normal" },
    products = {
      { type = "item", name = "alien-sample-02", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "dna-polymerase", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "primers", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "micro-fiber", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "fluid", name = "milk", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "formamide", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "bee-venom", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "filtration-dirty-water", quality = "normal" },
    products = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.63636363636363633 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.18181818181818183 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 90.909090909090907, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "zungror-mk03", quality = "normal" },
    products = {
      { type = "item", name = "zungror-mk03", quality = "normal", amount_per_second = 4.4444444444444438e-05 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "zungror", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.011111111111111112 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.11111111111111112 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.055555555555555554 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "caged-mukmoux", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "zungror", quality = "normal", amount_per_second = 0.022222222222222223 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "casein-mixture-01", quality = "normal" },
    products = {
      { type = "fluid", name = "casein-mixture", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "waste-water", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "milk", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "acetic-acid", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "chromium-01", quality = "normal" },
    products = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 1 },
    },
    ingredients = {
      { type = "item", name = "chromite-sand", quality = "normal", amount_per_second = 3 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.6 },
      { type = "item", name = "sand-casting", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 30, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bio-sample", quality = "normal" },
    products = {
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "bio-container", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 1.5 },
    },
    power_per_second = 620000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-mutant-enzymes-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "mutant-enzymes", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "mutant-enzymes-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "propeptides", quality = "normal" },
    products = {
      { type = "item", name = "propeptides", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "chromium", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "bonemeal", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "dingrit-spike", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "sea-sponge", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 1 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "micro-fiber", quality = "normal" },
    products = {
      { type = "item", name = "micro-fiber", quality = "normal", amount_per_second = 0.25 },
    },
    ingredients = {
      { type = "item", name = "fiber", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 0.375 },
    },
    power_per_second = 155000,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sodium-carbonate-1", quality = "normal" },
    products = {
      { type = "item", name = "sodium-carbonate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 1.25 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.75 },
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.25 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "sea-sponge", quality = "normal" },
    products = {
      { type = "item", name = "sea-sponge", quality = "normal", amount_per_second = 0.0066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "alien-sample01", quality = "normal", amount_per_second = 0.013333333333333333 },
      { type = "item", name = "bio-sample", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "cdna", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "earth-sea-sponge-sample", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "item", name = "sea-sponge-codex", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bmp-2", quality = "normal" },
    products = {
      { type = "item", name = "bmp", quality = "normal", amount_per_second = 1.75 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.15 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "paragen", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "negasium", quality = "normal", amount_per_second = 0.03 },
      { type = "item", name = "ticocr-alloy", quality = "normal", amount_per_second = 0.015 },
      { type = "item", name = "hyaline", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "chitin", quality = "normal", amount_per_second = 0.075 },
      { type = "item", name = "purine-analogues", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "alien-enzymes", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "pineal-gland", quality = "normal", amount_per_second = 0.02 },
      { type = "item", name = "collagen", quality = "normal", amount_per_second = 0.125 },
      { type = "fluid", name = "bacteria-2", quality = "normal", amount_per_second = 0.2, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "dms", quality = "normal", amount_per_second = 0.5, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 826666.66666666674,
    pollution_per_second = 0.01666666666666667,
  },
}

-- ---- SUCCESS: a constrained intermediate the solver closes cleanly --------
table.insert(cases, {
    name = "constrained intermediate (sodium-sulfate = 1) closes cleanly with imports + shipping",
    run = function()
        local problem = cp.create_problem("constrained-sodium_sulfate", constraints_sodium_sulfate, lines_sodium_sulfate)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat, ships, imports = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "the pinned intermediate is met by the real chain, not fabricated")
        harness.assert_true(ships, "a by-product leaves via a final_sink")
        harness.assert_true(imports, "the chain draws its raws via initial_source")
    end,
})


table.insert(cases, {
    name = "constrained intermediate (yotoi-leaves = 1) closes cleanly with imports + shipping",
    run = function()
        local problem = cp.create_problem("constrained-yotoi_leaves", constraints_yotoi_leaves, lines_yotoi_leaves)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat, ships, imports = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "the pinned intermediate is met by the real chain, not fabricated")
        harness.assert_true(ships, "a by-product leaves via a final_sink")
        harness.assert_true(imports, "the chain draws its raws via initial_source")
    end,
})


-- ---- AVOIDABLE cheat (xfail): export-feasible, the two-pass closes it -----
table.insert(cases, {
    name = "AVOIDABLE: constrained biomass is fabricated though its cycle can produce it",
    xfail = true,
    run = function()
        local problem = cp.create_problem("avoidable-biomass", constraints_biomass, lines_biomass)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "biomass is export-feasible; the diagnose-then-reclassify two-pass should run the chain")
    end,
})


table.insert(cases, {
    name = "AVOIDABLE: constrained guar-seeds-mk03 is fabricated though its cycle can produce it",
    xfail = true,
    run = function()
        local problem = cp.create_problem("avoidable-guar_seeds_mk03", constraints_guar_seeds_mk03, lines_guar_seeds_mk03)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "guar-seeds-mk03 is export-feasible; the diagnose-then-reclassify two-pass should run the chain")
    end,
})


table.insert(cases, {
    name = "AVOIDABLE: constrained scrondrix-mk03 is fabricated though its cycle can produce it",
    xfail = true,
    run = function()
        local problem = cp.create_problem("avoidable-scrondrix_mk03", constraints_scrondrix_mk03, lines_scrondrix_mk03)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "scrondrix-mk03 is export-feasible; the diagnose-then-reclassify two-pass should run the chain")
    end,
})


-- ---- UNAVOIDABLE cheat (xfail): needs the base-resource import signal -----
table.insert(cases, {
    name = "UNAVOIDABLE: constrained soil is fabricated, not imported (no flow makes it)",
    xfail = true,
    run = function()
        local problem = cp.create_problem("unavoidable-soil", constraints_soil, lines_soil)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "soil should be imported as a base resource, not fabricated via shortage")
    end,
})


table.insert(cases, {
    name = "UNAVOIDABLE: constrained fish is fabricated, not imported (no flow makes it)",
    xfail = true,
    run = function()
        local problem = cp.create_problem("unavoidable-fish", constraints_fish, lines_fish)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "fish should be imported as a base resource, not fabricated via shortage")
    end,
})


table.insert(cases, {
    name = "UNAVOIDABLE: constrained bmp is fabricated, not imported (no flow makes it)",
    xfail = true,
    run = function()
        local problem = cp.create_problem("unavoidable-bmp", constraints_bmp, lines_bmp)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat = classify(vars)
        harness.assert_near(cheat, 0, 1e-3,
            "bmp should be imported as a base resource, not fabricated via shortage")
    end,
})


return cases
