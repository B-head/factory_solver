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
- Supports Factorio 2.0 / Space Age (quality tiers).
- Splits per-fluid recipes by temperature and bridges them automatically.
- Includes a Build assistant that works as a build to-do list: every machine
  and beacon to place, with a pipette to grab each one and a Done/TODO column
  to check off as you go.
- Lets you declare external sources and sinks for any material to steer or
  unstick loop solutions.

Warning: Multiplayer games have not been tested. Note that solution data may be lost if the mod is used in multiplayer.

## How to use

The editor and each dialog guide you through this in-game; the steps below are for reference.

1. Click the blue '+' button to create a new solution.
2. Choose a target material whose production rate you want to set.
3. Choose a recipe that produces it as a product or uses it as an ingredient.
4. Click on a material button in the "Products" or "Ingredients" column to add a recipe.
5. Click on a button in the "Machine" column to set the machine, fuel, and modules to be used.
6. Adjust the constraints to set the target production rate.

The number in the "Required" column is the quantity of machines required for each recipe. Use this as a guide to build your factory!

Note: Constraints can be added by right-clicking material or recipe buttons.

## Migrating from Factory Planner, Helmod, or YAFC

Existing Factory Planner, Helmod, or YAFC factories can be brought over without
rebuilding them by hand:

1. In Factory Planner, Helmod, or YAFC, export the factory / page to a shared
   string.
2. In Factory solver, click the import button in the solution list toolbar
   and paste the string. The source format is detected automatically.
3. Pick which factories to bring in and confirm.

A symmetric export back to Factory Planner, Helmod, or YAFC is also available
from the export button next to it, in case you want to round-trip a solution.

Note: shared-string import / export between Factory solver, Factory Planner,
Helmod, and YAFC is best-effort. The calculators do not share the same
feature set, so some adjustments may be needed after an import; warnings in
the chat log point out what was dropped or coerced. (For YAFC specifically:
real recipes round-trip cleanly, and Factory solver's virtual recipes for
reactors, generators, boilers, spoilage, and pumping map onto YAFC's equivalent
"Mechanics" recipes; the remaining virtual recipes — mining, rocket launches,
agriculture, fusion, thrusters, research — have no YAFC counterpart and are
dropped from the exported page with a warning.)

## Enabling quality modules

Qualities above normal start locked, so quality modules have no effect on the calculation until you unlock them in the solver:

1. Click the "Research bonuses" button to open the dialog.
2. Under "Unlocked qualities", check each quality you have researched.
3. Click "Confirm" to apply.

The solver then expands recipes into the quality cascade, and quality modules shift production toward the higher tiers.

## External source / sink

Factory solver provides a *source* and a *sink* for every item, fluid, and
heat. A source supplies its material from outside the factory; a sink
discharges its material out of the factory. Material drawn from a source is
added to "Initial ingredients", and material sent to a sink is added to "Final
products".

You can add one from the dedicated "External" tab in the constraint picker, or
straight from a material in the recipe picker — a material's source appears
under "Recipes for product" and its sink under "Recipes for ingredient".

These source and sink recipes are generated as hidden recipes, so they are
filtered out of the recipe picker by default. Flip the picker's "Hidden" toggle
to "Show" to reveal them alongside the regular recipes.

You normally don't need these — the solver already balances surplus and
shortage on its own. They are a manual override for the cases where you want to
decide the factory boundary yourself:

- In a chain that contains a cycle (loop), use them to hand-pick which
  materials or products are supplied from / discharged outside the factory,
  instead of leaving the choice to the solver.
- When the solver returns a solution that is mostly zero (a degenerate loop it
  cannot anchor), inserting a source or sink inside the cycle gives it the
  external input/output it needs and can fix the result.

Source recipes are priced like an ordinary external input, so the solver only
draws on them when it helps; sink recipes are free, so surplus flows into them
freely.

## Why does the UI look like Factory Planner?

I originally developed this LP solver as an [additional feature of Factory Planner](https://github.com/ClaudeMetz/FactoryPlanner/pull/25). However, it was not merged, so I built another mod from scratch around it.
