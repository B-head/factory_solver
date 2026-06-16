-- Incremental, on_tick-driven, per-K-button picker build. Opening a recipe picker
-- builds its slot tables; under multiplayer lockstep that construction runs on
-- every client + the server in lockstep, so a large picker (e.g. the spent picker
-- for ash: ~4,700 buttons, 2,612 in one filter_slot_table) freezes the whole
-- server in one tick. This spreads the build across ticks at BUTTON_BUDGET buttons
-- per tick, mirroring the tick-split relation build (manage/relation.lua +
-- save.advance_relation_builds): the click/on_added handler stays light and just
-- arms a request; this advances it from control.lua's on_tick.
--
-- Build state lives in storage.players[*].picker_builds (replicated, plain
-- strings/numbers only -- no LuaObject, no live iterator), so it is save/load safe
-- and deterministic across clients; GUI elements are re-found by name each tick.
--
-- A caller registers a spec (a table of pure callbacks) per picker; this module
-- owns the generic cursor/budget loop. Callbacks:
--   plan(player_index, req)            -> PickerBuildPlan { entries, group_of }
--   find_table(player_index, req)      -> the LuaGuiElement to build into, or nil
--   open_group(pi, req, table, group)  -> appends the group's slot table, returns it
--   current_slot(pi, req, table)       -> the current (last) slot table to append to
--   make_button(pi, req, plan, i)      -> a GuiElemDef for entry i, or nil to skip it
--   close_group(pi, req, table)        -> OPTIONAL; called when the current group ends
--                                         (group change or build completion). Used by
--                                         single-table pickers (constraint_adder) to pad
--                                         the just-finished group to a row boundary;
--                                         per-group-table pickers (production_line_adder)
--                                         omit it.
--   sort_run(pi, req, plan, lo, hi)    -> OPTIONAL; sort plan.entries[lo..hi] (one
--                                         subgroup) in place, co-permuting any parallel
--                                         arrays the spec owns. Called once per sort-run
--                                         when its first entry is reached, so the per-
--                                         subgroup sort is spread across build ticks
--                                         instead of paid up front in the plan tick.
--                                         Required iff plan.sort_of is set.
local fs_util = require "fs_util"
local save = require "manage/save"

local M = {}

-- spec registry; specs hold callbacks (functions never go in storage).
local specs = {}

-- Buttons built per tick. ~44us/button => ~3.5ms worst build step, under the
-- ~5ms shared-tick target. Count-based: os.* is unavailable and a wall-clock
-- budget would desync.
local BUTTON_BUDGET = 80

---@param spec table
function M.register_spec(spec)
    specs[spec.id] = spec
end

---Arm (or replace) the tick-split build for one picker section. Pure state -- the
---caller clears the target table. Re-firing under the same key overwrites the
---state = cancel + restart.
---@param player_index integer
---@param key string Unique per concurrent build for this player (e.g. section name).
---@param req PickerBuildRequest
function M.request(player_index, key, req)
    local pd = save.get_player_data(player_index)
    if not pd then return end
    pd.picker_builds = pd.picker_builds or {}
    pd.picker_builds[key] = { req = req, phase = "plan", cursor = 1 }
end

