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
        -- RegisterEvent throws on events this client doesn't have; skip those so a
        -- single bad name can't abort the rest of a file's load.
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
-- Client / API compatibility
--------------------------------------------------------------------------
-- WoW Forever runs Classic content on the Midnight (12.x) client, so it reports a
-- Classic WOW_PROJECT_ID but exposes the modern addon API: the loose GetSpell* and
-- SetCVar globals are gone, and the widget set is the retail one. Project id can't
-- tell it apart, so everything below feature-detects the API it needs instead.

-- Midnight hands addon-tainted code "secret" values for some unit info. A secret
-- can be stored and passed around, but ordering comparisons on one throw outright
-- and arithmetic on one produces another secret, so a number derived from it can
-- never reach a widget setter. Test before touching one; on the older Classic
-- clients there are no secrets and issecretvalue doesn't exist.
local issecret = _G.issecretvalue
function ns.IsSecret(v)
    return issecret ~= nil and issecret(v)
end

-- Restricted APIs refuse by returning *nothing* rather than by erroring, and a
-- secret boolean still reports as "boolean" to type(). So a predicate only counts
-- as answered when it hands back a real, non-secret boolean; anything else means
-- "the client won't say", which is not the same as "no".
function ns.Truth(v)
    if ns.IsSecret(v) then return nil end
    if type(v) ~= "boolean" then return nil end
    return v
end

-- Spell icon lookup. C_Spell.GetSpellTexture is the only form on Forever/Midnight;
-- the GetSpellTexture global is what the older Classic clients ship.
local C_SpellGetTexture = C_Spell and C_Spell.GetSpellTexture
function ns.SpellTexture(spellId)
    if not spellId then return nil end
    local ok, tex
    if C_SpellGetTexture then
        ok, tex = pcall(C_SpellGetTexture, spellId)
    elseif GetSpellTexture then
        ok, tex = pcall(GetSpellTexture, spellId)
    end
    return ok and tex or nil
end

-- Spell name, for labelling a row the damage meter reports by id alone.
local C_SpellGetInfo = C_Spell and C_Spell.GetSpellInfo
function ns.SpellName(spellId)
    if not spellId then return nil end
    if C_SpellGetInfo then
        local ok, info = pcall(C_SpellGetInfo, spellId)
        if ok and type(info) == "table" then return info.name end
    end
    if _G.GetSpellInfo then
        local ok, name = pcall(_G.GetSpellInfo, spellId)
        if ok then return name end
    end
    return nil
end

-- SetCVar moved under C_CVar; the global is still around on older clients only.
-- Midnight also renamed the floating-combat-text CVars with a "_v2" suffix, so
-- write to whichever spelling this client actually knows. Setting an unknown CVar
-- throws, hence the existence check and the pcall around the write.
--
-- Writing a gameplay CVar is protected during combat lockdown: doing it from
-- tainted addon code pops Blizzard's "has been blocked from an action only
-- available to the Blizzard UI" dialog. So we never write in combat -- we record
-- what we want and apply it the moment combat ends. Writes are also skipped when
-- the CVar already holds the value, which is what most calls turn out to be.
local setCVar = (C_CVar and C_CVar.SetCVar) or SetCVar
local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar

local desiredCVar = {}     -- [cvar] = value to apply once we're allowed to
local flushQueued = false

local function flushCVars()
    flushQueued = false
    for cvar, value in pairs(desiredCVar) do
        desiredCVar[cvar] = nil
        local ok, current = pcall(getCVar, cvar)
        if ok and current ~= nil and tostring(current) ~= tostring(value) then
            pcall(setCVar, cvar, value)
        end
    end
end

function ns.SetCVar(name, value)
    if not setCVar or not getCVar then return end
    for _, candidate in ipairs({ name .. "_v2", name }) do
        local ok, current = pcall(getCVar, candidate)
        if ok and current ~= nil then
            if tostring(current) == tostring(value) then return end   -- already right
            desiredCVar[candidate] = value
            -- RunWhenSafe applies it now when we're out of combat, or queues it for
            -- PLAYER_REGEN_ENABLED. One flusher covers however many CVars pile up.
            if not flushQueued then
                flushQueued = true
                ns.RunWhenSafe(flushCVars)
            end
            return
        end
    end
end

