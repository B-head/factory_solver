data:extend({
    -- Per-player toggle: swap the placement of the Products and Ingredients
    -- sections in the solution editor table (left/right columns) and in the
    -- add-production-line dialog (output group <-> input group). Default off
    -- keeps the shipped ordering. Read at GUI build time via
    -- common.is_recipe_io_placement_swapped; per-player settings are MP-synced,
    -- so reading one inside a GUI handler stays deterministic across clients.
    {
        type = "bool-setting",
        name = "factory-solver-swap-recipe-io-placement",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "a",
    },
    -- Per-player toggle: reverse the vertical (top-to-bottom) production flow.
    -- Flips the production line row order in the solution editor and the build
    -- assistant (so newly added lines appear at the top), and swaps the Final
    -- products / Initial ingredients sections in the results panel. Display-only
    -- (production_lines is force-shared data and must not be mutated per player);
    -- read via common.is_production_line_order_reversed.
    {
        type = "bool-setting",
        name = "factory-solver-reverse-production-line-order",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "b",
    },
})
