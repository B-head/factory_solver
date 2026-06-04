-- Unit tests for the chain explorer's temperature-aware reachability core
-- (manage/chain_reachability.lua). The pure model must agree with how
-- solver/create_problem reaches materials: items by producer chain, fluids by
-- point/range with a bridge, and -- the load-bearing case -- a cycle broken by a
-- temperature gap is NOT a trap, because the out-of-range fluid is imported as a
-- raw seed (exactly what the LP does), so its consumer still fires.

local harness = require "tests/harness"
local cr = require "manage/chain_reachability"

local function I(name) return { item = name } end
local function F(name, t) return { fluid = name, t = t } end
local function Fin(name, lo, hi) return { fluid = name, lo = lo, hi = hi } end
local function R(ings, prods) return { ings = ings, prods = prods } end

local cases = {}

table.insert(cases, {
    name = "linear chain: producer fires, product reachable, raw input not trapped",
    run = function()
        local reach = cr.reachable({
            R({ I("ore") }, { I("plate") }),
        })
        harness.assert_true(reach.reach_items["plate"] == true, "plate reachable")
        harness.assert_true(cr.item_trapped(reach, "plate") == false, "plate not trapped")
        harness.assert_true(reach.ing_ok(I("ore")) == true, "raw ore satisfied")
    end,
})

table.insert(cases, {
    name = "item cycle with no external entry: both members trapped",
    run = function()
        -- A: M + X -> P ; B: P -> M. X is raw; M and P depend on each other.
        local reach = cr.reachable({
            R({ I("M"), I("X") }, { I("P") }),
            R({ I("P") }, { I("M") }),
        })
        harness.assert_true(cr.item_trapped(reach, "P"), "P trapped (cyclic)")
        harness.assert_true(cr.item_trapped(reach, "M"), "M trapped (cyclic)")
    end,
})

table.insert(cases, {
    name = "same cycle with an external producer: bootstrapped, nothing trapped",
    run = function()
        -- Add C: X -> M, giving M a producer outside the cycle.
        local reach = cr.reachable({
            R({ I("M"), I("X") }, { I("P") }),
            R({ I("P") }, { I("M") }),
            R({ I("X") }, { I("M") }),
        })
        harness.assert_true(reach.reach_items["M"] == true, "M reachable via C")
        harness.assert_true(reach.reach_items["P"] == true, "P reachable")
        harness.assert_true(cr.item_trapped(reach, "P") == false, "P not trapped")
    end,
})

table.insert(cases, {
    name = "cycle broken by a temperature gap is NOT a trap (out-of-range fluid imported)",
    run = function()
        -- A: G -> F@500 ; B: F[15,100] -> G. By NAME this is a G<->F cycle, but
        -- F is produced at 500, outside B's [15,100] window, so no bridge exists
        -- and B's F is a raw seed (imported). B fires, G is made, A fires.
        local reach = cr.reachable({
            R({ I("G") }, { F("F", 500) }),
            R({ Fin("F", 15, 100) }, { I("G") }),
        })
        harness.assert_true(reach.ing_ok(Fin("F", 15, 100)) == true,
            "out-of-range F is a raw seed (satisfied)")
        harness.assert_true(reach.reach_items["G"] == true, "G reachable -- cycle broken by import")
        harness.assert_true(cr.item_trapped(reach, "G") == false, "G not trapped")
    end,
})

table.insert(cases, {
    name = "temperature bridge inside range: consumer fires only via the produced point",
    run = function()
        -- A: ore -> F@50 ; B: F[15,100] -> final. 50 is inside [15,100], so F is
        -- NOT a raw seed -- B's F is satisfied only because the producer A reaches
        -- F@50.
        local reach = cr.reachable({
            R({ I("ore") }, { F("F", 50) }),
            R({ Fin("F", 15, 100) }, { I("final") }),
        })
        harness.assert_true(reach.ing_ok(Fin("F", 15, 100)) == true, "in-range F satisfied via bridge")
        harness.assert_true(reach.reach_items["final"] == true, "final reachable")
    end,
})

table.insert(cases, {
    name = "in-range producer that never fires blocks the consumer (no raw-seed escape)",
    run = function()
        -- A: M -> F@50 with M trapped in an item cycle; B: F[15,100] -> out.
        -- F is produced only at 50, inside [15,100], so it is NOT a raw seed; the
        -- bridge needs F@50 reachable, but A never fires, so B is blocked.
        local reach = cr.reachable({
            R({ I("M"), I("X") }, { I("P") }),
            R({ I("P") }, { I("M") }),
            R({ I("M") }, { F("F", 50) }),
            R({ Fin("F", 15, 100) }, { I("out") }),
        })
        harness.assert_true(reach.ing_ok(Fin("F", 15, 100)) == false,
            "in-range F unsatisfied (its only producer never fires)")
        harness.assert_true(cr.item_trapped(reach, "out"), "out trapped")
    end,
})

return cases
