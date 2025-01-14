The Factorio calculator. Calculate quantities of machine and ingredient required in a factory to achieve materials production speed.

The powerful solver based on IPMs for LP allows factories with complex recipe chains and loops to be calculated without extra hassle.

## Feature

- A recipe chain is configured to automatically calculate for each recipe.
- Supports recipe chains including loops. (still incomplete)
- Include the effects of modules, beacons and quality in calculation.
- Calculate the total power used/generated and pollution emitted.
- Generators and boilers etc. are treated as virtual recipes. (still incomplete)
- Set limited machine and material constraints for calculations.

Warning: Multiplayer games have not been tested. Note that solution data may be lost if used.

## How to use

1. Click the blue '+' button to create a new solution.
2. Choose the material to target for production speed.
3. Choose a recipe to product or ingredient that material.
4. Click on a material button in "Products" column or "Ingredients" column to add a recipe.
5. Click on a button in "Machine" column to set a machine, fuel and modules to be used.
6. Adjust the constraints to set the production speed to target.

The number in "Required" column is the quantity of machines required for each recipe. Use this as a guide to build your factory!

Note: Constraints can be added by right-click on material or recipe buttons.

## Why does the UI look like Factory Planner?

I originally developed the solver for linear problems as an [additional feature of Factory Planner](https://github.com/ClaudeMetz/FactoryPlanner/pull/25). However, that solver was not merged, so I decided to develop another mod from scratch specifically for that solver.
