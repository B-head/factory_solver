-- 0.6.0 (hardgate) solution for every bundle16 Solution with all constraints
-- forced to EXACT (equal). Under exact the lower/upper degenerate free dimension
-- is removed, so 0.6.0 and the reference solver converge to the SAME machine
-- counts -- the agreement is the trust anchor (no single solver is gold).
-- machines = sum over PLACED-line recipe vars (bridges excluded). NOT shipped.
-- Regenerate: tests/gen_v060_exact.lua run in a 0.6.0 git worktree.
return {
    ["Asteroid up cycleing"] = { state = "finished", T = 7.937372377e-14, import = 26.79722353, surplus = 0.001674102361, machines = 221.0184678 },
    ["Begining"] = { state = "finished", T = 1.619913368e-14, import = 0, surplus = 1.658791265e-10, machines = 36 },
    ["Fulgora bottom up"] = { state = "finished", T = 1.248968799e-14, import = 55, surplus = 10.16957483, machines = 48.61425264 },
    ["Fulgora top down"] = { state = "finished", T = 1.777794883e-14, import = 55.71481482, surplus = 10.30174506, machines = 49.24607425 },
    ["Fusion"] = { state = "unfinished", T = 0, import = 0, surplus = 0, machines = 0 },
    ["Generator"] = { state = "finished", T = 3.244152366e-14, import = 0.45, surplus = 9.966031775e-11, machines = 3.005 },
    ["Gleba circuit"] = { state = "finished", T = 4.66840025e-14, import = 0.3074074081, surplus = 0.006814815532, machines = 10.11851852 },
    ["Gleba loop"] = { state = "finished", T = 9.133711886e-14, import = 13.33333333, surplus = 0.01122131125, machines = 10.23379712 },
    ["Module and beacon"] = { state = "finished", T = 5.916676561e-14, import = 18.71811212, surplus = 4.798664339e-10, machines = 18.6829793 },
    ["Nuclear"] = { state = "finished", T = 3.356757892e-14, import = 0.005, surplus = 1.374928027e-10, machines = 11.90721649 },
    ["Oil Processing 1"] = { state = "finished", T = 2.251978768e-14, import = 1244.833861, surplus = 5.765221051e-11, machines = 83.90625 },
    ["Oil Processing 2"] = { state = "finished", T = 6.01212749e-14, import = 1460.233209, surplus = 1.538902176e-10, machines = 110.0373134 },
    ["Quality loop"] = { state = "finished", T = 2.761880766e-14, import = 74.16962285, surplus = 3.15667446e-10, machines = 19.09701745 },
    ["Rocket"] = { state = "finished", T = 2.39281629e-14, import = 2022.222222, surplus = 4.814269458e-11, machines = 1054.444444 },
    ["Simple"] = { state = "finished", T = 2.077488628e-14, import = 1.5, surplus = 6.37372886e-11, machines = 4.6 },
    ["SpacePlatform"] = { state = "finished", T = 4.330373538e-14, import = 0.9240000002, surplus = 4.876203147e-10, machines = 20.36 },
}
