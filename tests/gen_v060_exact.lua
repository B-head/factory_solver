-- Regenerate tests/fixtures/bundle16_v060.lua with constraints forced to EXACT
-- (equal). Run from the 0.6.0 worktree root. Under exact the degenerate free
-- dimension is gone, so 0.6.0(hardgate) converges to the same machine counts as
-- the reference -- the agreement (not any single solver) is what makes this a
-- trustworthy baseline.
package.path = "./?.lua;./?/init.lua;" .. package.path
package.preload["__flib__/format"] = function() local f={}; function f.number(a) return tostring(a) end; return f end
local create_problem = require "solver/create_problem"
local lp = require "solver/linear_programming"
local harness = require "tests/harness"
local tn = require "manage/typed_name"

local bundle = assert(loadfile(arg[1]))()
local out_path = arg[2]
local names = {}; for n in pairs(bundle) do names[#names+1]=n end; table.sort(names)
local function nf(x) if x==math.floor(x) then return string.format("%d",x) end; return string.format("%.10g",x) end

local out = {
  "-- 0.6.0 (hardgate) solution for every bundle16 Solution with all constraints",
  "-- forced to EXACT (equal). Under exact the lower/upper degenerate free dimension",
  "-- is removed, so 0.6.0 and the reference solver converge to the SAME machine",
  "-- counts -- the agreement is the trust anchor (no single solver is gold).",
  "-- machines = sum over PLACED-line recipe vars (bridges excluded). NOT shipped.",
  "-- Regenerate: tests/gen_v060_exact.lua run in a 0.6.0 git worktree.",
  "return {",
}
for _, name in ipairs(names) do
  local b = bundle[name]
  local cons = {}
  for i, c in ipairs(b.constraints) do
    local d = {}; for k,v in pairs(c) do d[k]=v end; d.limit_type="equal"; cons[i]=d
  end
  local placed = {}
  for _, ln in ipairs(b.lines) do placed[tn.typed_name_to_variable_name(ln.recipe_typed_name)] = true end
  local ok, problem = pcall(create_problem.create_problem, name, cons, b.lines)
  local state, vars = "create_problem-error", nil
  if ok then state, vars = harness.solve_to_completion(lp, problem, { tolerance = 1e-7, iterate_limit = 800 }) end
  local M, imp, sur, T = 0, 0, 0, 0
  if state == "finished" then
    for k, v in pairs(vars.x) do
      v = math.abs(v)
      if placed[k] then M = M + v
      elseif k:sub(1,17)=="|shortage_source|" or k:sub(1,16)=="|initial_source|" then imp = imp + v
      elseif k:sub(1,14)=="|surplus_sink|" then sur = sur + v
      elseif k:sub(1,9)=="|elastic|" then T = T + v end
    end
  end
  out[#out+1] = string.format("    [%q] = { state = %q, T = %s, import = %s, surplus = %s, machines = %s },",
    name, state, nf(T), nf(imp), nf(sur), nf(M))
  io.write(string.format("  %-22s state=%-10s M=%s\n", name, state, nf(M)))
end
out[#out+1] = "}"; out[#out+1] = ""
local f = assert(io.open(out_path, "w")); f:write(table.concat(out, "\n")); f:close()
io.write("wrote " .. out_path .. "\n")
