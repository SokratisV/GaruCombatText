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
    ns.FinishSettings()
end

-- Settings read in (a login, an import): what has changed since they were saved.
function ns.FinishSettings()

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
    ns.FinishSettings()
    ns.RefreshAll()
end

-- Redraw everything from ns.db, as it now is: after a reset or an import. Every feed,
-- not just two of them: Damage Received and Actions used to keep their old look until
-- the next reload. Counting every enemy or one target: a change starts afresh.
function ns.RefreshAll()
    if ns.EnemyScopeChanged then ns.EnemyScopeChanged() end
    if ns.ActionsScopeChanged then ns.ActionsScopeChanged() end
    if ns.RefreshAnchors then ns.RefreshAnchors() end
    if ns.RefreshEnemyText then ns.RefreshEnemyText() end
    if ns.RefreshHealText then ns.RefreshHealText() end
    if ns.RefreshDoneText then ns.RefreshDoneText() end
    if ns.RefreshTakenText then ns.RefreshTakenText() end
    if ns.RefreshActionsText then ns.RefreshActionsText() end
    if ns.RefreshTimer then ns.RefreshTimer() end
    if ns.RefreshOptions then ns.RefreshOptions() end
end

--------------------------------------------------------------------------
-- Profiles: every setting as one string, to copy to another character or install
--------------------------------------------------------------------------
-- "GCT1:" then base64 of the settings written out in a small format of our own:
--   {key value key value ...}  strings as s<length>:<bytes>, numbers n<number>;,
--   booleans T or F, tables nested the same way.
-- Read back with a parser that accepts that and nothing else, never by running it
-- as code. Everything a player sets goes in: every feed's settings, where its anchor
-- sits (point, nudges, attach), the combat timer, the summary, the lock. Left out:
-- the fight recorder's lines, what is on your weapon (it changes as you play), and
-- which settings page was last open. On import every value is checked against the
-- defaults' types, anything unknown is dropped, anything missing comes from the
-- defaults, and the whole addon is redrawn from it at once.
ns.Profile = {}
local PROFILE_TAG = "GCT1:"
local LEAVE_OUT = { trace = true, weaponProcs = true }
local LEAVE_OUT_GENERAL = { optionsPage = true }