--------------------------------------------------------------------------
-- Combat-log identity
--------------------------------------------------------------------------
-- Every feed has to answer two questions about each combat-log event: "did I
-- cause this?" and "did it land on my target, or on me?". Both used to be answered
-- by comparing GUIDs, which breaks on Midnight: UnitGUID can come back as a
-- secret, a secret never equals a plain string, so every event is dropped --
-- silently, with no error. That is exactly the "preview works, combat shows
-- nothing" shape.
--
-- The combat log already carries both answers in its own object flags, which are
-- plain numbers and cannot go secret. Ask those first, and keep the GUID compare
-- as a fallback for clients or events that don't set the special flags.
local bit_band = bit and bit.band or function() return 0 end

local AFFIL_MINE    = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PET      = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
local TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000
local PET_MASK      = TYPE_PET + TYPE_GUARDIAN
local TARGET_FLAG   = COMBATLOG_OBJECT_TARGET or 0x00010000
local FOCUS_FLAG    = COMBATLOG_OBJECT_FOCUS or 0x00020000

-- A secret never equals a plain value, so reporting "no match" for one loses
-- nothing real and avoids inspecting it (which throws).
function ns.SameGUID(a, b)
    if ns.IsSecret(a) or ns.IsSecret(b) then return false end
    if a == nil or b == nil then return false end
    return a == b
end

-- Did I -- or my pet, when the feed wants pets -- cause this event?
function ns.SourceIsMine(flags, includePet)
    flags = flags or 0
    if bit_band(flags, AFFIL_MINE) == 0 then return false end
    if bit_band(flags, PET_MASK) ~= 0 then return includePet and true or false end
    return true
end

-- Is this object me (not my pet)?
function ns.UnitIsMe(flags)
    flags = flags or 0
    return bit_band(flags, AFFIL_MINE) ~= 0 and bit_band(flags, PET_MASK) == 0
end

function ns.UnitIsMyTarget(flags) return bit_band(flags or 0, TARGET_FLAG) ~= 0 end
function ns.UnitIsMyFocus(flags)  return bit_band(flags or 0, FOCUS_FLAG) ~= 0 end


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

