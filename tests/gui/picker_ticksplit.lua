-- GUI tier test: the tick-split picker build (ui/picker_build.lua) must be
-- budget-invariant -- building a picker in one shot (finish, budget=math.huge)
-- and building it chunked (advance_all, BUTTON_BUDGET per tick) must yield the
-- IDENTICAL element tree. A mismatch means the cursor / open_group / close_group
-- logic corrupts the tree at a budget boundary. Covers both pickers that use the
-- shared helper: production_line_adder (per-group sub-tables) and constraint_adder
-- (one table + per-subgroup padding via close_group). Data-agnostic: the reference
-- item / item-group is discovered from the live caches and reused for both paths,
-- so process-local pairs() nondeterminism cannot skew the comparison.
--
-- Verdict: prints exactly one "GUITEST PASS:" / "GUITEST FAIL:" line.
local fs_util = package.loaded["__factory_solver__/fs_util.lua"]
local tn = package.loaded["__factory_solver__/manage/typed_name.lua"]
local save = package.loaded["__factory_solver__/manage/save.lua"]
local picker_build = package.loaded["__factory_solver__/ui/picker_build.lua"]
local pla = package.loaded["__factory_solver__/ui/production_line_adder.lua"]
local constraint_adder = package.loaded["__factory_solver__/ui/constraint_adder.lua"]

-- [type|sprite] per descendant in DFS order; .sprite only exists on sprite(-button).
local function signature(root)
    local sig = {}
    local stack = { root }
    while #stack > 0 do
        local cur = table.remove(stack)
        local kids = cur.children
        -- Push in reverse so the recorded order is stable left-to-right.
        for i = #kids, 1, -1 do stack[#stack + 1] = kids[i] end
        for _, c in ipairs(kids) do
            local s = ""
            if c.type == "sprite-button" or c.type == "sprite" then s = c.sprite or "" end
            sig[#sig + 1] = c.type .. "|" .. s
        end
    end
    return sig
end

local function same(a, b)
    if #a ~= #b then return false, "length " .. #a .. " vs " .. #b end
    for i = 1, #a do
        if a[i] ~= b[i] then return false, "index " .. i .. " (" .. a[i] .. " vs " .. b[i] .. ")" end
    end
    return true
end

local function finish_all(pix)
    local pd = save.get_player_data(pix)
    if not pd.picker_builds then return end
    local keys = {}
    for k in pairs(pd.picker_builds) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do picker_build.finish(pix, k) end
end

local function advance_all_to_done(pix)
    local pd = save.get_player_data(pix)
    local guard = 0
    while pd.picker_builds and next(pd.picker_builds) do
        picker_build.advance_all()
        guard = guard + 1
        if guard > 20000 then error("advance_all did not converge") end
    end
end

local ok, err = pcall(function()
    local p = assert(game.players[1], "no player in save")
    local pix = p.index
    local screen = p.gui.screen
    local player_data = save.get_player_data(pix)
    local rel = save.get_relation_to_recipes(pix)
    player_data.hidden_craft_visible = true
    player_data.unresearched_craft_visible = true

    local fails = {}

    ----------------------------------------------------------------------------
    -- production_line_adder: pick an item reference that has product recipes.
    ----------------------------------------------------------------------------
    local ref_name
    for name, info in pairs(rel.item) do
        if prototypes.item[name] and info.recipe_for_product and #info.recipe_for_product > 0 then
            ref_name = name
            break
        end
    end
    if not ref_name then
        fails[#fails + 1] = "no item with product recipes in relation cache"
    else
        local data = {
            typed_name = tn.create_typed_name("item", ref_name, "normal"),
            is_choose_product = true,
            is_choose_ingredient = true,
        }
        local function open_pla()
            if screen.factory_solver_production_line_adder then
                screen.factory_solver_production_line_adder.destroy()
            end
            fs_util.add_gui(screen, pla, data)
            return assert(fs_util.find_lower(screen.factory_solver_production_line_adder, "recipe_choose_flow"))
        end

        local flow = open_pla(); finish_all(pix)
        local sig_finish = signature(flow)
        flow = open_pla(); advance_all_to_done(pix)
        local sig_advance = signature(flow)
        screen.factory_solver_production_line_adder.destroy()

        local eq, why = same(sig_finish, sig_advance)
        if #sig_finish == 0 then
            fails[#fails + 1] = "production_line_adder(" .. ref_name .. ") built an empty tree"
        elseif not eq then
            fails[#fails + 1] = "production_line_adder(" .. ref_name .. ") finish!=advance @ " .. why
        end
    end

    ----------------------------------------------------------------------------
    -- constraint_adder: item tab, first item-group that has items.
    ----------------------------------------------------------------------------
    local groups = fs_util.sort_prototypes(fs_util.to_list(prototypes.item_group))
    local group_name
    for _, group in ipairs(groups) do
        for _, subgroup in ipairs(group.subgroups) do
            -- get_item_filtered returns a LuaCustomTable; next() throws on it, so
            -- probe emptiness via pairs (which the engine supports through __pairs).
            local items = prototypes.get_item_filtered { { filter = "subgroup", subgroup = subgroup.name } }
            local has_any = false
            for _ in pairs(items) do has_any = true; break end
            if has_any then group_name = group.name; break end
        end
        if group_name then break end
    end
    if not group_name then
        fails[#fails + 1] = "no item-group with items found"
    else
        player_data.selected_filter_type = "item"
        player_data.selected_filter_group["item"] = group_name

        if screen.factory_solver_constraint_adder then screen.factory_solver_constraint_adder.destroy() end
        fs_util.add_gui(screen, constraint_adder)
        local dialog = screen.factory_solver_constraint_adder
        local picker = assert(fs_util.find_lower(dialog, "constraint_picker"))

        fs_util.dispatch_to_subtree(dialog, "on_filter_group_changed"); finish_all(pix)
        local sig_finish = signature(picker)
        fs_util.dispatch_to_subtree(dialog, "on_filter_group_changed"); advance_all_to_done(pix)
        local sig_advance = signature(picker)
        dialog.destroy()

        local eq, why = same(sig_finish, sig_advance)
        if #sig_finish == 0 then
            fails[#fails + 1] = "constraint_adder(item/" .. group_name .. ") built an empty tree"
        elseif not eq then
            fails[#fails + 1] = "constraint_adder(item/" .. group_name .. ") finish!=advance @ " .. why
        end
    end

    if #fails > 0 then
        rcon.print("GUITEST FAIL: " .. table.concat(fails, " ; "))
    else
        rcon.print("GUITEST PASS: picker tick-split budget-invariant (production_line_adder=" .. tostring(ref_name)
            .. ", constraint_adder item/" .. tostring(group_name) .. ")")
    end
end)
if not ok then
    rcon.print("GUITEST FAIL: picker_ticksplit errored: " .. tostring(err))
end
