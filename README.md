The Factorio calculator. Calculate the quantities of machines and ingredients required in a factory to hit your target production rate.

A powerful solver based on interior-point methods for linear programming allows factories with complex recipe chains and loops to be calculated without extra hassle.

## Features

- Calculates the required quantities automatically for every recipe in a
  chain.
- Supports recipe chains with loops, including quality recycling cascades
  and byproduct-heavy chains (e.g. Fulgora recycling).
- Folds modules, beacons, quality tiers, and force productivity research
  bonuses into the calculation.
- Calculates the total power used / generated and pollution emitted.
- Treats generators, boilers, mining, pumping, labs, fusion reactors,
  thrusters, agricultural towers, and item spoilage as virtual recipes.
- Accepts upper, lower, or equal bound constraints on machines and
  ingredients.
- Supports Factorio 2.0 / Space Age (quality tiers, fluid temperatures).

Warning: Multiplayer games have not been tested. Note that solution data may be lost if the mod is used in multiplayer.

## How to use

1. Click the blue '+' button to create a new solution.
2. Choose a target material whose production rate you want to set.
3. Choose a recipe that produces it as a product or uses it as an ingredient.
4. Click on a material button in the "Products" or "Ingredients" column to add a recipe.
5. Click on a button in the "Machine" column to set the machine, fuel, and modules to be used.
6. Adjust the constraints to set the target production rate.

The number in the "Required" column is the quantity of machines required for each recipe. Use this as a guide to build your factory!

Note: Constraints can be added by right-clicking material or recipe buttons.

## Migrating from Factory Planner or Helmod

Existing Factory Planner or Helmod factories can be brought over without
rebuilding them by hand:

1. In Factory Planner or Helmod, export the factory / model to a shared
   string.
2. In factory_solver, click the import button in the solution list toolbar
   and paste the string. The source format is detected automatically.
3. Pick which factories to bring in and confirm.

A symmetric export back to Factory Planner or Helmod is also available from
the export button next to it, in case you want to round-trip a solution.

Note: shared-string import / export between factory_solver, Factory Planner,
and Helmod is best-effort. The three calculators do not share the same
feature set, so some adjustments may be needed after an import; warnings in
the chat log point out what was dropped or coerced.

## Enabling quality modules

Qualities above normal start locked, so quality modules have no effect on the calculation until you unlock them in the solver:

1. Click the "Research bonuses" button to open the dialog.
2. Under "Unlocked qualities", check each quality you have researched.
3. Click "Confirm" to apply.

The solver then expands recipes into the quality cascade, and quality modules shift production toward the higher tiers.

## Why does the UI look like Factory Planner?

I originally developed this LP solver as an [additional feature of Factory Planner](https://github.com/ClaudeMetz/FactoryPlanner/pull/25). However, it was not merged, so I built another mod from scratch around it.
