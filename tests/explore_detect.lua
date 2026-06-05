-- Pure-Lua inspection + result formatting for the chain explorer.
--
-- This module holds the two pieces of the explorer that read NOTHING from the
-- Factorio runtime: detect() reads only a solved variable set (string keys +
-- math), and format_result() turns a generation-side context plus a detect()
-- result into the single status line the launcher logs. Extracting them lets a
-- standalone `lua` worker (tests/solve_problem.lua) reproduce the in-game
-- explorer's output verbatim from a dumped problem -- the Option A
-- producer/consumer split. tests/chain_explorer.lua requires this module and
-- delegates, so the HIT taxonomy (DEGEN / NOSHIP / CATALYST / plain HIT) has a
-- single source of truth shared by the in-engine and headless paths.

local M = {}

-- A recipe variable is "parked" when it sits at the IPM's interior floor rather
-- than carrying real flow. The live solver keeps strictly-interior values near
-- ~1e-11 for a truly-zero variable while active ones are O(1)+, so a threshold
-- relative to the chain's largest recipe value (with an absolute floor) cleanly
-- separates the two without assuming a fixed solution scale.
M.PARK_REL = 1e-6
M.PARK_ABS = 1e-9
-- Cheat mass (shortage_source/elastic) above this flags a TRUE undesirable
-- solution. Slack values ride near the IPM floor (~1e-11) when inactive.
M.CHEAT_EPS = 1e-6
-- park fraction (excluding pyvoid) at/above this earns a "~park" note -- worth a
-- look, but usually an alternative path on a branchy chain, so not a HIT.
M.PARK_NOTE_FRACTION = 0.5

local PARK_REL = M.PARK_REL
local PARK_ABS = M.PARK_ABS
local CHEAT_EPS = M.CHEAT_EPS
local PARK_NOTE_FRACTION = M.PARK_NOTE_FRACTION

---True for a real production recipe flow variable: a `recipe/` or
---`virtual_recipe/` primal that is NOT a |bridge| temperature-conversion
---variable. |bridge| variables are LP-internal plumbing create_problem injects,
---not recipes the user placed, so they are excluded. Shared by detect() and the
---cost-sweep driver (tests/sweep_cost.lua) so the two agree on what counts as a
---recipe.
---@param k string
---@return boolean
function M.is_recipe(k)
    if k:find("|bridge|", 1, true) then return false end
    return k:sub(1, 7) == "recipe/" or k:sub(1, 15) == "virtual_recipe/"
end

---The park threshold for a solved variable set: a recipe value with |value|
---below this sits at the IPM's interior floor rather than carrying real flow.
---Relative to the chain's largest recipe value (with an absolute floor) so it
---adapts to the solution scale instead of assuming a fixed one. Shared with the
---cost-sweep driver so park decisions stay consistent across both readers.
---@param vars PackedVariables?
---@return number
function M.park_threshold(vars)
    local max_x = 0
    if vars and vars.x then
        for k, v in pairs(vars.x) do
            if M.is_recipe(k) and math.abs(v) > max_x then
                max_x = math.abs(v)
            end
        end
    end
    return math.max(PARK_ABS, max_x * PARK_REL)
end

