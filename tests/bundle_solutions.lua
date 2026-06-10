---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS is configured for the Factorio sandbox
--  where they are stripped, but this file only runs in a standalone Lua host.)

-- Offline bundler: turn one-or-more explorer dump files into a single
-- factory_solver shared string you can paste into the mod's Import dialog.
--
-- Each dump (tests/chain_explorer.lua's explore_emit ->
-- script-output/explore_problems/<tag>.lua) carries a `payload_json` field: the
-- finished JSON for ONE Solution's {name, constraints, production_lines}, built
-- in-engine by helpers.table_to_json with the REAL ProductionLines (machine /
-- module / fuel choices intact -- NOT the normalized fold). We splice those
-- opaque JSON fragments straight into a solution_codec envelope and wrap it the
-- way Factorio's helpers.encode_string does -- zlib deflate + base64 -- so the
-- result decodes through manage/solution_codec.lua unchanged.
--
-- Because we never re-implement JSON encoding (the fragments come from Factorio)
-- the only format this script owns is the zlib + base64 wrapper. We use zlib
-- STORED (uncompressed) deflate blocks: zlib inflate accepts them, so Factorio's
-- decode_string reads them, and we avoid shipping a real DEFLATE compressor. The
-- trade-off is size -- the shared string is base64 of the raw JSON (~1.37x) with
-- no compression -- which is fine for hand-picking a handful of chains.
--
-- Usage (run from the repo root):
--   lua tests/bundle_solutions.lua <out.txt> [--reference] <file-or-dir> [more...]
--     * <out.txt>            where the shared string is written (no newline).
--     * args ending in .lua  treated as dump files.
--     * any other arg        treated as a directory; its *.lua files are added.
--     * --reference          additionally solve each dump with the headless
--       lexicographic reference solver (tests/research/reference_solver.lua)
--       and embed the per-recipe machine counts as `solved_machines`; the mod
--       imports such a solution FROZEN (solver_state="freeze", no re-solve)
--       so the reference solution itself is what the GUI shows. The solution
--       name gets a " (ref)" suffix for side-by-side comparison with a normal
--       (re-solved) import of the same dump. Requires the full repo (pulls in
--       tests/headless_env + the solver); without the flag this script stays
--       a dependency-free standalone.
--
-- PowerShell glob expansion also works, e.g.:
--   lua tests/bundle_solutions.lua S:\tmp\bundle.txt `
--     (Get-ChildItem $env:APPDATA\Factorio\script-output\explore_problems\*.lua).FullName

local SIGNATURE = "factory_solver"
local VERSION = 1

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local SEP = IS_WINDOWS and "\\" or "/"

local function die(msg)
    io.stderr:write("bundle_solutions: " .. msg .. "\n")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Input collection
-- ---------------------------------------------------------------------------

---List the *.lua files directly inside `dir` (non-recursive). Best-effort via
---io.popen; returns an empty list and a warning string if listing is impossible.
---@param dir string
---@return string[] files
local function list_lua_files(dir)
    if not io.popen then
        die("io.popen unavailable; pass explicit .lua files instead of the directory '" .. dir .. "'")
    end
    local files = {}
    local trimmed = dir:gsub("[/\\]+$", "")
    -- cmd.exe's `dir` reads `/` as its option char, so a forward-slash path
    -- (e.g. git-bash hands lua "S:/tmp/...") silently lists nothing. Normalize
    -- to backslashes on Windows so both the command and the prepend agree.
    if IS_WINDOWS then trimmed = trimmed:gsub("/", "\\") end
    local cmd
    if IS_WINDOWS then
        -- /b bare names, /a-d files only; basenames need the dir prepended.
        cmd = string.format('dir /b /a-d "%s\\*.lua" 2>nul', trimmed)
    else
        cmd = string.format("ls -1 '%s'/*.lua 2>/dev/null", trimmed)
    end
    local pipe = io.popen(cmd)
    if not pipe then return files end
    for line in pipe:lines() do
        line = line:gsub("[\r\n]+$", "")
        if line ~= "" then
            if IS_WINDOWS then
                files[#files + 1] = trimmed .. SEP .. line
            else
                files[#files + 1] = line
            end
        end
    end
    pipe:close()
    return files
end

---Expand the raw positional inputs into a flat, ordered file list.
---@param inputs string[]
---@return string[]
local function collect_files(inputs)
    local files = {}
    for _, item in ipairs(inputs) do
        if item:match("%.lua$") then
            files[#files + 1] = item
        else
            local listed = list_lua_files(item)
            if #listed == 0 then
                io.stderr:write("bundle_solutions: warning: no *.lua under '" .. item .. "'\n")
            end
            for _, f in ipairs(listed) do
                files[#files + 1] = f
            end
        end
    end
    return files
end

---Load one dump file and return its embedded per-Solution payload JSON.
---(The --reference path reloads the dump through tests/problem_dump instead,
---sharing the validation every other headless driver uses.)
---@param path string
---@return string payload_json
local function read_payload(path)
    local chunk, load_err = loadfile(path)
    if not chunk then
        die("cannot load '" .. path .. "': " .. tostring(load_err))
    end
    local ok, dump = pcall(chunk)
    if not ok or type(dump) ~= "table" then
        die("'" .. path .. "' is not a valid dump table")
    end
    local payload = dump.payload_json
    if type(payload) ~= "string" then
        die("'" .. path .. "' has no payload_json -- re-run the explorer "
            .. "(tests/explore_chains.ps1) to regenerate dumps with it")
    end
    payload = payload:gsub("%s+$", "")
    if payload:match("^%s*{") == nil or payload:sub(-1) ~= "}" then
        die("'" .. path .. "' payload_json does not look like a JSON object")
    end
    return payload
end

-- ---------------------------------------------------------------------------
-- --reference: solve the dump with the lexicographic reference solver and
-- splice the frozen machine counts into the payload fragment
-- ---------------------------------------------------------------------------

---Minimal JSON string escaping for LP variable keys (plain ASCII in practice;
---escape the two structural characters anyway).
---@param s string
---@return string
local function json_escape(s)
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

---Append " (ref)" to the payload's "name" value so a frozen reference import
---sits next to a normal import of the same dump without a name clash suffix
---hiding which is which.
---@param payload string
---@return string
local function tag_name(payload)
    local head = payload:find('"name":"', 1, true)
    if not head then return payload end
    local value_start = head + #'"name":"'
    local value_end = payload:find('"', value_start, true)
    if not value_end then return payload end
    return payload:sub(1, value_end - 1) .. " (ref)" .. payload:sub(value_end)
end

---Solve the dump at `path` with the reference solver and splice its machine
---counts into the payload JSON as `solved_machines`. Returns the payload
---unchanged (with a warning) when the reference does not finish.
---@param payload string
---@param path string
---@return string
local function add_reference_solution(payload, path)
    -- Lazy: only the --reference path drags in the solver stack.
    require "tests/headless_env"
    local reference_solver = require "tests/research/reference_solver"
    local problem_dump = require "tests/problem_dump"

    local prob, kind, detail = problem_dump.load_problem(path)
    if not prob then
        die("'" .. path .. "' failed to load for --reference: "
            .. tostring(kind) .. " " .. tostring(detail))
    end
    local ok, r = pcall(reference_solver.solve_reference, prob.constraints, prob.normalized_lines)
    if not ok or r.state ~= "finished" or not r.problem then
        io.stderr:write(string.format(
            "bundle_solutions: warning: reference solve %s on '%s'; bundling unsolved\n",
            ok and tostring(r.state) or "raised", path))
        return payload
    end

    local machines = r.problem:filter_result({ x = r.x, y = {}, s = {} })
    local keys = {}
    for k in pairs(machines) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('"%s":%.17g', json_escape(k), machines[k])
    end
    return tag_name(payload:sub(1, -2))
        .. ',"solved_machines":{' .. table.concat(parts, ",") .. "}}"
end

-- ---------------------------------------------------------------------------
-- zlib (stored deflate) + base64 -- the only self-owned format here
-- ---------------------------------------------------------------------------

---Adler-32 over `s`, returned as its two 16-bit halves (high `b`, low `a`),
---blocked at NMAX=5552 so the running sums stay exact in a Lua double.
---@param s string
---@return integer a
---@return integer b
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

---Wrap `data` in raw DEFLATE STORED blocks (BTYPE=00), <=65535 bytes each.
---@param data string
---@return string
local function deflate_stored(data)
    local n = #data
    if n == 0 then
        -- One final empty stored block: BFINAL=1, LEN=0, NLEN=0xFFFF.
        return string.char(0x01, 0x00, 0x00, 0xFF, 0xFF)
    end
    local out = {}
    local pos = 1
    while pos <= n do
        local chunk_end = math.min(pos + 65534, n) -- up to 65535 bytes
        local len = chunk_end - pos + 1
        local nlen = 0xFFFF - len
        out[#out + 1] = string.char(chunk_end == n and 0x01 or 0x00) -- BFINAL + BTYPE=00, padded
        out[#out + 1] = string.char(len % 256, math.floor(len / 256) % 256)   -- LEN  (LE16)
        out[#out + 1] = string.char(nlen % 256, math.floor(nlen / 256) % 256) -- NLEN (LE16)
        out[#out + 1] = data:sub(pos, chunk_end)
        pos = chunk_end + 1
    end
    return table.concat(out)
end

---zlib stream = 0x78 0x01 header + stored deflate + big-endian Adler-32.
---@param data string
---@return string
local function zlib_compress(data)
    local a, b = adler32(data)
    local adler_be = string.char(
        math.floor(b / 256) % 256, b % 256,
        math.floor(a / 256) % 256, a % 256)
    return string.char(0x78, 0x01) .. deflate_stored(data) .. adler_be
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---Standard base64 with `=` padding.
---@param data string
---@return string
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
-- Main
-- ---------------------------------------------------------------------------

local out_path = arg[1]
if not out_path then
    io.stderr:write("usage: lua tests/bundle_solutions.lua <out.txt> <file-or-dir> [more...]\n")
    os.exit(2)
end

local inputs = {}
local with_reference = false
for k = 2, #arg do
    if arg[k] == "--reference" then
        with_reference = true
    else
        inputs[#inputs + 1] = arg[k]
    end
end
if #inputs == 0 then
    die("no input files given")
end

local files = collect_files(inputs)
if #files == 0 then
    die("no dump files to bundle")
end

local payloads = {}
for _, path in ipairs(files) do
    local payload = read_payload(path)
    if with_reference then
        payload = add_reference_solution(payload, path)
    end
    payloads[#payloads + 1] = payload
end

-- Assemble the envelope JSON by pure concatenation -- the per-Solution fragments
-- are already valid JSON objects, so no encoding/parsing happens here.
local envelope_json = string.format(
    '{"signature":"%s","version":%d,"solutions":[%s]}',
    SIGNATURE, VERSION, table.concat(payloads, ","))

local shared = base64_encode(zlib_compress(envelope_json))

local fh, open_err = io.open(out_path, "wb")
if not fh then
    die("cannot open '" .. out_path .. "' for writing: " .. tostring(open_err))
end
fh:write(shared)
fh:close()

io.stderr:write(string.format(
    "bundled %d solution(s), %d JSON bytes -> %d char shared string at %s\n",
    #payloads, #envelope_json, #shared, out_path))
