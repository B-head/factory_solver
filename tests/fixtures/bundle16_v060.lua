-- 0.6.0 (hardgate) solution for every bundle16 Solution with all constraints
-- forced to EXACT (equal). Under exact the lower/upper degenerate free dimension
-- is removed, so 0.6.0 and the reference solver converge to the SAME machine
-- counts -- the agreement is the trust anchor (no single solver is gold).
-- machines = sum over PLACED-line recipe vars (bridges excluded). NOT shipped.
-- Regenerate: tests/gen_v060_exact.lua run in a 0.6.0 git worktree.
-- "Asteroid up cycleing" and "SpacePlatform" have a confirmed-different correct
-- answer on Factorio 2.1+: asteroid-crushing recipes raised their own-chunk
-- self-return chance (basic 20% -> 30%, advanced 5% -> 10%) and asteroid-
-- reprocessing recipes lost the quality module effect (allowed_effects.quality
-- true -> false on metallic-asteroid-reprocessing, checked as representative of
-- the -reprocessing family) -- both confirmed by reading recipe prototypes on a
-- live 2.0.77 engine vs a live 2.1.9 engine. The values below are the 2.0-data
-- answer (unchanged from the original 0.6.0/2.0 capture); the 2.1-data answer
-- (verified independently via tests/research/reference_solver.lua converging on
-- the same numbers as the current shipping solver) lives in
-- BUNDLE16_V060_OVERRIDE_2_1 in manage/smoke_rcon.lua, selected at runtime by
-- detected engine version. See project_factorio_2_1_api_migration in memory for
-- the full derivation.
return {
    ["Asteroid up cycleing"] = { state = "finished", T = 7.937372377e-14, import = 26.79722353, surplus = 0.001674102361, machines = 221.0184678 },
    ["Begining"] = { state = "finished", T = 1.619913368e-14, import = 0, surplus = 1.658791265e-10, machines = 36 },
    ["Fulgora bottom up"] = { state = "finished", T = 1.248968799e-14, import = 55, surplus = 10.16957483, machines = 48.61425264 },
    ["Fulgora top down"] = { state = "finished", T = 1.777794883e-14, import = 55.71481482, surplus = 10.30174506, machines = 49.24607425 },
    -- Fusion's constraint is already EXACT (fusion-power-cell = 0.0166667), so the
    -- un-gated single solve is the well-posed baseline directly. Only the staged
    -- reference solver stalls on it (its per-stage budget-lock rows ill-condition
    -- the near-degenerate catalyst loop); 0.6.0 and the shipped single/cascade
    -- solves all converge to 266.667 (verified: the exact single solve and the
    -- cascade agree bit-for-bit at 266.6667819 across repeated headless runs).
    ["Fusion"] = { state = "finished", T = 0, import = 0.01666666667, surplus = 0, machines = 266.6667819 },
    ["Generator"] = { state = "finished", T = 3.244152366e-14, import = 0.45, surplus = 9.966031775e-11, machines = 3.005 },
    ["Gleba circuit"] = { state = "finished", T = 4.66840025e-14, import = 0.3074074081, surplus = 0.006814815532, machines = 10.11851852 },
    ["Gleba loop"] = { state = "finished", T = 0, import = 1.333333333, surplus = 0.01122131053, machines = 10.23379712 },
    ["Module and beacon"] = { state = "finished", T = 5.916676561e-14, import = 18.71811212, surplus = 4.798664339e-10, machines = 18.6829793 },
    ["Nuclear"] = { state = "finished", T = 3.356757892e-14, import = 0.005, surplus = 1.374928027e-10, machines = 11.90721649 },
    ["Oil Processing 1"] = { state = "finished", T = 0, import = 151.4833861, surplus = 0, machines = 83.90625 },
    ["Oil Processing 2"] = { state = "finished", T = 0, import = 191.8376866, surplus = 0, machines = 110.0373134 },
    ["Quality loop"] = { state = "finished", T = 2.761880766e-14, import = 74.16962285, surplus = 3.15667446e-10, machines = 19.09701745 },
    ["Rocket"] = { state = "finished", T = 0, import = 1747.222222, surplus = 0, machines = 1054.444444 },
    ["Simple"] = { state = "finished", T = 2.077488628e-14, import = 1.5, surplus = 6.37372886e-11, machines = 4.6 },
    ["SpacePlatform"] = { state = "finished", T = 4.330373538e-14, import = 0.9240000002, surplus = 4.876203147e-10, machines = 20.36 },
}
