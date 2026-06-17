-- 0.6.0 solver output for tests/fixtures/bundle16_shared.lua (the GOOD
-- baseline: 0.6.0 built real chains where the current solver collapses).
-- machines = sum over the PLACED-line recipe vars (== current kind=='recipe').
-- Regenerate via tests/bundle16_make_v060.lua run in a 0.6.0 git worktree (see
-- that file's header). NOT shipped (tests/* is in info.json package.ignore).
return {
    ["Asteroid up cycleing"] = { state = "finished", T = 0, import = 26.79722353, surplus = 0.001674102361, machines = 221.0184678 },
    ["Begining"] = { state = "finished", T = 2.592652355e-14, import = 0, surplus = 2.654875788e-10, machines = 62.73773205 },
    ["Fulgora bottom up"] = { state = "finished", T = 2.608944337e-14, import = 55, surplus = 10.16957483, machines = 48.61425264 },
    ["Fulgora top down"] = { state = "finished", T = 0, import = 55.71481482, surplus = 10.30174506, machines = 49.24607425 },
    ["Fusion"] = { state = "unfinished", T = 0, import = 0, surplus = 0, machines = 0 },
    ["Generator"] = { state = "finished", T = 3.244152366e-14, import = 0.45, surplus = 9.966031775e-11, machines = 3.005 },
    ["Gleba circuit"] = { state = "finished", T = 0, import = 0.3074074081, surplus = 0.006814815532, machines = 10.11851852 },
    ["Gleba loop"] = { state = "finished", T = 0, import = 13.33333333, surplus = 0.01122131125, machines = 10.23379712 },
    ["Module and beacon"] = { state = "finished", T = 0, import = 18.71811212, surplus = 4.798664339e-10, machines = 18.6829793 },
    ["Nuclear"] = { state = "finished", T = 3.356757892e-14, import = 0.005, surplus = 1.374928027e-10, machines = 11.90721649 },
    ["Oil Processing 1"] = { state = "finished", T = 0, import = 1244.833861, surplus = 5.765221051e-11, machines = 83.90625 },
    ["Oil Processing 2"] = { state = "finished", T = 5.914287961e-14, import = 1460.233209, surplus = 3.027710296e-10, machines = 110.0373135 },
    ["Quality loop"] = { state = "finished", T = 0, import = 74.16962285, surplus = 3.15419673e-10, machines = 19.09701745 },
    ["Rocket"] = { state = "finished", T = 3.189438461e-14, import = 2022.222222, surplus = 1.285238904e-10, machines = 1054.444444 },
    ["Simple"] = { state = "finished", T = 0, import = 1.5, surplus = 6.37372886e-11, machines = 4.6 },
    ["SpacePlatform"] = { state = "finished", T = 4.330373538e-14, import = 0.9240000002, surplus = 4.876203148e-10, machines = 20.36 },
}
