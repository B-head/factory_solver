-- Auto-generated from manage/smoke_rcon.lua M.bundle16_drop_report (CONFIRMED,
-- not guessed): the EXACT set of production-line recipe identities each interop
-- codec drops when round-tripping every Solution in tests/fixtures/bundle16_shared.
-- Keys are "<type>|<name>|<quality>". An empty list = a lossless round-trip for
-- that codec. native (solution_codec) is lossless for all and is asserted
-- structurally in check_bundle16_codecs rather than listed here. Regenerate with
-- pwsh tests/smoke_rcon.ps1 -Mods ...,space-age,quality,elevated-rails -KeepRun
-- then read write/script-output/bundle16_drops.txt. NOT shipped (tests/*).
--
-- STATUS (2026-06-17): the FP drop sets are confirmed INTENDED (FP has no
-- quality / no representation for these virtual recipes). The YAFC drop sets are
-- pinned-as-observed but NOT yet confirmed correct -- the maintainer flagged them
-- as suspicious (e.g. YAFC dropping <mine>/<grow>/<spoil>/<pump> virtual recipes
-- and <run>fusion-*). If the YAFC codec is fixed to carry more of these, this
-- table must be regenerated; until then the test pins current behaviour, it does
-- NOT certify it as desired.
return {
    ["Asteroid up cycleing"] = {
        FP = { "recipe|advanced-carbonic-asteroid-crushing|legendary", "recipe|advanced-metallic-asteroid-crushing|legendary", "recipe|advanced-oxide-asteroid-crushing|legendary", "recipe|carbonic-asteroid-reprocessing|epic", "recipe|carbonic-asteroid-reprocessing|rare", "recipe|carbonic-asteroid-reprocessing|uncommon", "recipe|metallic-asteroid-reprocessing|epic", "recipe|metallic-asteroid-reprocessing|rare", "recipe|metallic-asteroid-reprocessing|uncommon", "recipe|oxide-asteroid-reprocessing|epic", "recipe|oxide-asteroid-reprocessing|rare", "recipe|oxide-asteroid-reprocessing|uncommon" },
        Helmod = {},
        YAFC = {},
    },
    ["Begining"] = {
        FP = { "virtual_recipe|<research>logistic-science-pack|normal" },
        Helmod = { "virtual_recipe|<research>logistic-science-pack|normal" },
        YAFC = { "virtual_recipe|<mine>copper-ore|normal", "virtual_recipe|<mine>iron-ore|normal", "virtual_recipe|<research>logistic-science-pack|normal" },
    },
    ["Fulgora bottom up"] = {
        FP = { "virtual_recipe|<research>electromagnetic-science-pack|normal" },
        Helmod = { "virtual_recipe|<pump>oil-ocean-shallow|normal", "virtual_recipe|<research>electromagnetic-science-pack|normal" },
        YAFC = { "virtual_recipe|<pump>oil-ocean-shallow|normal", "virtual_recipe|<research>electromagnetic-science-pack|normal" },
    },
    ["Fulgora top down"] = {
        FP = { "virtual_recipe|<research>electromagnetic-science-pack|normal" },
        Helmod = { "virtual_recipe|<pump>oil-ocean-shallow|normal", "virtual_recipe|<research>electromagnetic-science-pack|normal" },
        YAFC = { "virtual_recipe|<pump>oil-ocean-shallow|normal", "virtual_recipe|<research>electromagnetic-science-pack|normal" },
    },
    ["Fusion"] = {
        FP = { "virtual_recipe|<run>fusion-generator|normal", "virtual_recipe|<run>fusion-reactor|normal" },
        Helmod = {},
        YAFC = { "virtual_recipe|<run>fusion-generator|normal", "virtual_recipe|<run>fusion-reactor|normal" },
    },
    ["Generator"] = {
        FP = { "virtual_recipe|<run>steam-engine|normal" },
        Helmod = {},
        YAFC = { "virtual_recipe|<pump>water|normal" },
    },
    ["Gleba circuit"] = {
        FP = {},
        Helmod = {},
        YAFC = { "virtual_recipe|<grow>jellystem:jellynut-seed|normal", "virtual_recipe|<grow>yumako-tree:yumako-seed|normal", "virtual_recipe|<spoil>copper-bacteria|normal", "virtual_recipe|<spoil>iron-bacteria|normal" },
    },
    ["Gleba loop"] = {
        FP = {},
        Helmod = {},
        YAFC = { "virtual_recipe|<grow>jellystem:jellynut-seed|normal", "virtual_recipe|<grow>yumako-tree:yumako-seed|normal" },
    },
    ["Module and beacon"] = {
        FP = {},
        Helmod = {},
        YAFC = {},
    },
    ["Nuclear"] = {
        FP = { "virtual_recipe|<run>nuclear-reactor|normal", "virtual_recipe|<run>steam-turbine|normal" },
        Helmod = {},
        YAFC = { "virtual_recipe|<pump>water|normal" },
    },
    ["Oil Processing 1"] = {
        FP = {},
        Helmod = {},
        YAFC = {},
    },
    ["Oil Processing 2"] = {
        FP = {},
        Helmod = {},
        YAFC = {},
    },
    ["Quality loop"] = {
        FP = { "recipe|electronic-circuit-recycling|rare", "recipe|electronic-circuit-recycling|uncommon", "recipe|electronic-circuit|epic", "recipe|electronic-circuit|rare", "recipe|electronic-circuit|uncommon" },
        Helmod = {},
        YAFC = {},
    },
    ["Rocket"] = {
        FP = {},
        Helmod = { "virtual_recipe|<run>rocket-silo:rocket-part:space-age|normal" },
        YAFC = { "virtual_recipe|<run>rocket-silo:rocket-part:space-age|normal" },
    },
    ["Simple"] = {
        FP = {},
        Helmod = {},
        YAFC = {},
    },
    ["SpacePlatform"] = {
        FP = { "virtual_recipe|<run>thruster|normal" },
        Helmod = { "virtual_recipe|<run>thruster|normal" },
        YAFC = { "virtual_recipe|<run>thruster|normal" },
    },
}
