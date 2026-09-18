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
-- Registration outcome per event, so "nothing is happening" can be told apart from
-- "the event never registered on this client". /gct debug reports it.
ns.registered = {}
function ns.On(event, fn)
    if not handlers[event] then
        if not pcall(dispatcher.RegisterEvent, dispatcher, event) then
            ns.registered[event] = false
            return
        end
        ns.registered[event] = true
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
-- Combat-log diagnostics (/gct debug)
--------------------------------------------------------------------------
-- Preview data is handed straight to the feeds, so when the preview draws and
-- real combat doesn't, the cause is always either "no event arrived" or "a filter
-- dropped it". These counters say which, on this client, rather than guessing.
local diag
function ns.DiagBump(bucket)
    if diag then diag[bucket] = (diag[bucket] or 0) + 1 end
end

function ns.DiagStart(seconds)
    seconds = seconds or 15
    diag = { seen = 0, mine = 0, routed = 0 }

    -- A private frame registering the event directly, as a control. If this counts
    -- events while the addon's dispatcher doesn't, the bug is ours; if neither
    -- counts, the client simply isn't delivering the event.
    local probe = CreateFrame("Frame")
    probe.count = 0
    pcall(probe.RegisterEvent, probe, "COMBAT_LOG_EVENT_UNFILTERED")
    probe:SetScript("OnEvent", function(self) self.count = self.count + 1 end)

    -- Sample combat state once a second, so "no events" can be told apart from
    -- "you weren't actually fighting during the window".
    local inCombat, ticks = 0, 0
    local sampler = C_Timer.NewTicker(1, function()
        ticks = ticks + 1
        if UnitAffectingCombat("player") then inCombat = inCombat + 1 end
    end)

    print("|cff66ccffGaru Combat Text|r: watching the combat log for " .. seconds
        .. "s -- |cffffd100start attacking now and keep attacking|r.")

    C_Timer.After(seconds, function()
        local d = diag
        diag = nil
        if sampler then sampler:Cancel() end
        probe:UnregisterAllEvents()

        local valid = "unknown"
        if C_EventUtils and C_EventUtils.IsEventValid then
            local ok, v = pcall(C_EventUtils.IsEventValid, "COMBAT_LOG_EVENT_UNFILTERED")
            if ok then valid = tostring(v) end
        end

        print("|cff66ccffGaru Combat Text|r: combat-log diagnostics")
        print("  CLEU registered: " .. tostring(ns.registered["COMBAT_LOG_EVENT_UNFILTERED"])
            .. "  |  IsEventValid: " .. valid)
        print("  you were in combat for " .. inCombat .. " of " .. ticks .. "s")
        print("  events: addon " .. d.seen .. "  |  private probe frame " .. probe.count)
        print("  passed the 'mine' filter: " .. d.mine .. "  |  routed to a feed: " .. d.routed)
        print("  C_DamageMeter API present: " .. tostring(C_DamageMeter ~= nil))

        if inCombat == 0 then
            print("  |cffffd100You weren't in combat during the window|r -- nothing to read. Re-run and attack.")
        elseif d.seen == 0 and probe.count == 0 then
            print("  |cffff5555The client delivered no combat-log events at all, to us or to a bare frame.|r")
            if C_DamageMeter then
                print("  C_DamageMeter exists, so this client replaces the addon combat log with that API.")
            end
        elseif d.seen == 0 then
            print("  |cffff5555Events reach a bare frame but not the addon|r -- our dispatcher is at fault.")
        elseif d.mine == 0 then
            print("  |cffff5555Events arrive but none count as mine|r -- the source filter is dropping them.")
        elseif d.routed == 0 then
            print("  |cffff5555Your events arrive but none route to a feed|r -- the target filter is dropping them.")
        else
            print("  |cff55ff55Events are reaching the feeds.|r")
        end
    end)
end

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
