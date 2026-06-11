data:extend({
    -- Per-player layout toggles. The default (false) layout follows Factorio's
    -- engine reading order (ingredients before products, ingredient flow top):
    --   * classic-recipe-io-placement OFF -> Ingredients column left of Products
    --     in the editor, input group above output group in the adder; ON -> the
    --     classic factory_solver placement (Products / output first).
    --   * classic-production-line-order OFF -> production line rows reversed
    --     (newly added lines on top), Initial ingredients above Final products in
    --     the results panel; ON -> the classic order (Final products on top).
    -- The render code is unchanged; common.is_recipe_io_placement_swapped /
    -- is_production_line_order_reversed return the inverse of these settings.
    -- Per-player settings are MP-synced, so reading them inside a GUI handler
    -- stays deterministic across clients.
    {
        type = "bool-setting",
        name = "factory-solver-classic-recipe-io-placement",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "a",
    },
    {
        type = "bool-setting",
        name = "factory-solver-classic-production-line-order",
        setting_type = "runtime-per-user",
        default_value = false,
        order = "b",
    },
})
