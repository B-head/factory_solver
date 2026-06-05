-- Two real all-technologies pyanodon chains captured verbatim from the chain
-- explorer (dump_constraints / dump_normalized_lines; cycle, void=ex, nosrc=ex,
-- target=trapdown, closure=off). Coverage that create_problem formalizes these
-- tangled biological topologies and the IPM solves them to a finished state:
--   * seed 9  (-> auog-food-02): solves clean -- no shortage.
--   * seed 25 (-> scrondrix): solves to a finished partial-shortage (cheat
--     ~0.6337) -- a catalyst loop whose net-zero catalyst the LP fabricates
--     through |shortage_source| rather than running an unbootstrappable cycle.
local harness = require "tests/harness"
local lp = require "solver/linear_programming"
local cp = require "solver/create_problem"
local constraints9 = {
  { type = "item", name = "auog-food-02", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines9 = {
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
  {
    recipe_typed_name = { type = "recipe", name = "empty-carbolic-oil-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "carbolic-oil", quality = "normal", amount_per_second = 125, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "carbolic-oil-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-4", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.175 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.025 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.054166666666666679 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 2.0833333333333335, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.2916666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.16666666666666665, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "fertilizer-3", quality = "normal" },
    products = {
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 2 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 4 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 4 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "seaweed", quality = "normal", amount_per_second = 2 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "soil-separation-2", quality = "normal" },
    products = {
      { type = "item", name = "sand", quality = "normal", amount_per_second = 4.333333333333333 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.66666666666666661 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 1 },
    },
    ingredients = {
      { type = "item", name = "soil", quality = "normal", amount_per_second = 6.666666666666667 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-3", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.048214285714285712 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.010714285714285716 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0035714285714285712 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.89285714285714288, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.035714285714285712, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-super-10", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 88.166666666666671 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 3.3333333333333335 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 1.6666666666666668 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 16.666666666666668 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 2.5 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.05 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 5 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 166.66666666666666, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 6261666.666666667,
    pollution_per_second = 0,
  },
  {
    recipe_typed_name = { type = "recipe", name = "hydrogen-chloride-quartz", quality = "normal" },
    products = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "quartz-tube", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "hydrogen-chloride", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "item", name = "quartz-tube", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "chlorine", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 217000,
    pollution_per_second = 0.066666666666666661,
  },
  {
    recipe_typed_name = { type = "recipe", name = "syngas2", quality = "normal" },
    products = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.3333333333333333 },
      { type = "fluid", name = "syngas", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "tar", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "coal-gas", quality = "normal", amount_per_second = 16.666666666666668, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "oxygen", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 33.333333333333336, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "coalbed-gas-to-coalgas", quality = "normal" },
    products = {
      { type = "fluid", name = "coal-gas", quality = "normal", amount_per_second = 40, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.1 },
      { type = "fluid", name = "coalbed-gas", quality = "normal", amount_per_second = 40, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "pressured-water", quality = "normal" },
    products = {
      { type = "fluid", name = "pressured-water", quality = "normal", amount_per_second = 250, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 250, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.0009999999999999998,
  },
  {
    recipe_typed_name = { type = "recipe", name = "extract-gas-from-coalbed-4", quality = "normal" },
    products = {
      { type = "fluid", name = "coalbed-gas", quality = "normal", amount_per_second = 41.666666666666664, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "drill-head", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "fluid", name = "pressured-water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "oxygen", quality = "normal", amount_per_second = 41.666666666666664, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 775000,
    pollution_per_second = 0.83333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "ref-to-light-oil", quality = "normal" },
    products = {
      { type = "fluid", name = "light-oil", quality = "normal", amount_per_second = 40, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 200, minimum_temperature = 150, maximum_temperature = 150 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 20, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "refsyngas", quality = "normal", amount_per_second = 15, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hydrogen", quality = "normal", amount_per_second = 25, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1550000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "coalbed-gas-to-refsyngas", quality = "normal" },
    products = {
      { type = "fluid", name = "refsyngas", quality = "normal", amount_per_second = 75, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.25 },
      { type = "fluid", name = "coalbed-gas", quality = "normal", amount_per_second = 50, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "hot-air", quality = "normal", amount_per_second = 75, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.83333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "oleochemicals-distilation", quality = "normal" },
    products = {
      { type = "item", name = "raw-coal", quality = "normal", amount_per_second = 1.6000000000000001 },
      { type = "fluid", name = "syngas", quality = "normal", amount_per_second = 200, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "petroleum-gas", quality = "normal", amount_per_second = 40, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "acidgas", quality = "normal", amount_per_second = 40, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "fluid", name = "oleochemicals", quality = "normal", amount_per_second = 100, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "oxygen", quality = "normal", amount_per_second = 160, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "Moss-4", quality = "normal" },
    products = {
      { type = "item", name = "moss", quality = "normal", amount_per_second = 0.05 },
    },
    ingredients = {
      { type = "item", name = "stone", quality = "normal", amount_per_second = 0.03125 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.0234375 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.015625 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 0.15625, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.15625, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 103333.33333333334,
    pollution_per_second = -0.58333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "kicalk-mk02-breeder", quality = "normal" },
    products = {
      { type = "item", name = "kicalk-mk02", quality = "normal", amount_per_second = 0.0031746031746031744 },
      { type = "item", name = "kicalk-mk02", quality = "normal", amount_per_second = 0.00079365079365079358 },
      { type = "item", name = "kicalk-seeds", quality = "normal", amount_per_second = 0.0011904761904761905 },
      { type = "item", name = "kicalk-seeds-mk02", quality = "normal", amount_per_second = 0.0003968253968253968 },
    },
    ingredients = {
      { type = "item", name = "small-lamp", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "item", name = "rich-clay", quality = "normal", amount_per_second = 0.0079365079365079358 },
      { type = "item", name = "kicalk-seeds-mk02", quality = "normal", amount_per_second = 0.003968253968253968 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 0.31746031746031744, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "flutec-pp6", quality = "normal", amount_per_second = 0.03968253968253968, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 930000,
    pollution_per_second = -0.25000000000000004,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tar-refining-tops", quality = "normal" },
    products = {
      { type = "fluid", name = "light-oil", quality = "normal", amount_per_second = 12.5, minimum_temperature = 25, maximum_temperature = 25 },
      { type = "fluid", name = "carbolic-oil", quality = "normal", amount_per_second = 12.5, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "naphthalene-oil", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "fluid", name = "middle-oil", quality = "normal", amount_per_second = 25, minimum_temperature = 10, maximum_temperature = 10 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 25, minimum_temperature = 250, maximum_temperature = 2000 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "extract-methane-from-coalbed-2", quality = "normal" },
    products = {
      { type = "fluid", name = "methane", quality = "normal", amount_per_second = 41.666666666666664, minimum_temperature = 15, maximum_temperature = 15 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "filtration-media", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "item", name = "drill-head", quality = "normal", amount_per_second = 0.083333333333333321 },
      { type = "fluid", name = "pressured-water", quality = "normal", amount_per_second = 208.33333333333334, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 41.666666666666664, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 775000,
    pollution_per_second = 0.83333333333333339,
  },
  {
    recipe_typed_name = { type = "recipe", name = "ralesia-4", quality = "normal" },
    products = {
      { type = "item", name = "ralesia", quality = "normal", amount_per_second = 0.13076923076923077 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.015384615384615385 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.023076923076923079 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.038461538461538463 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.015384615384615385 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.023076923076923079 },
      { type = "item", name = "ralesia-seeds", quality = "normal", amount_per_second = 0.035384615384615392 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.15384615384615385, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "syngas", quality = "normal", amount_per_second = 0.15384615384615385, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.076923076923076925, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = -0.083333333333333357,
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
    recipe_typed_name = { type = "recipe", name = "auog-food-02", quality = "normal" },
    products = {
      { type = "item", name = "auog-food-02", quality = "normal", amount_per_second = 0.5 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "casein", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "wood-seeds", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "ralesia", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "fawogae", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "moss", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "seaweed", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "starch", quality = "normal", amount_per_second = 0.4 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "tree-mk04", quality = "normal" },
    products = {
      { type = "item", name = "tree-mk04", quality = "normal", amount_per_second = 0.0030303030303030303 },
    },
    ingredients = {
      { type = "item", name = "planter-box", quality = "normal", amount_per_second = 0.0030303030303030303 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.0090909090909090917 },
      { type = "item", name = "wood-seedling-mk04", quality = "normal", amount_per_second = 0.0090909090909090917 },
      { type = "item", name = "sodium-alginate", quality = "normal", amount_per_second = 0.0030303030303030303 },
      { type = "fluid", name = "muddy-sludge", quality = "normal", amount_per_second = 0.60606060606060606, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 465000,
    pollution_per_second = -0.58333333333333348,
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
}

local constraints25 = {
  { type = "item", name = "scrondrix", quality = "normal", limit_type = "equal", limit_amount_per_second = 1 },
}

local lines25 = {
  {
    recipe_typed_name = { type = "recipe", name = "navens-1", quality = "normal" },
    products = {
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.0013548387096774193 },
    },
    ingredients = {
      { type = "item", name = "fungal-substrate-02", quality = "normal", amount_per_second = 0.00038709677419354826 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.00096774193548387064 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.00096774193548387064 },
      { type = "item", name = "navens-spore", quality = "normal", amount_per_second = 0.00038709677419354826 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.019354838709677416, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "navens-mk02", quality = "normal" },
    products = {
      { type = "item", name = "navens-mk02", quality = "normal", amount_per_second = 3.2258064516129026e-06 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.0003225806451612903 },
    },
    ingredients = {
      { type = "item", name = "fungal-substrate-02", quality = "normal", amount_per_second = 0.003225806451612903 },
      { type = "item", name = "manure", quality = "normal", amount_per_second = 0.0064516129032258061 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.0064516129032258061 },
      { type = "item", name = "navens-spore", quality = "normal", amount_per_second = 0.003225806451612903 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.0012903225806451612 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.32258064516129026, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "numal-raising-6", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "numal", quality = "normal", amount_per_second = 0.0375 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "numal-egg", quality = "normal", amount_per_second = 0.066666666666666661 },
    },
    ingredients = {
      { type = "item", name = "arqad-honey-barrel", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.0125 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "caged-mukmoux", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "arthurian-egg", quality = "normal", amount_per_second = 0.0375 },
      { type = "item", name = "numal-egg", quality = "normal", amount_per_second = 0.0875 },
      { type = "item", name = "numal-food-02", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "navens-mk03", quality = "normal" },
    products = {
      { type = "item", name = "navens-mk03", quality = "normal", amount_per_second = 2.5806451612903225e-06 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.00038709677419354826 },
    },
    ingredients = {
      { type = "item", name = "fungal-substrate-02", quality = "normal", amount_per_second = 0.003225806451612903 },
      { type = "item", name = "manure", quality = "normal", amount_per_second = 0.0064516129032258061 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.0064516129032258061 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.00064516129032258061 },
      { type = "item", name = "navens-spore-mk02", quality = "normal", amount_per_second = 0.003225806451612903 },
      { type = "item", name = "navens-mk02", quality = "normal", amount_per_second = 0.0012903225806451612 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.64516129032258052, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "Scrondrix-Manure-4", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "manure", quality = "normal", amount_per_second = 0.04 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "wood-seeds", quality = "normal", amount_per_second = 0.028571428571428577 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.019047619047619049 },
      { type = "item", name = "raw-fiber", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "salt", quality = "normal", amount_per_second = 0.0095238095238095237 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-mukmoux", quality = "normal" },
    products = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.26666666666666665 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 4.333333333333333, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-mukmoux", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "numal-food-02", quality = "normal" },
    products = {
      { type = "item", name = "numal-food-02", quality = "normal", amount_per_second = 0.6 },
    },
    ingredients = {
      { type = "item", name = "albumin", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "xyhiphoe", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "shell", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "ralesia", quality = "normal", amount_per_second = 0.4 },
      { type = "item", name = "sap-seeds", quality = "normal", amount_per_second = 0.8 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.7 },
      { type = "item", name = "fawogae", quality = "normal", amount_per_second = 0.3 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.2 },
      { type = "fluid", name = "milk", quality = "normal", amount_per_second = 10, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 5, minimum_temperature = 10, maximum_temperature = 100 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "navens-spore-mk02", quality = "normal" },
    products = {
      { type = "item", name = "navens-spore-mk02", quality = "normal", amount_per_second = 0.2 },
    },
    ingredients = {
      { type = "item", name = "navens-mk02", quality = "normal", amount_per_second = 0.04 },
    },
    power_per_second = 155000,
    pollution_per_second = 0.016666666666666665,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-seeds", quality = "normal" },
    products = {
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.8 },
    },
    ingredients = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.4 },
    },
    power_per_second = 129166.66666666667,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "Scrondrix-Manure-3", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "manure", quality = "normal", amount_per_second = 0.020952380952380949 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "wood-seeds", quality = "normal", amount_per_second = 0.028571428571428577 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.019047619047619049 },
      { type = "item", name = "raw-fiber", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "salt", quality = "normal", amount_per_second = 0.0095238095238095237 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-kor", quality = "normal" },
    products = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 1, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-korlex", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
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
    recipe_typed_name = { type = "recipe", name = "grod-4", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.175 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.025 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "pesticide-mk02", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.054166666666666679 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0041666666666666661 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.125 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.02083333333333333 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 2.0833333333333335, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.2916666666666667, minimum_temperature = 10, maximum_temperature = 100 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.16666666666666665, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-3", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.048214285714285712 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "coarse", quality = "normal", amount_per_second = 0.010714285714285716 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "pesticide-mk01", quality = "normal", amount_per_second = 0.0035714285714285712 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.017857142857142856 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.008928571428571427 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.89285714285714288, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "slacked-lime", quality = "normal", amount_per_second = 0.035714285714285712, minimum_temperature = 10, maximum_temperature = 100 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-2", quality = "normal" },
    products = {
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.019318181818181817 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.011363636363636365 },
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.011363636363636365 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.011363636363636365 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.0056818181818181825 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.56818181818181825, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "arthurian-egg-mk03-gmo", quality = "normal" },
    products = {
      { type = "item", name = "arthurian-egg-mk03", quality = "normal", amount_per_second = 4.4444444444444438e-05 },
      { type = "item", name = "arthurian-egg-mk02", quality = "normal", amount_per_second = 0.0044444444444444446 },
      { type = "item", name = "arthurian-egg", quality = "normal", amount_per_second = 0.003333333333333333 },
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.044444444444444446 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.011111111111111112 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.044444444444444446 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "alien-sample-03", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "caged-ulric", quality = "normal", amount_per_second = 0.011111111111111112 },
      { type = "item", name = "cocoon", quality = "normal", amount_per_second = 0.022222222222222223 },
      { type = "item", name = "arthurian", quality = "normal", amount_per_second = 0.022222222222222223 },
    },
    power_per_second = 516666.66666666669,
    pollution_per_second = 0.0083333333333333321,
  },
  {
    recipe_typed_name = { type = "recipe", name = "ralesia-4", quality = "normal" },
    products = {
      { type = "item", name = "ralesia", quality = "normal", amount_per_second = 0.13076923076923077 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 0.015384615384615385 },
      { type = "item", name = "soil", quality = "normal", amount_per_second = 0.023076923076923079 },
      { type = "item", name = "biomass", quality = "normal", amount_per_second = 0.038461538461538463 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.015384615384615385 },
      { type = "item", name = "urea", quality = "normal", amount_per_second = 0.023076923076923079 },
      { type = "item", name = "ralesia-seeds", quality = "normal", amount_per_second = 0.035384615384615392 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 0.15384615384615385, minimum_temperature = 15, maximum_temperature = 500 },
      { type = "fluid", name = "syngas", quality = "normal", amount_per_second = 0.15384615384615385, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "flue-gas", quality = "normal", amount_per_second = 0.076923076923076925, minimum_temperature = 15, maximum_temperature = 100 },
    },
    power_per_second = 413333.33333333337,
    pollution_per_second = -0.083333333333333357,
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
    recipe_typed_name = { type = "recipe", name = "empty-water-barrel", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 2.5 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 125, minimum_temperature = 15, maximum_temperature = 15 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 2.5 },
    },
    power_per_second = 206666.66666666669,
    pollution_per_second = 0.01666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "grod-mk02", quality = "normal" },
    products = {
      { type = "item", name = "grod-mk02", quality = "normal", amount_per_second = 2.0833333333333335e-05 },
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.002083333333333333 },
    },
    ingredients = {
      { type = "item", name = "limestone", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "fertilizer", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "item", name = "grod", quality = "normal", amount_per_second = 0.0083333333333333321 },
      { type = "item", name = "grod-seeds", quality = "normal", amount_per_second = 0.041666666666666661 },
      { type = "fluid", name = "carbon-dioxide", quality = "normal", amount_per_second = 1.25, minimum_temperature = 15, maximum_temperature = 100 },
      { type = "fluid", name = "water", quality = "normal", amount_per_second = 4.166666666666667, minimum_temperature = 15, maximum_temperature = 500 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = -0.083333333333333357,
  },
  {
    recipe_typed_name = { type = "recipe", name = "phadai-food-02", quality = "normal" },
    products = {
      { type = "item", name = "phadai-food-02", quality = "normal", amount_per_second = 0.5 },
    },
    ingredients = {
      { type = "item", name = "ash", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "casein", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "bones", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.8 },
      { type = "item", name = "native-flora", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "fish", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "ralesia", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "rennea-seeds", quality = "normal", amount_per_second = 1 },
      { type = "item", name = "yotoi-fruit", quality = "normal", amount_per_second = 0.5 },
      { type = "item", name = "plastic-bar", quality = "normal", amount_per_second = 0.6 },
      { type = "fluid", name = "steam", quality = "normal", amount_per_second = 10, minimum_temperature = 15, maximum_temperature = 2000 },
    },
    fuel_ingredient = { type = "item", name = "charcoal-briquette", quality = "normal", amount_per_second = 0.00041666666666666661 },
    power_per_second = 0,
    pollution_per_second = 0.2,
  },
  {
    recipe_typed_name = { type = "recipe", name = "Scrondrix-4", quality = "normal" },
    products = {
      { type = "item", name = "barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "scrondrix", quality = "normal", amount_per_second = 0.020952380952380949 },
    },
    ingredients = {
      { type = "item", name = "water-barrel", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "bedding", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "antiviral", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "gh", quality = "normal", amount_per_second = 0.0019047619047619049 },
      { type = "item", name = "scrondrix-pup", quality = "normal", amount_per_second = 0.019047619047619049 },
      { type = "item", name = "wood-seeds", quality = "normal", amount_per_second = 0.028571428571428577 },
      { type = "item", name = "yotoi-leaves", quality = "normal", amount_per_second = 0.019047619047619049 },
      { type = "item", name = "raw-fiber", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "navens", quality = "normal", amount_per_second = 0.0095238095238095237 },
      { type = "item", name = "salt", quality = "normal", amount_per_second = 0.0095238095238095237 },
    },
    power_per_second = 1033333.3333333334,
    pollution_per_second = 0.049999999999999991,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-ulrics", quality = "normal" },
    products = {
      { type = "item", name = "bonemeal", quality = "normal", amount_per_second = 0.2 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.1 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 2.6666666666666665, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-ulric", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
  {
    recipe_typed_name = { type = "recipe", name = "full-render-arthurian", quality = "normal" },
    products = {
      { type = "item", name = "bones", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "meat", quality = "normal", amount_per_second = 0.16666666666666665 },
      { type = "item", name = "skin", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "item", name = "mukmoux-fat", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "guts", quality = "normal", amount_per_second = 0.13333333333333333 },
      { type = "item", name = "cage", quality = "normal", amount_per_second = 0.03333333333333333 },
      { type = "item", name = "brain", quality = "normal", amount_per_second = 0.066666666666666661 },
      { type = "fluid", name = "blood", quality = "normal", amount_per_second = 1.6666666666666668, minimum_temperature = 10, maximum_temperature = 10 },
    },
    ingredients = {
      { type = "item", name = "caged-arthurian", quality = "normal", amount_per_second = 0.03333333333333333 },
    },
    power_per_second = 310000,
    pollution_per_second = 0.1666666666666667,
  },
}

-- Total penalty mass on the shortage / elastic hatches (the "cheat").
local function cheat_of(vars)
    local cheat = 0
    if vars and vars.x then
        for k, v in pairs(vars.x) do
            if math.abs(v) > 1e-6 and (k:find("|shortage_source|", 1, true)
                    or k:find("|elastic|", 1, true)) then
                cheat = cheat + math.abs(v)
            end
        end
    end
    return cheat
end

local function solve(problem)
    return harness.solve_to_completion(lp, problem,
        { tolerance = 1e-6, iterate_limit = 600 })
end

local cases = {}

cases[#cases + 1] = {
    name = "pyanodon seed 9 (-> auog-food-02) formalizes and solves clean",
    run = function()
        local state, vars = solve(cp.create_problem("seed9", constraints9, lines9))
        harness.assert_eq(state, "finished", "converges")
        harness.assert_near(cheat_of(vars), 0, 1e-3, "no shortage")
    end,
}

cases[#cases + 1] = {
    name = "pyanodon seed 25 (-> scrondrix) formalizes and solves to a finished partial-shortage",
    run = function()
        local state, vars = solve(cp.create_problem("seed25", constraints25, lines25))
        harness.assert_eq(state, "finished", "converges")
        harness.assert_near(cheat_of(vars), 0.6337, 1e-2,
            "catalyst loop fabricates its net-zero catalyst (~0.6337)")
    end,
}

return cases
