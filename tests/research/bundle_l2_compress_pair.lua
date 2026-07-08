---@diagnostic disable: undefined-global
-- Bundle one-or-more corpus dumps into a SINGLE factory_solver shared string
-- carrying BOTH stages of the shipped L2 pipeline for each dump, frozen side
-- by side for visual comparison in-game:
--   "<name> (L2 baseline)"    the plain target-rescued L2 (QP) baseline, no fold
--   "<name> (mode-compressed)" solver/mode_compress.lua's fold applied on top,
--                              exactly as manage/pre_solve.lua's l2_compress_step
-- Both machine-count snapshots are embedded as `solved_machines`, so each
-- import lands FROZEN (solver_state="freeze", no re-solve) -- what you see is
-- exactly what this script computed, not whatever the GUI's default norm
-- would produce. N dumps -> 2N solutions in one envelope, one shared string.
--
-- Reuses the payload_json splicing + zlib-stored/base64 wrapper from
-- tests/bundle_solutions.lua (duplicated here rather than required -- that
-- script's helpers are file-local); see its header comment for the format
-- rationale (STORED deflate: correct, not size-optimal).
--   lua tests/research/bundle_l2_compress_pair.lua <out.txt> <dump1.lua> [dump2.lua ...]
require "tests/headless_env"
local create_problem = require "solver/create_problem"
local problem_dump = require "tests/problem_dump"
local mode_compress = require "solver/mode_compress"
local R = require "tests/research/research_lib"

local VQ, VF, EPS = 2 ^ 11, 2 ^ -8, 2 ^ -10

local function die(msg)
    io.stderr:write("bundle_l2_compress_pair: " .. msg .. "\n")
    os.exit(1)
end

local out_path = arg[1]
local dump_paths = {}
for i = 2, #arg do dump_paths[#dump_paths + 1] = arg[i] end
if not out_path or #dump_paths == 0 then
    die("usage: lua tests/research/bundle_l2_compress_pair.lua <out.txt> <dump1.lua> [dump2.lua ...]")
end

-- ---------------------------------------------------------------------------
-- payload_json splicing (tests/bundle_solutions.lua's approach)
-- ---------------------------------------------------------------------------

local function json_escape(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function read_payload(path)
    local chunk, load_err = loadfile(path)
    if not chunk then die("cannot load '" .. path .. "': " .. tostring(load_err)) end
    local ok, dump = pcall(chunk)
    if not ok or type(dump) ~= "table" then die("'" .. path .. "' is not a valid dump table") end
    local payload = dump.payload_json
    if type(payload) ~= "string" then
        die("'" .. path .. "' has no payload_json -- re-run the explorer to regenerate dumps with it")
    end
    payload = payload:gsub("%s+$", "")
    if payload:match("^%s*{") == nil or payload:sub(-1) ~= "}" then
        die("'" .. path .. "' payload_json does not look like a JSON object")
    end
    return payload
end

local function tag_name(payload, suffix)
    local head = payload:find('"name":"', 1, true)
    if not head then return payload end
    local value_start = head + #'"name":"'
    local value_end = payload:find('"', value_start, true)
    if not value_end then return payload end
    return payload:sub(1, value_end - 1) .. suffix .. payload:sub(value_end)
end

local function with_solved_machines(payload, suffix, machines)
    payload = tag_name(payload, suffix)
    local keys = {}
    for k in pairs(machines) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('"%s":%.17g', json_escape(k), machines[k])
    end
    return payload:sub(1, -2) .. ',"solved_machines":{' .. table.concat(parts, ",") .. "}}"
end

-- ---------------------------------------------------------------------------
-- Solve both stages for one dump (mirrors probe_l2_compress_divergence.lua)
-- ---------------------------------------------------------------------------

---@param dump_path string
---@return string payload_l2, string payload_compressed
local function solve_pair(dump_path)
    local ok_load, prob = pcall(problem_dump.load_problem, dump_path)
    if not ok_load or not prob then die("cannot load '" .. dump_path .. "'") end

    local function build(opts_extra)
        local opts = { reachability_gating = false, deficit_seeding = false, catalyst_closure = false,
            surplus_sink_gating = false, recipe_epsilon = EPS }
        if opts_extra then for k, v in pairs(opts_extra) do opts[k] = v end end
        local p = create_problem.create_problem("l2", prob.constraints, prob.normalized_lines, nil, opts)
        create_problem.shape_l2(p, VQ, VF)
        return p
    end
    local function solve(p) return R.drive_solve(p, prob.meta) end

    local base0 = build()
    local x0u, st0u = solve(base0)
    if st0u ~= "finished" then die(dump_path .. ": baseline (unlocked) did not finish: " .. tostring(st0u)) end
    local T0 = 0
    for k, p in pairs(base0.primals) do
        if p.kind == "elastic" or p.kind == "headroom" then T0 = T0 + math.abs(x0u[k] or 0) end
    end
    local BUDGET = T0 * (1 + 1e-3) + 1e-6

    local base = build({ target_budget = BUDGET })
    local x0, st0 = solve(base)
    if st0 ~= "finished" then die(dump_path .. ": baseline (locked) did not finish: " .. tostring(st0)) end

    local plan = mode_compress.plan(base, x0)
    local compressed, xd
    if plan then
        compressed = build({ target_budget = BUDGET, hatch_exclude = plan.hatch, sink_exclude = plan.sink })
        local xdv, stdv = solve(compressed)
        if stdv ~= "finished" then die(dump_path .. ": compressed re-solve did not finish: " .. tostring(stdv)) end
        xd = xdv
    else
        compressed, xd = base, x0
    end

    local machines0 = base:filter_result({ x = x0 })
    local machines1 = compressed:filter_result({ x = xd })

    local raw_payload = read_payload(dump_path)
    local payload_l2 = with_solved_machines(raw_payload, " (L2 baseline)", machines0)
    local payload_compressed = with_solved_machines(
        raw_payload, plan and " (mode-compressed)" or " (mode-compressed, no fold)", machines1)
    return payload_l2, payload_compressed
end

-- ---------------------------------------------------------------------------
-- zlib (stored deflate) + base64, verbatim from tests/bundle_solutions.lua
-- ---------------------------------------------------------------------------

local function adler32(s)
    local MOD = 65521
    local a, b = 1, 0
    local i, n = 1, #s
    while i <= n do
        local last = math.min(i + 5551, n)
        for j = i, last do
            local byte = s:byte(j)
            a = a + byte
            b = b + a
        end
        a = a % MOD
        b = b % MOD
        i = last + 1
    end
    return a, b
end

local function deflate_stored(data)
    local n = #data
    if n == 0 then
        return string.char(0x01, 0x00, 0x00, 0xFF, 0xFF)
    end
    local out = {}
    local pos = 1
    while pos <= n do
        local chunk_end = math.min(pos + 65534, n)
        local len = chunk_end - pos + 1
        local nlen = 0xFFFF - len
        out[#out + 1] = string.char(chunk_end == n and 0x01 or 0x00)
        out[#out + 1] = string.char(len % 256, math.floor(len / 256) % 256)
        out[#out + 1] = string.char(nlen % 256, math.floor(nlen / 256) % 256)
        out[#out + 1] = data:sub(pos, chunk_end)
        pos = chunk_end + 1
    end
    return table.concat(out)
end

local function zlib_compress(data)
    local a, b = adler32(data)
    local adler_be = string.char(
        math.floor(b / 256) % 256, b % 256,
        math.floor(a / 256) % 256, a % 256)
    return string.char(0x78, 0x01) .. deflate_stored(data) .. adler_be
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    local out = {}
    local n = #data
    local i = 1
    while i <= n do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)
        local s1 = math.floor(b1 / 4)
        local s2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
        local s3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0)) or nil
        local s4 = b3 and (b3 % 64) or nil
        out[#out + 1] = B64:sub(s1 + 1, s1 + 1)
        out[#out + 1] = B64:sub(s2 + 1, s2 + 1)
        out[#out + 1] = s3 and B64:sub(s3 + 1, s3 + 1) or "="
        out[#out + 1] = s4 and B64:sub(s4 + 1, s4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

-- ---------------------------------------------------------------------------
-- Main: solve every dump, splice all payload pairs into one envelope
-- ---------------------------------------------------------------------------

local payloads = {}
for _, dump_path in ipairs(dump_paths) do
    local payload_l2, payload_compressed = solve_pair(dump_path)
    payloads[#payloads + 1] = payload_l2
    payloads[#payloads + 1] = payload_compressed
    io.stderr:write("bundle_l2_compress_pair: solved " .. dump_path .. "\n")
end

local envelope_json = string.format(
    '{"signature":"factory_solver","version":1,"solutions":[%s]}',
    table.concat(payloads, ","))

local shared = base64_encode(zlib_compress(envelope_json))

local fh, open_err = io.open(out_path, "wb")
if not fh then die("cannot open '" .. out_path .. "' for writing: " .. tostring(open_err)) end
fh:write(shared)
fh:close()

io.stderr:write(string.format(
    "bundle_l2_compress_pair: %d dump(s) -> %d solution(s), %d JSON bytes -> %d char shared string at %s\n",
    #dump_paths, #payloads, #envelope_json, #shared, out_path))