---@param player_index integer
---@param state PickerBuildState
---@param budget integer
---@return boolean done
local function advance_one(player_index, state, budget)
    local spec = specs[state.req.spec_id]
    if not spec then return true end

    if state.phase == "plan" then
        -- Re-find by name; if the dialog is gone the build is abandoned.
        local t = spec.find_table(player_index, state.req)
        if not t or not t.valid then return true end
        state.plan = spec.plan(player_index, state.req)
        state.phase = (#state.plan.entries == 0) and "done" or "build"
        return state.phase == "done"
    end

    if state.phase == "build" then
        local t = spec.find_table(player_index, state.req)
        if not t or not t.valid then return true end
        local plan = state.plan
        local n = #plan.entries
        -- The current slot table is re-acquired at most once per group change per
        -- step (never per button -- that would reintroduce the O(width^2) we fixed).
        local slot = nil
        local processed = 0
        while processed < budget and state.cursor <= n do
            local i = state.cursor
            -- Sort this entry's run (one subgroup) once, when first reached, before its
            -- buttons are built. Folding the per-subgroup sort here keeps it off the
            -- one-shot plan tick (which would otherwise pay the whole display sort up
            -- front). The run is contiguous (the plan bucketed entries by subgroup), so
            -- its extent is the maximal i..hi sharing this sort_of.
            if plan.sort_of and plan.sort_of[i] ~= state.current_sort then
                local hi = i
                while hi < n and plan.sort_of[hi + 1] == plan.sort_of[i] do hi = hi + 1 end
                spec.sort_run(player_index, state.req, plan, i, hi)
                state.current_sort = plan.sort_of[i]
            end
            -- make_button returns nil for entries filtered out (hidden / unresearched
            -- not shown, or name-filtered): skip without opening their group, so a
            -- fully-filtered group never gets an empty sprite + table.
            local def = spec.make_button(player_index, state.req, plan, i)
            if def then
                local g = plan.group_of[i]
                if g ~= state.current_group then
                    -- Close the previous group before opening the next. Only fires on
                    -- a real group change (never mid-budget within a group), so a
                    -- single-table picker's padding lands exactly at group boundaries.
                    if state.current_group ~= nil and spec.close_group then
                        spec.close_group(player_index, state.req, t)
                    end
                    slot = spec.open_group(player_index, state.req, t, g)
                    state.current_group = g
                elseif not slot then
                    slot = spec.current_slot(player_index, state.req, t)
                end
                fs_util.add_gui(slot, def)
            end
            state.cursor = i + 1
            processed = processed + 1
        end
        if state.cursor > n then
            -- Build complete: close the final group (the last one never sees a group
            -- change to trigger its close).
            if state.current_group ~= nil and spec.close_group then
                spec.close_group(player_index, state.req, t)
            end
            state.phase = "done"
        end
        return state.phase == "done"
    end

    return true
end

---on_tick entry: advance ONE section globally this tick, so the worst tick is one
---plan or one build step (parity with the one-force-per-tick relation build). Which
---section is advanced ROTATES by game.tick (round-robin), so the several sections of
---one open dialog -- production_line_adder's ingredient / fuel / product / spent --
---fill in balance instead of one completing before the next starts. game.tick is
---lockstep-identical across clients, so the choice is deterministic; the flat list is
---built in sorted (player, key) order for the same reason.
---@return boolean advanced
function M.advance_all()
    local players = storage.players
    if not players then return false end

    -- Flatten every in-flight section into a deterministic (player, key) list.
    local pids = {}
    for pid, pd in pairs(players) do
        if pd.picker_builds and next(pd.picker_builds) then
            pids[#pids + 1] = pid
        end
    end
    if #pids == 0 then return false end
    table.sort(pids)

    local flat = {}
    for _, pid in ipairs(pids) do
        local keys = {}
        for k in pairs(players[pid].picker_builds) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, key in ipairs(keys) do
            flat[#flat + 1] = { pid = pid, key = key }
        end
    end

    -- Rotate which section advances this tick. One section per tick keeps the
    -- per-tick cost bounded (BUTTON_BUDGET); rotating spreads progress across the
    -- open dialog's sections instead of draining them one at a time.
    local pick = flat[(game.tick % #flat) + 1]
    local pd = players[pick.pid]
    local builds = pd.picker_builds
    if advance_one(pick.pid, builds[pick.key], BUTTON_BUDGET) then
        builds[pick.key] = nil
        if not next(builds) then pd.picker_builds = nil end
    end
    return true
end

---Synchronous completion of one section (verification / fallback symmetry; not on
---the hot path).
---@param player_index integer
---@param key string
function M.finish(player_index, key)
    local pd = save.get_player_data(player_index)
    local builds = pd and pd.picker_builds
    local state = builds and builds[key]
    if not state then return end
    while not advance_one(player_index, state, math.huge) do end
    builds[key] = nil
    if not next(builds) then pd.picker_builds = nil end
end

return M