-- Shared icons for the miss/avoid count rows (Actions).
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
        copyPosition = true, copyMirror = true,   -- "Copy to..." brings position, mirrored
    },
    summary = {   -- post-fight summary behaviour (WoW Forever / any client with C_DamageMeter)
        holdSecs = 15,      -- how long a target's summary stays reachable once first shown
        fadeTime = 0.6,     -- the tail end of that window, spent dimming out
        requireDead = true, -- only report against something that died
    },
    enemyText = {   -- Damage Dealt: cumulative damage you deal to your target, or every enemy
        enabled = true, style = "float", showBar = true, rowHeight = 18,
        barColor = { 0.80, 0.20, 0.20 }, includePet = true,
        anchor = "CENTER", xOffset = 0, yOffset = 0, growth = "DOWN", align = "LEFT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 6,
        fontSize = 15, maxSize = 34, scaleBySeverity = false, bigPct = 40,
        schoolColors = true, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = false, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, persist = true,
        scope = "all", holdSecs = 10,   -- "target": per target; "all": every enemy, per fight
        hideBlizzardFCT = true, onFocus = false,
        pop = true, roll = true, splash = true, splashSide = "RIGHT", critFlash = true, killMark = true,   -- effects (Meter.lua)
        stackDir = "vertical", growthH = "RIGHT",   -- Stacked: one under another, or side by side
        layout = "radial", radius = 70, arc = 100, arcAngle = 0, arcFixed = true,
        attach = "free", point = { "CENTER", 75, -50 },
    },
    healText = {
        enabled = true, style = "float", showBar = true, rowHeight = 16,
        barColor = { 0.20, 0.80, 0.30 }, anchor = "CENTER", xOffset = 0, yOffset = 0,
        growth = "DOWN", align = "RIGHT", matchFrameWidth = false, textWidth = 300,
        lineSpacing = 18, maxLines = 6, fontSize = 15, maxSize = 30, scaleBySeverity = false,
        bigPct = 30, schoolColors = true, crit = false, showLabel = false, maxLabel = 0,
        showIcon = true, sortMode = "amount", threshold = 0, showMana = false,
        valueMode = "amount", includeMana = true, windowSecs = 5, holdSecs = 10,
        pop = true, roll = true, splash = true, splashSide = "LEFT", critFlash = true,
        stackDir = "vertical", growthH = "LEFT",
        layout = "radial", radius = 70, arc = 100, arcAngle = 180, arcFixed = true,
        attach = "free", point = { "CENTER", -150, -50 },
    },
    doneText = {   -- Healing Done: the healing you cast this fight, on anyone, one row per spell
        enabled = false, style = "float", showBar = true, rowHeight = 16,
        barColor = { 0.30, 0.85, 0.50 }, anchor = "CENTER", xOffset = 0, yOffset = 0,
        growth = "DOWN", align = "RIGHT", matchFrameWidth = false, textWidth = 300,
        lineSpacing = 18, maxLines = 6, fontSize = 15, maxSize = 30, scaleBySeverity = false,
        bigPct = 30, schoolColors = true, crit = false, showLabel = false, maxLabel = 0,
        showIcon = true, sortMode = "amount", threshold = 0, showMana = false, includePet = true,
        holdTime = 4, fadeTime = 0.8, holdSecs = 10,
        pop = true, roll = true, splash = true, splashSide = "LEFT", critFlash = true,
        stackDir = "vertical", growthH = "LEFT",
        layout = "radial", radius = 70, arc = 100, arcAngle = 180, arcFixed = true,
        attach = "free", point = { "CENTER", -150, 70 },
    },
    takenText = {   -- Damage Received: cumulative damage you take, one row per attack type
        enabled = true, style = "float", showBar = true, rowHeight = 18,
        barColor = { 0.80, 0.30, 0.20 },
        anchor = "CENTER", xOffset = 0, yOffset = 0, growth = "DOWN", align = "RIGHT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 6,
        fontSize = 15, maxSize = 34, scaleBySeverity = false, bigPct = 40,
        schoolColors = true, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = false, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, holdSecs = 10,
        pop = true, roll = true, splash = true, splashSide = "LEFT", critFlash = true,
        stackDir = "vertical", growthH = "LEFT",
        layout = "radial", radius = 70, arc = 100, arcAngle = 180, arcFixed = true,
        attach = "free", point = { "CENTER", -75, -50 },
    },
    actionsText = {   -- Actions: how many of your attacks your target (or every enemy) avoided
        enabled = true, style = "float", includePet = false,
        anchor = "CENTER", xOffset = 0, yOffset = 0, growth = "DOWN", align = "LEFT",
        matchFrameWidth = false, textWidth = 300, lineSpacing = 18, maxLines = 6,
        fontSize = 15, maxSize = 30, scaleBySeverity = false, bigPct = 40,
        schoolColors = true, crit = false, showLabel = false, maxLabel = 0, showIcon = true,
        showMana = false, showCombatTime = false, sortMode = "amount",
        holdTime = 4, fadeTime = 0.8, threshold = 0, persist = true,
        scope = "all", holdSecs = 10, pop = true,
        showIncoming = true,   -- the attacks on you that you avoided, in green, beside yours in red
        stackDir = "vertical", growthH = "RIGHT",
        layout = "radial", radius = 70, arc = 100, arcAngle = 0, arcFixed = true,
        attach = "free", point = { "CENTER", 150, -50 },
    },
    combatTimer = {   -- "Combat M:SS" for your current target; positioned on its own
        enabled = true, attach = "free",   -- "free" | "enemy" | "taken" | "heal"
        point = { "CENTER", 0, -235 }, xOffset = 0, yOffset = 0, fontSize = 14,
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
    for _, k in ipairs({ "enemyText", "healText", "doneText", "takenText", "actionsText" }) do
        local c = ns.db[k]
        c.style, c.scaleBySeverity, c.crit, c.matchFrameWidth = "float", false, false, false
        c.showCombatTime = false   -- the standalone Combat Timer element handles this now
    end
    -- Healing's Show (healing, healing and mana, mana only) is gone: it never showed
    -- anything useful, so a saved choice goes back to the healing
    ns.db.healText.valueMode = "amount"
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
    -- every feed, not just two of them: Damage Received and Actions used to keep their
    -- old look until the next reload
    if ns.RefreshAnchors then ns.RefreshAnchors() end
    if ns.RefreshEnemyText then ns.RefreshEnemyText() end
    if ns.RefreshHealText then ns.RefreshHealText() end
    if ns.RefreshDoneText then ns.RefreshDoneText() end
    if ns.RefreshTakenText then ns.RefreshTakenText() end
    if ns.RefreshActionsText then ns.RefreshActionsText() end
    if ns.RefreshTimer then ns.RefreshTimer() end
    if ns.RefreshOptions then ns.RefreshOptions() end
end
