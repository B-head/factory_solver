-- Quality-tier scaling helpers. Translates a QualityID (string name or
-- LuaQualityPrototype) into the engine's level / multiplier values that the
-- rest of the accessor layer applies to machine throughput and module effects.
-- Part of the manage/accessor.lua family; consumers reach these through the
-- accessor facade, not by requiring this module directly.

local M = {}

---comment
---@param quality QualityID
function M.get_quality_level(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    return quality_prototype and quality_prototype.level or 0
end

---Return the base multiplier for a quality tier (normal=1, uncommon=1.3, ...).
---LuaQualityPrototype::default_multiplier (Factorio 2.0.69+ runtime read)
---reflects per-QualityPrototype customisation, so this is the single entry
---point used to retire the hardcoded `1 + level * 0.3` everywhere.
---Falls back to `1 + level * 0.3` on older Factorio versions or when
---default_multiplier is not exposed.
---@param quality QualityID
---@return number
function M.get_quality_default_multiplier(quality)
    local quality_prototype = (type(quality) == "string") and prototypes.quality[quality] or quality
    if quality_prototype then
        local m = quality_prototype.default_multiplier
        if m then
            return m
        end
        return 1 + quality_prototype.level * 0.3
    end
    return 1
end

---Return the quality multiplier applied to module effects.
---Uses the quality tier's default_multiplier (matches the engine's own
---quality scaling of module effects). Used to replace the hardcoded
---`(1 + quality_level * 0.3)` inside `get_total_effectivity`'s `modify()`.
---@param quality QualityID
---@return number
function M.get_module_quality_multiplier(quality)
    return M.get_quality_default_multiplier(quality)
end

return M
