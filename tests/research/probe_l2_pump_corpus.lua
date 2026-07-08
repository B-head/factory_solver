-- Convergence sweep of the SHIPPED two-stage L2 pipeline (pre_solve
-- forwerd_solve: target rescue + violation lock + mode compression) over one
-- explorer dump. Complements probe_l2_twostage.lua, which validated the
-- lock's build shape on fixed builds: this drives the real state machine, so
-- it catches orchestration hangs (livelocks, preserve-list drops) and rescue
-- interplay the fixed-build A/B could not.
--
-- Emits: RESULT\t<file>\t<norm>=<state>/<rebuilds>/<lockphase>/<compressphase>
--        \timp=<physical shortage total>\tdmp=<physical surplus total>\ttgt=<target relax>
--
-- Usage: lua tests/research/probe_l2_pump_corpus.lua <dump.lua>
--        pwsh tests/research/run_corpus.ps1 -Driver tests/research/probe_l2_pump_corpus.lua

require "tests/headless_env"

local pre_solve = require "manage/pre_solve"
local rl = require "tests/research/research_lib"

local path = assert(arg[1], "usage: lua tests/research/probe_l2_pump_corpus.lua <dump.lua>")
local prob = rl.load(path)
local name = path:match("([^/\\]+)%.lua$") or path

local function physical_totals(problem, x)
    local imp, dmp, tgt = 0, 0, 0
    for key, p in pairs(problem.primals) do
        local terms = problem.subject_terms[key]
        local w = math.abs((terms and p.material and terms[p.material]) or 1)
        if p.kind == "shortage_source" then
            imp = imp + w * (x[key] or 0)
        elseif p.kind == "surplus_sink" then
            dmp = dmp + w * (x[key] or 0)
        elseif p.kind == "elastic" or p.kind == "headroom" then
            tgt = tgt + math.abs(x[key] or 0)
        end
    end
    return imp, dmp, tgt
end

local out = { "RESULT\t" .. name }
for _, norm in ipairs({ "l2_baseline", "l2" }) do
    local solution = {
        name = "pump", constraints = prob.constraints, production_lines = {},
        solver_state = "ready", solver_norm = norm,
    }
    local saved = pre_solve.to_normalized_production_lines
    pre_solve.to_normalized_production_lines = function() return prob.normalized_lines end
    local rebuilds, steps, hung = 0, 0, false
    while solution.solver_state == "ready" or solution.solver_state == "calculating" do
        if solution.solver_state == "ready" then rebuilds = rebuilds + 1 end
        pre_solve.forwerd_solve({ research_bonuses = nil }, solution)
        steps = steps + 1
        if steps > 20000 then hung = true break end
    end
    pre_solve.to_normalized_production_lines = saved
    local imp, dmp, tgt = -1, -1, -1
    if solution.problem and solution.raw_variables then
        imp, dmp, tgt = physical_totals(solution.problem, solution.raw_variables.x)
    end
    out[#out + 1] = string.format("%s=%s/%d/%s/%s\timp_%s=%.8g\tdmp_%s=%.8g\ttgt_%s=%.8g",
        norm, hung and "HUNG" or tostring(solution.solver_state), rebuilds,
        tostring(solution.l2_lock and solution.l2_lock.phase),
        tostring(solution.l2_compress and solution.l2_compress.phase),
        norm, imp, norm, dmp, norm, tgt)
end
print(table.concat(out, "\t"))
