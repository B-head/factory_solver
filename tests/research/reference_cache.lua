---@diagnostic disable: undefined-global
-- Per-dump cache for the lexicographic reference solver
-- (tests/research/reference_solver.lua). Solving the reference is five staged
-- LPs plus two producibility fixpoints -- ~45 min over the full corpus -- yet it
-- is a PURE, DETERMINISTIC function of (dump bytes, reference definition). This
-- module memoizes that result to disk so ship-side iteration
-- (probe_reference_compare) re-solves only the shipped pipeline.
--
-- PARALLEL-SAFE BY CONSTRUCTION. run_corpus.ps1 fans one `lua <driver> <dump>`
-- process per file across every core, so there is no single shared cache file to
-- serialize on: each dump maps to its own <hash>.lua entry and distinct dumps
-- never write the same path. Writes go temp-then-rename so a concurrent reader
-- sees either the old file or the whole new one, never a partial.
--
-- INVALIDATION (never silently stale):
--   * key   = content hash of the dump bytes -> regenerating the corpus (new
--             problem bytes under the same filename) misses automatically.
--   * stamp = fingerprint of the reference DEFINITION (the files in FP_FILES:
--             reference_solver.lua, the LP build, the IPM, typed_name, harness).
--             Editing any of them recomputes every entry. The reference OVERRIDES
--             costs per stage, so solver/cost tiers do NOT affect its output and
--             are deliberately absent. Determinants reachable only through a deep
--             require of these files (e.g. a Cholesky helper under
--             linear_programming) are NOT tracked -- pass FS_REFCACHE=refresh
--             (or delete the cache dir) after touching those.
--
-- CONTROL (env vars, so run_corpus's fan-out inherits them from the parent
-- shell):
--   FS_REFCACHE      on (default) | off (bypass: never read, never write)
--                    | refresh (ignore existing entries, recompute + overwrite)
--   FS_REFCACHE_DIR  cache directory (default tests/research/.refcache, relative
--                    to the repo root the workers run in)

local M = {}

local MODE = (os.getenv("FS_REFCACHE") or "on"):lower()
local DIR = os.getenv("FS_REFCACHE_DIR") or "tests/research/.refcache"

-- The files whose content determines a reference solution. Hashed together into
-- the fingerprint stamped on every entry; a mismatch on read is a miss.
local FP_FILES = {
    "tests/research/reference_solver.lua",
    "solver/create_problem.lua",
    "solver/linear_programming.lua",
    "manage/typed_name.lua",
    "tests/harness.lua",
}

local SEP = package.config:sub(1, 1) -- "\" on Windows, "/" on POSIX
local IS_WINDOWS = SEP == "\\"

-- ---- primitives -------------------------------------------------------------

---Read a whole file as a byte string, or nil if it cannot be opened.
---@param path string
---@return string?
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

