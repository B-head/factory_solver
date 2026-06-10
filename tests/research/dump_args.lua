---@diagnostic disable: undefined-global
-- (io/os/arg are stdlib globals; LuaLS targets the Factorio sandbox where they
--  are stripped, but this file only runs in a standalone Lua host.)

-- Reconstruct the explore_emit / explore args string from a dumped problem
-- file's `meta`. The explorer is deterministic for a fixed (modset, seed,
-- config) -- see tests/explore_chains.ps1's -ReuseProblems note -- so feeding
-- this string back to remote.call('factory_solver_explore','explore_emit', ...)
-- under the SAME mod set regenerates the byte-identical chain (now with the
-- payload_json field tests/bundle_solutions.lua needs). Use it to reproduce a
-- specific existing dump without guessing the launcher's current -Seeds /
-- -StartSeed / config matrix: the file already carries everything in `meta`.
--
-- The field->token mapping mirrors build_problem's parser in
-- tests/chain_explorer.lua (void=ex/in, nosrc=ex/in, qual=on/off, ...).
--
-- Usage (from the repo root):
--   lua tests/research/dump_args.lua <path-to-dumped-problem.lua>

local path = arg[1]
if not path then
    io.stderr:write("usage: lua tests/research/dump_args.lua <dumped-problem.lua>\n")
    os.exit(2)
end

local chunk, load_err = loadfile(path)
if not chunk then
    io.stderr:write("dump_args: cannot load '" .. path .. "': " .. tostring(load_err) .. "\n")
    os.exit(1)
end
local ok, dump = pcall(chunk)
if not ok or type(dump) ~= "table" or type(dump.meta) ~= "table" then
    io.stderr:write("dump_args: '" .. path .. "' is not a dumped problem table\n")
    os.exit(1)
end

local m = dump.meta
local args = string.format(
    "seed=%d;hops=%d;mode=%s;init=%s;void=%s;nosrc=%s;pins=%d;qual=%s;target=%s;closure=%s;cycleonly=%s",
    m.seed, m.hops, m.mode, m.init,
    m.exclude_void and "ex" or "in",
    m.exclude_source_sink and "ex" or "in",
    m.pins,
    m.use_quality and "on" or "off",
    m.target_mode,
    m.do_close and "on" or "off",
    m.cycle_only and "on" or "off")
-- Optional tokens build_problem also reads: seedrecipe= (only set when the chain
-- was pinned to a forced seed recipe) and tq= (target quality, only meaningful
-- in quality mode).
if m.seed_override then args = args .. ";seedrecipe=" .. m.seed_override end
if m.use_quality then args = args .. ";tq=" .. tostring(m.target_quality) end

print(args)
