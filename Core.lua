local ADDON, ns = ...

-- Garu Combat Text -- a standalone addon for damage-dealt (per target) and
-- healing-received combat text. Fully self-contained: its own event dispatcher,
-- settings, Meter engine, helpers and config panel. Each feed has its own
-- movable anchor point (Anchors.lua), optionally pinned to a frame.

--------------------------------------------------------------------------
-- Event dispatcher + combat-safe queue
--------------------------------------------------------------------------
local dispatcher = CreateFrame("Frame")
local handlers, queue = {}, {}
function ns.On(event, fn)
    if not handlers[event] then
        if not pcall(dispatcher.RegisterEvent, dispatcher, event) then return end
        handlers[event] = {}
    end
    handlers[event][#handlers[event] + 1] = fn
end
dispatcher:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]; if not list then return end
    for _, fn in ipairs(list) do fn(event, ...) end
end)
function ns.RunWhenSafe(fn)
    if InCombatLockdown() then queue[#queue + 1] = fn else fn() end
end
ns.On("PLAYER_REGEN_ENABLED", function()
    local q = queue; queue = {}
    for _, fn in ipairs(q) do fn() end
end)

--------------------------------------------------------------------------
-- Helpers (the modules + Meter expect these on ns)
--------------------------------------------------------------------------
ns.FLAT = "Interface\\Buttons\\WHITE8X8"
ns.GLOW = ns.FLAT
function ns.Font(_) return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF" end
function ns.Texture(_) return "Interface\\TargetingFrame\\UI-StatusBar" end
function ns.AdjustColor(r, g, b) return r, g, b end
ns.AbsorbSpellIds = {}     -- no absorb-spell list standalone (heal mana isn't filtered)
function ns.FormatNumber(v)
    v = v or 0
    if v >= 1e6 then return string.format("%.2fM", v / 1e6) end
    if v >= 1e4 then return string.format("%.1fk", v / 1e3) end
    return tostring(math.floor(v + 0.5))
end
ns.test = { combat = false }   -- set true via /gct test to preview

-- Shared icons for the miss/avoid count rows (Damage Taken + Actions feeds).
ns.AVOID_ICON = {
    DODGE   = "Interface\\ICONS\\Ability_Rogue_Sprint",
    PARRY   = "Interface\\ICONS\\Ability_Parry",
    BLOCK   = "Interface\\ICONS\\Ability_Warrior_DefensiveStance",
    MISS    = "Interface\\ICONS\\Ability_Warrior_Disarm",
    ABSORB  = "Interface\\ICONS\\Spell_Holy_PowerWordShield",
    RESIST  = "Interface\\ICONS\\Spell_Shadow_AntiShadow",
    IMMUNE  = "Interface\\ICONS\\Spell_Holy_DivineShield",
    DEFLECT = "Interface\\ICONS\\Ability_Warrior_ShieldWall",
    EVADE   = "Interface\\ICONS\\Ability_Rogue_Sprint",
}

--------------------------------------------------------------------------
-- Settings (SavedVariables: GaruCombatTextDB)
--------------------------------------------------------------------------
ns.defaults = {
    locked = true,   -- /gct unlock to drag the feed anchors
    general = {
        fontSize = 12, fontOutline = "OUTLINE",
    },
    enemyText = {   -- Damage Dealt: cumulative damage you deal to your current target
        enabled = true, style = "float", showBar = true, rowHeight = 18,
        barColor = { 0.80, 0.20, 0.20 }, includePet = true,
        anchor = "CENTER", xOffset = -30, yOffset = 0, growth = "DOWN", align = "LEFT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 6,
        fontSize = 12, maxSize = 34, scaleBySeverity = false, bigPct = 40,
        schoolColors = true, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = true, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, persist = true,
        hideBlizzardFCT = false, onFocus = false,
        layout = "radial", radius = 66, arc = 105, arcAngle = 0, arcFixed = true,
        attach = "free", point = { "CENTER", 50, -30 },
    },
    healText = {
        enabled = true, style = "float", showBar = true, rowHeight = 16,
        barColor = { 0.20, 0.80, 0.30 }, anchor = "CENTER", xOffset = -24, yOffset = 0,
        growth = "UP", align = "RIGHT", matchFrameWidth = false, textWidth = 300,
        lineSpacing = 18, maxLines = 6, fontSize = 12, maxSize = 30, scaleBySeverity = false,
        bigPct = 30, schoolColors = true, crit = false, showLabel = false, maxLabel = 0,
        showIcon = true, sortMode = "amount", threshold = 0, showMana = false,
        valueMode = "amount", includeMana = true, windowSecs = 5, holdSecs = 5,
        layout = "radial", radius = 66, arc = 105, arcAngle = 180, arcFixed = true,
        attach = "free", point = { "CENTER", -50, -30 },
    },
    takenText = {   -- Damage Taken: cumulative damage you take, one row per attack type
        enabled = true, style = "float", showBar = true, rowHeight = 18,
        barColor = { 0.80, 0.30, 0.20 },
        anchor = "CENTER", xOffset = 0, yOffset = 0, growth = "UP", align = "LEFT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 6,
        fontSize = 12, maxSize = 34, scaleBySeverity = false, bigPct = 40,
        schoolColors = true, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = false, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, showAvoid = true, holdSecs = 5,
        layout = "radial", radius = 66, arc = 105, arcAngle = 180, arcFixed = true,
        attach = "free", point = { "CENTER", -50, -30 },
    },
    actionsText = {   -- Actions: how many of your attacks the current target avoided (per target)
        enabled = true, style = "float", includePet = false,
        anchor = "CENTER", xOffset = 0, yOffset = 0, growth = "UP", align = "LEFT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 8,
        fontSize = 12, maxSize = 30, scaleBySeverity = false, bigPct = 40,
        schoolColors = false, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = false, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, persist = true,
        layout = "radial", radius = 66, arc = 105, arcAngle = 0, arcFixed = true,
        attach = "free", point = { "CENTER", 50, 30 },
    },
    combatTimer = {   -- "Combat M:SS" for your current target; positioned on its own
        enabled = true, attach = "enemy",   -- "free" | "enemy" | "taken" | "heal"
        point = { "CENTER", 0, 0 }, xOffset = 27, yOffset = -22, fontSize = 12,
    },
}

local function copyDefaults(src, dst)
    dst = dst or {}
    for k, v in pairs(src) do
        if type(v) == "table" then dst[k] = copyDefaults(v, type(dst[k]) == "table" and dst[k] or {})
        elseif dst[k] == nil then dst[k] = v end
    end
    return dst
end

-- IMPORTANT: SavedVariables are only populated at ADDON_LOADED (after this file's
-- main chunk runs), so the DB must be wired up there -- doing it in the main chunk
-- would bind ns.db to a throwaway table and lose settings every reload.
local function initDB()
    GaruCombatTextDB = copyDefaults(ns.defaults, GaruCombatTextDB)
    ns.db = GaruCombatTextDB

    -- Plain-text (float) only; severity scaling, crit emphasis and the sized box were
    -- all removed -- the feed is placed at a movable anchor point.
    for _, k in ipairs({ "enemyText", "healText", "takenText", "actionsText" }) do
        local c = ns.db[k]
        c.style, c.scaleBySeverity, c.crit, c.matchFrameWidth = "float", false, false, false
        c.showCombatTime = false   -- the standalone Combat Timer element handles this now
    end
    if ns.db.healText.valueMode == "permana" then ns.db.healText.valueMode = "both" end  -- removed option
end

ns.On("ADDON_LOADED", function(_, name)
    if name == ADDON then initDB() end
end)

--------------------------------------------------------------------------
-- Anchors. Anchors.lua creates the movable anchor points and fills these:
--   ns.frames.target  -> damage-dealt anchor   (.unit = "target")
--   ns.healHostFrame  -> healing-received anchor (.unit = "player")
--------------------------------------------------------------------------
ns.frames = {}
ns.groupFrames = {}

--------------------------------------------------------------------------
-- Reset
--------------------------------------------------------------------------
function ns.ResetSettings()
    GaruCombatTextDB = copyDefaults(ns.defaults, {})
    ns.db = GaruCombatTextDB
    if ns.RefreshAnchors then ns.RefreshAnchors() end
    if ns.RefreshEnemyText then ns.RefreshEnemyText() end
    if ns.RefreshHealText then ns.RefreshHealText() end
    if ns.RefreshTimer then ns.RefreshTimer() end
    print("|cff66ccffGaru Combat Text|r: settings reset to defaults.")
end