local function serialize(v, out)
    local t = type(v)
    if t == "string" then out[#out + 1] = "s" .. #v .. ":" .. v
    elseif t == "number" then out[#out + 1] = "n" .. string.format("%.17g", v) .. ";"
    elseif t == "boolean" then out[#out + 1] = v and "T" or "F"
    elseif t == "table" then
        out[#out + 1] = "{"
        local keys = {}
        for k in pairs(v) do
            if type(k) == "string" or type(k) == "number" then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        for _, k in ipairs(keys) do
            local x = v[k]
            local tx = type(x)
            if tx == "string" or tx == "number" or tx == "boolean" or tx == "table" then
                serialize(k, out); serialize(x, out)
            end
        end
        out[#out + 1] = "}"
    end
end

local function parse(s)
    local i, depth = 1, 0
    local value
    local function fail(why) error({ why = why }, 0) end
    value = function()
        local c = s:sub(i, i)
        if c == "s" then
            local len, colon = s:match("^(%d+)():", i + 1)
            if not len then fail("bad text") end
            len = tonumber(len)
            local from = colon + 1
            local str = s:sub(from, from + len - 1)
            if #str ~= len then fail("cut short") end
            i = from + len
            return str
        elseif c == "n" then
            local num, after = s:match("^([%-%d%.eE+]+);()", i + 1)
            local n = num and tonumber(num)
            if not n or n ~= n or n == math.huge or n == -math.huge then fail("bad number") end
            i = after
            return n
        elseif c == "T" or c == "F" then
            i = i + 1
            return c == "T"
        elseif c == "{" then
            depth = depth + 1
            if depth > 8 then fail("nested too deep") end
            i = i + 1
            local t = {}
            while s:sub(i, i) ~= "}" do
                if i > #s then fail("cut short") end
                local k = value()
                if type(k) ~= "string" and type(k) ~= "number" then fail("bad key") end
                t[k] = value()
            end
            i = i + 1
            depth = depth - 1
            return t
        end
        fail(c == "" and "cut short" or "unexpected character")
    end
    local ok, res = pcall(value)
    if not ok then return nil, type(res) == "table" and res.why or tostring(res) end
    if i <= #s then return nil, "extra text after the settings" end
    return res
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for n = 1, 64 do B64_INDEX[B64:sub(n, n)] = n - 1 end

local function b64encode(s)
    local out = {}
    for n = 1, #s, 3 do
        local a, b, c = s:byte(n, n + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local d1, d2 = math.floor(v / 262144) % 64, math.floor(v / 4096) % 64
        local d3, d4 = math.floor(v / 64) % 64, v % 64
        out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
            .. (b and B64:sub(d3 + 1, d3 + 1) or "=") .. (c and B64:sub(d4 + 1, d4 + 1) or "=")
    end
    return table.concat(out)
end

local function b64decode(s)
    s = s:gsub("%s", "")
    if #s == 0 or #s % 4 ~= 0 or s:find("[^%w%+/=]") then return nil end
    local out = {}
    for n = 1, #s, 4 do
        local chunk = s:sub(n, n + 3)
        local pad = select(2, chunk:gsub("=", ""))
        if pad > 2 or (pad > 0 and n + 3 < #s) or chunk:sub(1, 4 - pad):find("=") then return nil end
        local v = 0
        for k = 1, 4 do
            local ch = chunk:sub(k, k)
            v = v * 64 + (ch == "=" and 0 or B64_INDEX[ch])
        end
        local bytes = string.char(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
        out[#out + 1] = bytes:sub(1, 3 - pad)
    end
    return table.concat(out)
end

-- What may be kept from an imported table: only the keys the defaults have, each of
-- the same type; a list in the defaults (a point, a colour) must hold the same kinds.
local function keepValid(src, def)
    local out = {}
    for k, d in pairs(def) do
        local v = src[k]
        if type(d) == "table" and type(v) == "table" then
            if d[1] ~= nil then                       -- a list: { "CENTER", x, y }, { r, g, b }
                local okList = true
                for n = 1, #d do if type(v[n]) ~= type(d[n]) then okList = false end end
                if okList then
                    local copy = {}
                    for n = 1, #d do copy[n] = v[n] end
                    out[k] = copy
                end
            else
                out[k] = keepValid(v, d)
            end
        elseif v ~= nil and type(v) == type(d) then
            out[k] = v
        end
    end
    return out
end

function ns.Profile.Export()
    local copy = {}
    for k, v in pairs(ns.db) do
        if not LEAVE_OUT[k] then copy[k] = v end
    end
    if type(copy.general) == "table" then
        local g = {}
        for k, v in pairs(copy.general) do if not LEAVE_OUT_GENERAL[k] then g[k] = v end end
        copy.general = g
    end
    return ns.Profile.Encode({ addon = ADDON, version = 1, settings = copy })
end

-- A table as a profile string (Export's last step; the tests build bad ones with it).
function ns.Profile.Encode(t)
    local out = {}
    serialize(t, out)
    return PROFILE_TAG .. b64encode(table.concat(out))
end

-- Read a profile string: the settings to apply, or nil and why not.
function ns.Profile.Read(text)
    if type(text) ~= "string" then return nil, "Nothing to import." end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "Paste a profile string first." end
    if text:sub(1, #PROFILE_TAG) ~= PROFILE_TAG then
        return nil, "That is not a Garu Combat Text profile: it should start with " .. PROFILE_TAG
    end
    if #text > 200000 then return nil, "That string is far too long to be a profile." end
    local raw = b64decode(text:sub(#PROFILE_TAG + 1))
    if not raw then return nil, "The profile string is damaged and did not decode. Copy it again, whole." end
    local data, why = parse(raw)
    if not data then return nil, "The profile string is damaged (" .. tostring(why) .. "). Copy it again, whole." end
    if type(data) ~= "table" or data.addon ~= ADDON or type(data.settings) ~= "table" then
        return nil, "That string is not a Garu Combat Text profile."
    end
    if type(data.version) ~= "number" or data.version > 1 then
        return nil, "That profile was made by a newer version of Garu Combat Text. Update the addon first."
    end
    return keepValid(data.settings, ns.defaults)
end

-- Apply a profile string: true, or false and why not. A string that is no good
-- changes nothing.
function ns.Profile.Import(text)
    local settings, why = ns.Profile.Read(text)
    if not settings then return false, why end
    local old = ns.db or {}
    local page = old.general and old.general.optionsPage
    GaruCombatTextDB = copyDefaults(ns.defaults, settings)
    ns.db = GaruCombatTextDB
    ns.db.trace, ns.db.weaponProcs = old.trace, old.weaponProcs
    ns.db.general.optionsPage = page
    ns.FinishSettings()
    ns.RefreshAll()
    return true
end