---Inspect a solved variable set. Reports the TRUE-signal cheat mass plus the
---(secondary) park fractions: all recipes, and excluding pyvoid waste recipes.
---`active` is how many real recipes carry flow; `degenerate` flags the sharpest
---impractical case -- cheat>0 with ZERO active recipes, i.e. the target is met
---purely by |shortage_source| while no factory runs (the net-negative-target /
---mass-losing-loop solution). A regular cheat>0 with active>0 is a partial
---shortage; degenerate is the "built nothing, conjured the target" extreme.
---
---`noship` is a second, cheat-free impracticality signal (the maintainer's
---criterion): a buildable solution draws on at least one |initial_source| (a
---declared external import) AND empties at least one |final_sink| (a product that
---leaves the factory). A solution that imports yet ships NOTHING -- every product
---is consumed internally or dumped back as penalized |surplus_sink| -- is a
---factory built to void its own output. cheat=0 hides it from the shortage/elastic
---gate (nothing is fabricated; the books balance), so it is flagged separately.
---Observed when a producer/consumer intermediate is pinned: create_problem routes
---the pinned amount to |surplus_sink| and never opens a |final_sink|, so the LP
---makes the material only to throw it away.
---@param vars PackedVariables?
---@return { recipes: integer, near_zero: integer, frac: number, recipes_nv: integer, near_zero_nv: integer, frac_nv: number, cheat: number, active: integer, degenerate: boolean, has_initial: boolean, has_final: boolean, noship: boolean, zeros: string[] }
function M.detect(vars)
    if not vars or not vars.x then
        return { recipes = 0, near_zero = 0, frac = 0, recipes_nv = 0,
            near_zero_nv = 0, frac_nv = 0, cheat = 0, active = 0, degenerate = false,
            has_initial = false, has_final = false, noship = false, zeros = {} }
    end

    -- Count only real production recipes. |bridge| temperature-conversion
    -- variables (keyed virtual_recipe/|bridge|...) are LP-internal plumbing
    -- create_problem injects, not recipes the user placed; they park whenever no
    -- temperature conversion is needed, so excluding them keeps the count about
    -- the user's chain rather than solver internals. M.is_recipe is the shared
    -- predicate; is_void is pyvoid-specific and stays local to this taxonomy.
    local is_recipe = M.is_recipe
    local function is_void(k)
        return k:find("pyvoid", 1, true) ~= nil
    end

    local thresh = M.park_threshold(vars)

    local recipes, near_zero = 0, 0
    local recipes_nv, near_zero_nv = 0, 0
    local zeros = {}
    for k, v in pairs(vars.x) do
        if is_recipe(k) then
            recipes = recipes + 1
            local parked = math.abs(v) < thresh
            if parked then
                near_zero = near_zero + 1
                zeros[#zeros + 1] = k:match("^[%w_]+/(.+)/[^/]+$") or k
            end
            if not is_void(k) then
                recipes_nv = recipes_nv + 1
                if parked then near_zero_nv = near_zero_nv + 1 end
            end
        end
    end

    -- Total mass carried by the penalty escapes (shortage_source / elastic): a
    -- non-trivial value means the solution leaned on the cheat instead of real
    -- flow -- the TRUE undesirable signal. The same pass records whether any
    -- declared external input (|initial_source|) is drawn and whether any product
    -- leaves the factory (|final_sink|) -- the two halves of the practicality
    -- criterion. |surplus_sink| deliberately does NOT count as shipping: it is
    -- penalized over-production (waste), not a delivered product.
    local cheat = 0
    local has_initial, has_final = false, false
    for k, v in pairs(vars.x) do
        if math.abs(v) > thresh then
            if k:find("|shortage_source|", 1, true) or k:find("|elastic|", 1, true) then
                cheat = cheat + math.abs(v)
            elseif k:find("|initial_source|", 1, true) then
                has_initial = true
            elseif k:find("|final_sink|", 1, true) then
                has_final = true
            end
        end
    end

    -- Real recipes carrying flow. Zero active + cheat>0 == the degenerate
    -- "target fabricated, nothing built" solution (mass-losing loop / net-
    -- negative target).
    local active = recipes - near_zero

    -- Imports something, fabricates nothing, yet ships nothing out: the factory
    -- produces only to dump it back as surplus. A cheat-free impracticality the
    -- shortage/elastic gate cannot see.
    local noship = has_initial and not has_final and cheat <= CHEAT_EPS

    return {
        recipes = recipes,
        near_zero = near_zero,
        frac = recipes > 0 and near_zero / recipes or 0,
        recipes_nv = recipes_nv,
        near_zero_nv = near_zero_nv,
        frac_nv = recipes_nv > 0 and near_zero_nv / recipes_nv or 0,
        cheat = cheat,
        active = active,
        degenerate = cheat > CHEAT_EPS and active == 0,
        has_initial = has_initial,
        has_final = has_final,
        noship = noship,
        zeros = zeros,
    }
end

---The generation-side context format_result needs. Every field is a plain
---number / string / boolean / string[] so the whole table round-trips through
---the dumped problem's `meta` literal (serialize_meta in chain_explorer.lua) and
---reaches the headless worker unchanged.
---@class ExploreContext
---@field seed integer
---@field mode string
---@field init string
---@field exclude_void boolean
---@field exclude_source_sink boolean
---@field pins integer
---@field use_quality boolean
---@field target_quality string
---@field hops integer
---@field seed_recipe string
---@field built integer
---@field target_label string
---@field do_close boolean
---@field catalysts string[] closure.catalysts: unresolved AND universe-unreachable (real imports).
---@field trapped_items string[] closure.trapped_items: produced-but-unreachable items.
---@field unresolved string[] closure.unresolved: consumed-but-unreachable materials.
---@field closure_added integer closure.added: bootstrap producers the generator pulled in.
---@field closure_closed boolean closure.closed: chain bottomed out at raw resources.

---Format one explorer status line from a generation context, the terminal
---solver state, the step count, and a detect() result. This is the single source
---of the HIT taxonomy: the in-engine explore() and the headless worker both call
---it so their output lines are byte-identical.
---  <<HIT DEGEN    -> cheat>0, zero recipes run (target conjured, nothing built).
---  <<HIT NOSHIP   -> cheat=0 but no |final_sink| (imports + runs yet voids output).
---  <<HIT          -> partial shortage with some real flow.
---  ... CATALYST   -> a cheat sitting on a genuine net-zero catalyst (solver finding).
---  ~park          -> high park fraction (ex-pyvoid); usually a normal alternative.
---@param ctx ExploreContext
---@param state string Terminal solver_state ("finished" | "unfinished" | ...).
---@param steps integer IPM steps taken.
---@param d table detect() result.
---@return string
function M.format_result(ctx, state, steps, d)
    local converged = state == "finished"
    -- HIT covers both impracticality families: the cheat gate (shortage/elastic
    -- fabricated or relaxed the target) and the noship gate (imports but ships
    -- nothing -- a cheat-free degeneracy the old gate could not see).
    local true_hit = (not converged) or d.cheat > CHEAT_EPS or d.noship
    local park_note = d.frac_nv >= PARK_NOTE_FRACTION

    -- HIT subclasses, in order of sharpness: DEGEN (cheat>0, zero recipes run --
    -- target conjured, nothing built); NOSHIP (cheat=0 but no |final_sink| -- a
    -- factory that imports and runs yet voids all output); plain HIT (a partial
    -- shortage with some real flow). All carry "<<HIT" so the launcher matches.
    local cats = ctx.catalysts or {}
    local tag = ""
    if true_hit then
        if d.degenerate then
            tag = "  <<HIT DEGEN"
        elseif d.cheat <= CHEAT_EPS and d.noship then
            tag = "  <<HIT NOSHIP"
        else
            tag = "  <<HIT"
        end
        -- A cheat sitting on top of a genuine catalyst is a SOLVER finding (the LP
        -- fabricated a material downstream of the catalyst instead of importing
        -- the catalyst), not the generator-incompleteness dead end that an
        -- unclosed-but-universe-reachable material is. Mark it so it is not
        -- dismissed with the ordinary unclosed cheats.
        if d.cheat > CHEAT_EPS and #cats > 0 then
            tag = tag .. " CATALYST"
        end
    elseif park_note then
        tag = "  ~park"
    end
    local parked = ""
    if (true_hit or park_note) and #d.zeros > 0 then
        table.sort(d.zeros)
        parked = " parked={" .. table.concat(d.zeros, ",") .. "}"
    end

    -- Closure note: how many bootstrap producers the generator had to add, and
    -- (when it could not bottom the chain out at raw resources) which materials
    -- stayed unreachable. An unclosed material that IS reachable universe-wide is
    -- a generator dead end (closure missed a producer the mod set has); one that
    -- is NOT (a catalyst, reported separately below) is a real import the solver
    -- must handle. The reachability rework provides this disambiguation.
    local closure_note = ""
    if not ctx.do_close then
        -- closure=off: report the surviving traps (what the netneg target is
        -- drawn from) rather than a bootstrap-add count.
        if #ctx.trapped_items > 0 then
            closure_note = " closure=off,trapped={" .. table.concat(ctx.trapped_items, ",") .. "}"
        else
            closure_note = " closure=off"
        end
    elseif not ctx.closure_closed and #ctx.unresolved > 0 then
        closure_note = string.format(" closure=add%d,unclosed={%s}",
            ctx.closure_added, table.concat(ctx.unresolved, ","))
    elseif ctx.closure_added > 0 then
        closure_note = string.format(" closure=add%d", ctx.closure_added)
    end

    -- Catalysts (unresolved AND universe-unreachable): the materials the solver
    -- should import via |initial_source| but may instead fabricate downstream.
    -- Surfaced always when present -- this is the load-bearing signal that a
    -- cheat here is a solver finding, not a generator artifact.
    local catalyst_note = ""
    if #cats > 0 then
        catalyst_note = " catalyst={" .. table.concat(cats, ",") .. "}"
    end

    return string.format(
        "seed=%d mode=%s init=%s void=%s nosrc=%s pins=%d qual=%s hops=%d state=%s built=%d R=%d(act=%d) nz=%d(%.0f%%) Rnv=%d(%.0f%%) cheat=%.4g ship=%s/%s steps=%d sr=%s tgt=%s%s%s%s%s",
        ctx.seed, ctx.mode, ctx.init, ctx.exclude_void and "ex" or "in",
        ctx.exclude_source_sink and "ex" or "in", ctx.pins,
        ctx.use_quality and ctx.target_quality or "off", ctx.hops,
        tostring(state), ctx.built,
        d.recipes, d.active, d.near_zero, d.frac * 100,
        d.recipes_nv, d.frac_nv * 100,
        d.cheat, d.has_initial and "i" or "-", d.has_final and "f" or "-",
        steps, ctx.seed_recipe, ctx.target_label, closure_note, catalyst_note, tag, parked)
end

return M
