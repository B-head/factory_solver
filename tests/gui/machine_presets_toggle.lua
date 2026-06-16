-- GUI tier test: machine_presets builds each preset button's `toggled` state at
-- build time (reading dialog.tags.presets once per table) instead of via a
-- post-build dialog-wide on_preset_changed dispatch that snapshotted dialog.tags
-- per button. This guards that the optimization is behaviour-preserving: the
-- build-time toggled states must be IDENTICAL to what a full on_preset_changed
-- dispatch (the old path) produces. Data-agnostic (any mod set).
--
-- Verdict: prints exactly one "GUITEST PASS:" / "GUITEST FAIL:" line for gui_rcon.ps1.
local fs_util = package.loaded["__factory_solver__/fs_util.lua"]
local save = package.loaded["__factory_solver__/manage/save.lua"]
local picker_build = package.loaded["__factory_solver__/ui/picker_build.lua"]
local machine_presets = package.loaded["__factory_solver__/ui/machine_presets.lua"]

local function collect(root)
    -- index -> toggled, for every button carrying a preset_type tag.
    local out = {}
    local stack = { root }
    while #stack > 0 do
        local cur = table.remove(stack)
        for _, c in ipairs(cur.children) do
            if c.type == "sprite-button" and c.tags and c.tags.preset_type then
                out[c.index] = c.toggled
            end
            stack[#stack + 1] = c
        end
    end
    return out
end

local ok, err = pcall(function()
    local p = assert(game.players[1], "no player in save")
    local pix = p.index
    local screen = p.gui.screen
    save.get_relation_to_recipes(pix)

    -- Reveal hidden + unresearched so the dialog populates its full preset set
    -- (a minimal save has little research, which would otherwise leave only a
    -- handful of buttons to check). Mutates the per-run save copy only.
    local player_data = save.get_player_data(pix)
    player_data.hidden_craft_visible = true
    player_data.unresearched_craft_visible = true

    if screen.factory_solver_machine_presets then screen.factory_solver_machine_presets.destroy() end
    fs_util.add_gui(screen, machine_presets)
    local dialog = screen.factory_solver_machine_presets

    -- The preset sections build via tick-split now (armed on open, not built yet);
    -- drive them to completion synchronously before inspecting toggled states.
    local pd = save.get_player_data(pix)
    if pd.picker_builds then
        local keys = {}
        for k in pairs(pd.picker_builds) do keys[#keys + 1] = k end
        for _, k in ipairs(keys) do picker_build.finish(pix, k) end
    end

    local before = collect(dialog)
    local n_buttons, n_toggled = 0, 0
    for _, v in pairs(before) do
        n_buttons = n_buttons + 1
        if v then n_toggled = n_toggled + 1 end
    end

    -- The old build path: re-sync every button's toggled via a dialog-wide dispatch.
    fs_util.dispatch_to_subtree(dialog, "on_preset_changed")
    local after = collect(dialog)

    local diffs = 0
    for idx, v in pairs(before) do if after[idx] ~= v then diffs = diffs + 1 end end
    for idx, v in pairs(after) do if before[idx] ~= v then diffs = diffs + 1 end end

    if screen.factory_solver_machine_presets then screen.factory_solver_machine_presets.destroy() end

    if n_buttons == 0 then
        rcon.print("GUITEST FAIL: machine_presets built 0 preset buttons (dialog did not populate)")
    elseif diffs ~= 0 then
        rcon.print("GUITEST FAIL: build-time toggled != dispatch toggled (" .. diffs .. " diffs of "
            .. n_buttons .. " buttons)")
    else
        rcon.print("GUITEST PASS: machine_presets toggled build-time==dispatch (buttons=" .. n_buttons
            .. " toggled=" .. n_toggled .. " diffs=0)")
    end
end)
if not ok then
    rcon.print("GUITEST FAIL: machine_presets_toggle errored: " .. tostring(err))
end
