-- Real chain-explorer findings, captured verbatim from the in-game create_problem
-- dumps (dump_normalized_lines / dump_constraints) on the all-technologies
-- pyanodon graph. Both are the catalyst-loop failure mode (the fourth mode of
-- find_deficit_materials, cf. lp_catalyst_loop_bootstrap's hand-built NS2): a loop
-- turns on net-zero catalysts the net-flow heuristic cannot see, so the loop never
-- becomes reachable and the LP fabricates the demanded material -- and the
-- catalysts -- via |shortage_source| instead of importing the catalysts and
-- running the chain. Captured unedited from the explorer (init=recipe netneg
-- probe, all tech researched) so the regressions ride real pyanodon topologies.
-- They span the spectrum: the rennea/dingrits case fabricates almost everything
-- (1 recipe active), the limestone case runs most of the chain yet still cheats
-- (12 active). Headless solves reproduce the in-game cheat exactly (0.75 / 0.82).
-- Practicality is decided in create_problem / material_cycles, not the IPM. xfail
-- until the catalyst is imported via |initial_source| instead of fabricated.
--
-- NOTE: NS2's catalyst fix (net-zero seed_candidates in a NON-self-sustaining
-- cycle) does NOT reach these. Both loops here are self-sustaining (cone_feasible
-- admits a positive circulation) yet still cannot bootstrap from zero, and the
-- limestone primer (slacked-lime) is mass-losing, not a net-zero catalyst -- so
-- both fall outside the deliberately conservative gate that keeps Gleba <grow>
-- loops and mild-loss dead-ends on their existing (correct) paths. Closing these
-- needs a reachability-driven primer that can fire inside a self-sustaining SCC
-- without also priming a mass-positive <grow> loop -- a sharper test than
-- is_self_sustaining alone provides.

local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"

-- Cheat mass (shortage + elastic) and whether any declared external input is drawn.
local function cheat_and_imports(vars)
    local cheat, has_initial = 0, false
    for k, v in pairs(vars.x) do
        if math.abs(v) > 1e-6 then
            if k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true) then
                cheat = cheat + math.abs(v)
            elseif k:find("|initial_source|", 1, true) then
                has_initial = true
            end
        end
    end
    return cheat, has_initial
end

local cases = {}

