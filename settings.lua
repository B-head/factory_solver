data:extend({
    -- Per-player toggle: swap the placement of the Products and Ingredients
    -- sections in the solution editor table (left/right columns) and in the
    -- add-production-line dialog (output group <-> input group). Default off
    -- keeps the shipped ordering. Read at GUI build time via
    -- common.is_product_ingredient_swapped; per-player settings are MP-synced,
    -- so reading one inside a GUI handler stays deterministic across clients.
    {
        type = "bool-setting",
        name = "factory-solver-swap-recipe-io-placement",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "a",
    },
})