---Two independent polynomial rolling hashes over the bytes, combined with the
---length. Pure Lua and double-exact (every intermediate stays < 2^53), so it is
---identical across stock Lua 5.2/5.3/5.4 and LuaJIT -- a cache written by one
---reads back under another. Not cryptographic; collision risk over a
---few-thousand-file corpus is negligible and a miss only costs a recompute.
---@param s string
---@return string hex-free decimal key safe as a filename
local function hash_string(s)
    local h1, h2 = 7, 13
    local P1, P2 = 1000000007, 998244353
    for i = 1, #s do
        local b = s:byte(i)
        h1 = (h1 * 131 + b) % P1
        h2 = (h2 * 137 + b) % P2
    end
    return string.format("%010d-%010d-%d", h1, h2, #s)
end

local _fp
---@return string fingerprint of the reference definition (memoized per process)
local function fingerprint()
    if _fp then return _fp end
    local acc = {}
    for _, p in ipairs(FP_FILES) do acc[#acc + 1] = read_file(p) or "" end
    _fp = hash_string(table.concat(acc, "\0"))
    return _fp
end

-- Single-shot drivers process one dump, so memoizing the last (path -> hash)
-- serves both the load probe and the store without re-reading the dump.
local _last_path, _last_hash
---@param dump_path string
---@return string? cache file path for this dump, nil if the dump is unreadable
local function entry_path(dump_path)
    if dump_path ~= _last_path then
        local s = read_file(dump_path)
        if not s then return nil end
        _last_path, _last_hash = dump_path, hash_string(s)
    end
    return DIR .. "/" .. _last_hash .. ".lua"
end

---Create the cache directory if absent. Idempotent and race-tolerant (many
---workers may call it at once); the os.execute result is ignored.
local function ensure_dir(dir)
    if IS_WINDOWS then
        -- cmd's mkdir/if-exist want backslashes; io.open is happy with either.
        local w = dir:gsub("/", "\\")
        os.execute('if not exist "' .. w .. '" mkdir "' .. w .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

-- ---- serialization (this entry shape only, not a general serpent) -----------

---@param n number
---@return string a Lua expression that round-trips n exactly
local function fmt_num(n)
    if n ~= n then return "0/0" end -- NaN (should not arise in |x| sums)
    if n == math.huge then return "math.huge" end
    if n == -math.huge then return "-math.huge" end
    return string.format("%.17g", n)
end

---@param list string[]
---@return string a Lua array literal of quoted strings
local function fmt_list(list)
    local parts = {}
    for i = 1, #list do parts[i] = string.format("%q", list[i]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

---@param e table the cached reference entry (fingerprint already stamped)
---@return string
local function serialize(e)
    return string.format(
        "return {state=%q,n_mats=%s,T=%s,Vp=%s,Vc=%s,Vf=%s,M=%s,S=%s,Nv=%s," ..
        "steps=%s,fingerprint=%q,producible=%s,consumable=%s}\n",
        e.state, fmt_num(e.n_mats), fmt_num(e.T), fmt_num(e.Vp), fmt_num(e.Vc),
        fmt_num(e.Vf), fmt_num(e.M), fmt_num(e.S), fmt_num(e.Nv), fmt_num(e.steps),
        e.fingerprint, fmt_list(e.producible), fmt_list(e.consumable))
end

-- ---- public API -------------------------------------------------------------

---Load the cached reference entry for `dump_path`, or nil on a miss (no entry,
---unreadable, malformed, fingerprint mismatch, or FS_REFCACHE off/refresh).
---@param dump_path string
---@return table? entry { state, n_mats, T, Vp, Vc, Vf, M, S, Nv, steps,
---  producible: string[], consumable: string[] }
function M.load(dump_path)
    if MODE == "off" or MODE == "refresh" then return nil end
    local cp = entry_path(dump_path)
    if not cp then return nil end
    local chunk = loadfile(cp)
    if not chunk then return nil end
    local ok, e = pcall(chunk)
    if not ok or type(e) ~= "table" then return nil end
    if e.fingerprint ~= fingerprint() then return nil end
    return e
end

---Persist `entry` for `dump_path`. Stamps the current fingerprint and writes
---temp-then-rename. A no-op under FS_REFCACHE=off; silently skips (rather than
---raising) if the directory or file cannot be written.
---@param dump_path string
---@param entry table the reference result minus its fingerprint
function M.store(dump_path, entry)
    if MODE == "off" then return end
    local cp = entry_path(dump_path)
    if not cp then return end
    ensure_dir(DIR)
    entry.fingerprint = fingerprint()
    local tmp = cp .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end -- read-only fs, missing dir, etc.: just don't cache
    f:write(serialize(entry))
    f:close()
    os.remove(cp) -- Windows os.rename will not replace an existing file
    if not os.rename(tmp, cp) then os.remove(tmp) end
end

M.fingerprint = fingerprint
M.hash_string = hash_string

return M