-- Case 1: a rennea / dingrits biological loop, target tuuphra = 1/s. Catalysts
-- rennea-seeds-mk03 / dingrits-cub / digested-rennea-seeds-mk03 stay unreachable;
-- the LP fabricates tuuphra (cheat = 0.75) with essentially nothing running.
local constraints_tuuphra = {
  { type = "item", name = "tuuphra", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_tuuphra = {
  {
    recipe_typed_name = { type = "recipe", name = "rennea-mk03-seed-seperation", quality = "normal" },
    products = {
      { type = "item", name = "rennea-seeds-mk03", quality = "normal", amount_per_second = 0.83333333333333339 },
      { type = "fluid", name = "tall-oil", quality = "normal", amount_per_second = 0.66666666666666661, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "black-liquor", quality = "normal", amount_per_second = 0.66666666666666661, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "rennea-mk03", quality = "normal", amount_per_second = 0.26666666666666665 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "rennea-mk03-dingrit-pup-digestion", quality = "normal" },
    products = {
      { type = "item", name = "dingrits", quality = "normal", amount_per_second = 0.0030303030303030303 },
      { type = "item", name = "digested-rennea-seeds-mk03", quality = "normal", amount_per_second = 0.015151515151515156 },
    },
    ingredients = {
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.0045454545454545459 },
      { type = "item", name = "rennea-seeds-mk03", quality = "normal", amount_per_second = 0.015151515151515156 },
      { type = "item", name = "tuuphra", quality = "normal", amount_per_second = 0.030303030303030312 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.024999999999999996,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-cub-1", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.088888888888888893 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.022222222222222223 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.044444444444444446 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 0.66666666666666661 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-food-01", quality = "normal" },
    products = {
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.6 },
    },
    ingredients = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "tuuphra", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "guar-gum", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.6 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 2000 },
      { type = "fluid", name = "fish-oil", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "caged-scrondrix", quality = "normal" },
    products = {
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 2 },
    },
    ingredients = {
      { type = "item", name = "cage", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "scrondrix", quality = "normal", amount_per_second = 2 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tuuphra-mk02", quality = "normal" },
    products = {
      { type = "item", name = "tuuphra-mk02", quality = "normal", amount_per_second = 1.6666666666666668e-05 },
      { type = "item", name = "tuuphra", quality = "normal", amount_per_second = 0.0016666666666666665 },
    },
    ingredients = {
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "manure", quality = "normal", amount_per_second = 0.049999999999999991 },
      { type = "item", name = "tuuphra-seeds", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "tuuphra", quality = "normal", amount_per_second = 0.0066666666666666661 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.99999999999999982, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 3.333333333333333, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = -0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-cub-4", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.2333333333333333 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "dingrits-food-02", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.3333333333333333 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-cub-3", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.4166666666666667 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.15277777777777777 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.083333333333333321 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.4166666666666667 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.027777777777777777 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.055555555555555554 },
      { type = "item", name = "dingrits-food-02", quality = "normal", amount_per_second = 0.055555555555555554 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.27777777777777772 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 0.83333333333333339 },
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.27777777777777772 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-4", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "item", name = "dingrits", quality = "normal", amount_per_second = 0.017045454545454546 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.0011363636363636365 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.0011363636363636365 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.0011363636363636365 },
      { type = "item", name = "dingrits-food-02", quality = "normal", amount_per_second = 0.0011363636363636365 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.0011363636363636365 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.017045454545454546 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.039772727272727284 },
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.022727272727272729 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.024999999999999996,
  },
  {
    recipe_typed_name = { type = "recipe", name = "rennea-mk03-breeding", quality = "normal" },
    products = {
      { type = "item", name = "rennea-mk03", quality = "normal", amount_per_second = 0.0076628352490421445 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.022988505747126435 },
    },
    ingredients = {
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.019157088122605362 },
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.019157088122605362 },
      { type = "item", name = "phosphoric-acid-barrel", quality = "normal", amount_per_second = 0.0038314176245210723 },
      { type = "item", name = "abraded-rennea-seeds-mk03", quality = "normal", amount_per_second = 0.011494252873563218 },
      { type = "item", name = "stone-wool", quality = "normal", amount_per_second = 0.019157088122605362 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.57471264367816088, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "nitrogen", quality = "normal", amount_per_second = 0.19157088122605362, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yotoi-fruit-3", quality = "normal" },
    products = {
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 0.045321100917431192 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.019082568807339451 },
      { type = "item", name = "gravel", quality = "normal", amount_per_second = 0.023853211009174311 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.011926605504587156 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.0095412844036697244 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.014311926605504588 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0023853211009174311 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.011926605504587156 },
      { type = "item", name = "blood-meal", quality = "normal", amount_per_second = 0.0047706422018348622 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.23853211009174311, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.14311926605504588, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-cub-2", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.35714285714285716 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.10714285714285714 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.071428571428571423 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.35714285714285716 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.023809523809523809 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.047619047619047619 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.071428571428571423 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.23809523809523809 },
      { type = "item", name = "yotoi-seeds", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.11904761904761905 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "phosphoric-acid-barrel", quality = "normal" },
    products = {
      { type = "item", name = "phosphoric-acid-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "phosphoric-acid", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "dingrits-3", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0041322314049586781 },
      { type = "item", name = "dingrits", quality = "normal", amount_per_second = 0.0070247933884297513 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.00082644628099173563 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.0041322314049586781 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.00082644628099173563 },
      { type = "item", name = "dingrits-food-01", quality = "normal", amount_per_second = 0.00082644628099173563 },
      { type = "item", name = "dingrits-food-02", quality = "normal", amount_per_second = 0.00082644628099173563 },
      { type = "item", name = "caged-scrondrix", quality = "normal", amount_per_second = 0.00082644628099173563 },
      { type = "item", name = "dingrits-cub", quality = "normal", amount_per_second = 0.0082644628099173563 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.012396694214876034 },
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.016528925619834711 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.024999999999999996,
  },
  {
    recipe_typed_name = { type = "recipe", name = "purex-antimony-void", quality = "normal" },
    products = {
      { type = "item", name = "sb-oxide", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "phosphorous-acid", quality = "normal", amount_per_second = 12, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.3 },
      { type = "fluid", name = "sb-phosphate-2", quality = "normal", amount_per_second = 6, minimum_temperature = 10, maximum_temperature = 1000 },
      { type = "fluid", name = "purex-concentrate-1", quality = "normal", amount_per_second = 3, minimum_temperature = 10, maximum_temperature = 1000 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "bedding-improve", quality = "normal" },
    products = {
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.57142857142857135 },
    },
    ingredients = {
      { type = "item", name = "wood", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "item", name = "dried-grods", quality = "normal", amount_per_second = 0.14285714285714284 },
      { type = "item", name = "raw-fiber", quality = "normal", amount_per_second = 0.71428571428571432 },
      { type = "fluid", name = "formic-acid", quality = "normal", amount_per_second = 14.285714285714286, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.033333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "water-barrel", quality = "normal" },
    products = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 125, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "coarse-classification", quality = "normal" },
    products = {
      { type = "item", name = "stone", quality = "normal", amount_per_second = 5 },
      { type = "item", name = "iron-oxide", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "gravel", quality = "normal", amount_per_second = 4 },
    },
    ingredients = {
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 20 },
    },
    power_per_second = 775000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "abraded-rennea-seed-filtering-mk03", quality = "normal" },
    products = {
      { type = "item", name = "abraded-rennea-seeds-mk03", quality = "normal", amount_per_second = 1.3999999999999999 },
      { type = "fluid", name = "liquid-manure", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "digested-rennea-seeds-mk03", quality = "normal", amount_per_second = 1.3999999999999999 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 100, minimum_temperature = 15, maximum_temperature = 500 },
    },
    fuel_ingredient = { type = "item", name = "xeno-egg", quality = "normal", amount_per_second = 0.00083333333333333321 },
    power_per_second = 0,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "yaedols-4", quality = "normal" },
    products = {
      { type = "item", name = "yaedols", quality = "normal", amount_per_second = 0.12 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.005 },
    },
    ingredients = {
      { type = "item", name = "wood", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "bacteria-1-barrel", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "fungal-substrate", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "fungal-substrate-03", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.075 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "yaedols-spores", quality = "normal", amount_per_second = 0.08 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.4, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "nitrogen", quality = "normal", amount_per_second = 0.75, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tall-oil-barrel", quality = "normal" },
    products = {
      { type = "item", name = "tall-oil-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "tall-oil", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
}

table.insert(cases, {
    name = "explorer catalyst (rennea/dingrits -> tuuphra) imports the catalyst, not fabricates",
    xfail = true,
    run = function()
        local problem = cp.create_problem("explorer-rennea-tuuphra", constraints_tuuphra, lines_tuuphra)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat, has_initial = cheat_and_imports(vars)
        harness.assert_true(has_initial, "imports declared external inputs")
        harness.assert_near(cheat, 0, 1e-3,
            "tuuphra + catalysts from the real chain + imports, not shortage (cheat = 0.75 today)")
    end,
})

-- Case 2: a uranium / antimony-family loop seeded from fuel-cell-dissolve, target
-- limestone = 1/s. Most of the chain runs (12 active recipes) but the catalyst is
-- still fabricated, so limestone is partly conjured (cheat = 0.82). The
-- partial-shortage shape: real flow next to a cheat, not the all-parked extreme.
local constraints_limestone = {
  { type = "item", name = "limestone", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines_limestone = {
  {
    recipe_typed_name = { type = "recipe", name = "fuel-cell-dissolve", quality = "normal" },
    products = {
      { type = "fluid", name = "sb-phosphate-1", quality = "normal", amount_per_second = 6.666666666666667, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "depleted-uranium-fuel-cell", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "sodium-hydroxide", quality = "normal", amount_per_second = 1 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 25, maximum_temperature = 25 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
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
    recipe_typed_name = { type = "recipe", name = "grod-mk03-breeder", quality = "normal" },
    products = {
      { type = "item", name = "grod-mk03", quality = "normal", amount_per_second = 0.0109375 },
      { type = "item", name = "grod-mk03", quality = "normal", amount_per_second = 0.00125 },
      { type = "item", name = "grod-mk02", quality = "normal", amount_per_second = 0.0009375 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0015625 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.0015625 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "grod-seeds-mk03", quality = "normal", amount_per_second = 0.015625 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.46875, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 1.5625, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "acetylene", quality = "normal" },
    products = {
      { type = "fluid", name = "acetylene", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 3.125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "calcium-carbide", quality = "normal", amount_per_second = 1.25 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 37.5, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
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
    recipe_typed_name = { type = "recipe", name = "grod-mk04", quality = "normal" },
    products = {
      { type = "item", name = "grod-mk04", quality = "normal", amount_per_second = 1.25e-05 },
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.0029166666666666661 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "zinc-finger-proteins", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "grod-mk03", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "grod-seeds-mk03", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 1.25, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 4.166666666666667, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-mk04-breeder", quality = "normal" },
    products = {
      { type = "item", name = "grod-mk04", quality = "normal", amount_per_second = 0.0109375 },
      { type = "item", name = "grod-mk04", quality = "normal", amount_per_second = 0.0009375 },
      { type = "item", name = "grod-mk03", quality = "normal", amount_per_second = 0.00109375 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0015625 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "zinc-finger-proteins", quality = "normal", amount_per_second = 0.0015625 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.015625 },
      { type = "item", name = "grod-seeds-mk04", quality = "normal", amount_per_second = 0.015625 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.46875, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 1.5625, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
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
    recipe_typed_name = { type = "recipe", name = "methyl-acrylate-2", quality = "normal" },
    products = {
      { type = "item", name = "methyl-acrylate", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "cobalt-oxide", quality = "normal", amount_per_second = 0.4 },
      { type = "fluid", name = "acetylene", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "calcium-carbide", quality = "normal" },
    products = {
      { type = "item", name = "calcium-carbide", quality = "normal", amount_per_second = 2.5 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 1.75 },
      { type = "item", name = "lime", quality = "normal", amount_per_second = 0.5 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "acrylic", quality = "normal" },
    products = {
      { type = "item", name = "acrylic", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "methyl-acrylate", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "acrylonitrile", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "ammonia", quality = "normal", amount_per_second = 16, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "sulfuric-acid", quality = "normal", amount_per_second = 10, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "natural-gas", quality = "normal", amount_per_second = 30, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "acetone", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-mk03", quality = "normal" },
    products = {
      { type = "item", name = "grod-mk03", quality = "normal", amount_per_second = 1.6666666666666668e-05 },
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.0025 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "grod-mk02", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "grod-seeds-mk02", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 1.25, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 4.166666666666667, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "propene-to-acetone", quality = "normal" },
    products = {
      { type = "fluid", name = "acetone", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "chromite-sand", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "copper-plate", quality = "normal", amount_per_second = 0.4 },
      { type = "fluid", name = "propene", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "pressured-air", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "salt-ex", quality = "normal" },
    products = {
      { type = "item", name = "salt", quality = "normal", amount_per_second = 11.5 },
    },
    ingredients = {
      { type = "fluid", name = "water-saline", quality = "normal", amount_per_second = 115, minimum_temperature = 25, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "zinc-finger-proteins", quality = "normal" },
    products = {
      { type = "item", name = "zinc-finger-proteins", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "flask", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "lab-instrument", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "carapace", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "adam42-gen", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "cysteine", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "serine", quality = "normal", amount_per_second = 2 },
      { type = "item", name = "zinc-plate", quality = "normal", amount_per_second = 0.26666666666666665 },
      { type = "fluid", name = "gta", quality = "normal", amount_per_second = 3.3333333333333335, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "fatty-acids", quality = "normal", amount_per_second = 2, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "silver-foam", quality = "normal" },
    products = {
      { type = "item", name = "silver-foam", quality = "normal", amount_per_second = 0.1 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 3 },
      { type = "item", name = "agzn-alloy", quality = "normal", amount_per_second = 0.1 },
      { type = "fluid", name = "acetylene", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen-chloride", quality = "normal", amount_per_second = 20, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen-peroxide", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "phosphate-glass", quality = "normal" },
    products = {
      { type = "item", name = "phosphate-glass", quality = "normal", amount_per_second = 0.25 },
    },
    ingredients = {
      { type = "item", name = "iron-oxide", quality = "normal", amount_per_second = 3 },
      { type = "item", name = "phosphate-rock", quality = "normal", amount_per_second = 1.25 },
      { type = "item", name = "crushed-quartz", quality = "normal", amount_per_second = 1.5 },
      { type = "item", name = "sodium-sulfate", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "acetylene", quality = "normal", amount_per_second = 12.5, minimum_temperature = 15, maximum_temperature = 100 },
    },
    fuel_ingredient = { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
    power_per_second = 0,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "empty-natural-gas-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "natural-gas", quality = "normal", amount_per_second = 125, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "natural-gas-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "lime", quality = "normal" },
    products = {
      { type = "item", name = "lime", quality = "normal", amount_per_second = 2 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "coke", quality = "normal", amount_per_second = 3 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 2 },
    },
    power_per_second = 2066666.6666666667,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "refsyngas-from-meth", quality = "normal" },
    products = {
      { type = "fluid", name = "refsyngas", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 15, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 15, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 32.5, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "syngas", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "methanol", quality = "normal", amount_per_second = 50, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "cadaveric-arum-4", quality = "normal" },
    products = {
      { type = "item", name = "cadaveric-arum", quality = "normal", amount_per_second = 0.14000000000000002 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.035000000000000004 },
      { type = "item", name = "sand", quality = "normal", amount_per_second = 0.025 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.01 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.015000000000000002 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.045 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "cadaveric-arum-seeds", quality = "normal", amount_per_second = 0.185 },
      { type = "item", name = "stone-wool", quality = "normal", amount_per_second = 0.005 },
      { type = "item", name = "blood-meal", quality = "normal", amount_per_second = 0.05 },
      { type = "fluid", name = "coal-gas", quality = "normal", amount_per_second = 0.075, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 2.5, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 0.25, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1860000,
    pollution_per_second = -0.049999999999999991,
  },
}

table.insert(cases, {
    name = "explorer catalyst (fuel-cell-dissolve loop -> limestone) runs the chain without cheating",
    xfail = true,
    run = function()
        local problem = cp.create_problem("explorer-limestone", constraints_limestone, lines_limestone)
        local state, vars = harness.solve_to_completion(lp, problem,
            { tolerance = 1e-6, iterate_limit = 600 })
        harness.assert_eq(state, "finished", "solver_state")
        local cheat, has_initial = cheat_and_imports(vars)
        harness.assert_true(has_initial, "imports declared external inputs")
        harness.assert_near(cheat, 0, 1e-3,
            "limestone + catalyst from the real chain + imports, not shortage (cheat = 0.82 today)")
    end,
})

return cases
