local ADDON, ns = ...

-- Midnight (and so WoW Forever) removed the addon combat log: COMBAT_LOG_EVENT_UNFILTERED
-- is a valid event that never fires. What replaces it is C_DamageMeter, which hands
-- over per-fight AGGREGATES rather than individual hits.
--
-- This module reads a finished fight out of that API and paints it into the feeds,
-- and it owns when they appear: a summary is shown against the target it describes,
-- for a window that starts when you first look at it. Sorting and the radial and
-- stack layouts are the engine's as before; the live-feed machinery around them
-- (rolling windows, per-row fades) is not used here.
--
-- What is genuinely lost, because the API carries no field for it: per-hit crits,
-- spell schools, mana spent, and miss/dodge/parry counts (the Actions feed).

ns.DM = {}
local DM = ns.DM

local SessionType = Enum and Enum.DamageMeterSessionType
local MeterType   = Enum and Enum.DamageMeterType

DM.available = (C_DamageMeter ~= nil)
    and C_DamageMeter.GetCombatSessionFromType ~= nil
    and C_DamageMeter.GetCombatSessionSourceFromType ~= nil
    and SessionType ~= nil and SessionType.Current ~= nil
    and MeterType ~= nil

-- C_DamageMeter existing is also the signal that the combat log is gone, so the
-- feeds use it to decide which way to get their data.
ns.UseDamageMeter = DM.available and true or false

-- ...and, because this client withholds the meter's numbers for the duration of a
-- fight and only releases them once it ends, the same flag means the feeds can only
-- be a SUMMARY of the fight just finished. Measured: out of combat the totals read
-- normally; from the first moment of combat every one of them is unreadable, and
-- stays that way until combat drops. No polling interval or event changes that.
--
-- Summary mode therefore turns off the whole live-feed apparatus -- rolling
-- windows, hold timers, per-row fades -- and replaces it with the presentation
-- rules further down: shown against a dead target once the fight is over, held for
-- ns.db.summary.holdSecs, recallable by re-selecting that target until it lapses.
ns.SummaryMode = ns.UseDamageMeter

DM.TYPES = MeterType and {
    damage  = MeterType.DamageDone,
    taken   = MeterType.DamageTaken,
    healing = MeterType.HealingDone,
} or {}

--------------------------------------------------------------------------
-- Reading a session
--------------------------------------------------------------------------
-- The player's own row in a meter's current session. isLocalPlayer is what marks
-- it -- no GUID comparison needed, which is just as well given how fragile those
-- turned out to be here.
local function localSource(meterType)
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, SessionType.Current, meterType)
    if not ok or type(session) ~= "table" then return nil, nil end
    local sources = session.combatSources
    if type(sources) ~= "table" then return nil, session end
    for i = 1, #sources do
        local s = sources[i]
        if type(s) == "table" and ns.Truth(s.isLocalPlayer) == true then
            return s, session
        end
    end
    return nil, session
end

-- How long the fight being summarised lasted, or nil. Used in place of the live
-- combat clock, which counted from the first hit we saw -- and in summary mode we
-- see no hits at all, only the total afterwards.
function DM.SessionSeconds()
    if not DM.available or not C_DamageMeter.GetSessionDurationSeconds then return nil end
    local ok, secs = pcall(C_DamageMeter.GetSessionDurationSeconds, SessionType.Current)
    if not ok or ns.IsSecret(secs) or type(secs) ~= "number" or secs <= 0 then return nil end
    return secs
end

-- The meter can be switched off or unavailable; nothing works if it is, and saying
-- so beats drawing empty feeds forever.
function DM.IsUsable()
    if not DM.available then return false end
    if C_DamageMeter.IsDamageMeterAvailable then
        local ok, v = pcall(C_DamageMeter.IsDamageMeterAvailable)
        if ok and type(v) == "boolean" then return v end
    end
    return true
end

function ns.PrintStatus()
    print("|cff66ccffGaru Combat Text|r: reading from "
        .. (ns.UseDamageMeter and "C_DamageMeter (post-fight summaries)" or "the combat log (live)"))
    if ns.UseDamageMeter then
        print("   meter available: " .. tostring(DM.IsUsable())
            .. "  |  last fight: " .. (DM.SessionSeconds() and (math.floor(DM.SessionSeconds()) .. "s") or "none"))
        print("   This client hides damage numbers during a fight, so the feeds fill in")
        print("   once it ends. Actions (dodge/parry/miss) has no data source at all here.")
        local s = ns.db and ns.db.summary
        print("   summary: " .. (DM.Shown() and "on screen now" or "waiting for a target")
            .. "  |  holds for " .. tostring(s and s.holdSecs or 15) .. "s"
            .. ((s and s.requireDead ~= false) and " once you select something that died"
                                               or " once you select anything"))
    end
end

local labelCache = {}
local function spellLabel(spellID)
    if not spellID or spellID == 0 then return "Melee" end
    local cached = labelCache[spellID]
    if cached then return cached end
    local name = ns.SpellName(spellID) or ("Spell " .. spellID)
    labelCache[spellID] = name
    return name
end

--------------------------------------------------------------------------
-- Capturing a finished fight
--------------------------------------------------------------------------
-- Nothing here diffs successive polls any more. On this client no number is
-- readable until the fight is over, at which point SessionType.Current holds that
-- fight's totals complete -- so a capture is simply "read the rows and keep them".
--
-- Current is per-fight rather than a running tally: the API exposes a separate
-- Overall session for that, and probing out of combat read Current 147 against
-- Overall 501. Current is the fight that just ended; Overall is everything.

-- Accumulate spell rows into `into` as [key] = { id, label, amount, icon }.
-- `filter` (optional) decides which rows belong to us.
local function rowsFrom(spells, into, filter)
    for i = 1, #spells do
        local sp = spells[i]
        if type(sp) == "table" then
            local id, amt = sp.spellID, sp.totalAmount
            if (not ns.IsSecret(id)) and (not ns.IsSecret(amt))
                and type(amt) == "number" and amt > 0
                and ((not filter) or filter(sp)) then
                local key = "spell:" .. tostring(id or 0)
                local r = into[key]
                if r then
                    r.amount = r.amount + amt
                else
                    into[key] = { id = id, label = spellLabel(id),
                                  amount = amt, icon = ns.SpellTexture(id) }
                end
            end
        end
    end
end

local function spellsOf(meterType, guid, creatureID)
    local ok, detail = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
        SessionType.Current, meterType, guid, creatureID)
    if not ok or type(detail) ~= "table" then return nil end
    local spells = detail.combatSpells
    return type(spells) == "table" and spells or nil
end

-- The player's own rows for one meter, for the fight just finished.
function DM.CaptureOutgoing(meterType)
    if not DM.available or not meterType then return nil end
    local src = localSource(meterType)
    if not src then return nil end
    local spells = spellsOf(meterType, src.sourceGUID, src.sourceCreatureID)
    if not spells then return nil end
    local rows = {}
    rowsFrom(spells, rows)
    return next(rows) and rows or nil
end

-- Incoming version, for healing received. HealingDone is keyed by the HEALER, so
-- "what landed on me" means walking every source and keeping the spell rows whose
-- other party is me. Whether the client fills combatSpellDetails.unitName in at all
-- decides whether this works: when it is blank nothing matches and the feed stays
-- empty, which is the right failure -- far better than showing somebody else's
-- healing as though it were yours.
function DM.CaptureIncoming(meterType, unitName)
    if not DM.available or not meterType or not unitName then return nil end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, SessionType.Current, meterType)
    if not ok or type(session) ~= "table" then return nil end
    local sources = session.combatSources
    if type(sources) ~= "table" then return nil end

    local function mine(sp)
        local d = sp.combatSpellDetails
        local who = type(d) == "table" and d.unitName or nil
        return (not ns.IsSecret(who)) and who == unitName
    end

    local rows = {}
    for i = 1, #sources do
        local s = sources[i]
        if type(s) == "table" then
            local spells = spellsOf(meterType, s.sourceGUID, s.sourceCreatureID)
            if spells then rowsFrom(spells, rows, mine) end
        end
    end
    return next(rows) and rows or nil
end

-- Per-enemy breakdown of the damage dealt, when this client offers one.
-- EnemyDamageTaken is a meter whose *sources* are the enemies, so each source is one
-- mob and its spell rows are what landed on it -- exactly the split the summary
-- wants, keyed by GUID so there is no name matching to get wrong.
--
-- Unverified against a live fight. If the session comes back in a shape this does
-- not recognise it returns nothing, and every corpse then shows the fight's totals
-- instead: the behaviour we already had, not a broken one.
function DM.CaptureByTarget()
    local mt = MeterType and MeterType.EnemyDamageTaken
    if not DM.available or not mt then return nil end
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, SessionType.Current, mt)
    if not ok or type(session) ~= "table" then return nil end
    local sources = session.combatSources
    if type(sources) ~= "table" then return nil end

    local out, any = {}, false
    for i = 1, #sources do
        local s = sources[i]
        local guid = type(s) == "table" and s.sourceGUID or nil
        if type(guid) == "string" and not ns.IsSecret(guid) then
            local spells = spellsOf(mt, guid, s.sourceCreatureID)
            if spells then
                local rows = {}
                rowsFrom(spells, rows)
                if next(rows) then out[guid], any = rows, true end
            end
        end
    end
    return any and out or nil
end

--------------------------------------------------------------------------
-- Post-fight presentation
--------------------------------------------------------------------------
-- A summary is not live combat text, so it does not behave like it. Nothing appears
-- the moment combat drops: it appears when you select what you were fighting, holds
-- for a configurable window, and can be brought back by re-selecting that target
-- until the window runs out. Each target gets its own window, started the first time
-- its summary is shown, so flicking between two corpses shows each one's figures.

local feeds = {}

-- A feed registers what it can do rather than when to do it: `capture` reads its
-- rows out of a finished session, `frame` says where they are drawn, `enabled` says
-- whether the user wants them at all.
function DM.RegisterFeed(def)
    feeds[#feeds + 1] = def
end

local inCombat = false
local shownGUID = nil
local expiry = {}          -- [targetGUID] = GetTime() when its window closes

local function conf(key, fallback)
    local s = ns.db and ns.db.summary
    local v = s and s[key]
    if v == nil then return fallback end
    return v
end

local function hideAll()
    for i = 1, #feeds do
        feeds[i].meter:SetExpiry(nil)
        feeds[i].meter:Forget()
    end
    shownGUID = nil
end

-- Draws the summary for one target, and says whether there was anything to draw --
-- a corpse you never fought has no rows against it, and should cost neither a
-- window nor an empty feed.
local function paint(guid)
    local drew = false
    for i = 1, #feeds do
        local f = feeds[i]
        f.meter:Forget()
        local rows = (f.targets and f.targets[guid]) or f.rows
        local frame = (rows and f.enabled()) and f.frame() or nil
        if frame then
            drew = true
            -- The API carries no school and no crit flag, hence nil/false. Each row
            -- is painted with a single Bump into a stream we just emptied, so the
            -- tracker's running total lands on the fight's figure exactly.
            for key, r in pairs(rows) do
                f.meter:Bump(frame, key, r.label, r.amount, nil, false, r.icon)
            end
        end
    end
    return drew
end

-- Only something dead, and only once you have stopped fighting: these numbers
-- describe a finished fight, and hanging them off a live mob you are about to pull
-- reads as though they were that mob's.
local function qualifies()
    if inCombat then return false end
    if conf("requireDead", true) then
        local dead = ns.Truth(UnitIsDead("target"))
        -- nil means the client will not tell us. Show it anyway: a summary you can
        -- never reach is worse than one that occasionally appears on a live target.
        if dead == false then return false end
    end
    return true
end

function DM.Shown()
    return shownGUID ~= nil
end

function DM.UpdateDisplay()
    local guid = UnitGUID("target")
    if type(guid) ~= "string" or ns.IsSecret(guid) or not qualifies() then
        if shownGUID then hideAll() end
        return
    end
    if guid == shownGUID then return end

    local now = GetTime()
    local ends = expiry[guid]
    if ends and now >= ends then      -- this one's window has already run out
        if shownGUID then hideAll() end
        return
    end
    -- Draw before committing to a window, so a target with nothing recorded against
    -- it neither starts a clock nor leaves an empty feed hanging off it.
    if not paint(guid) then
        if shownGUID then hideAll() end
        return
    end
    if not ends then                  -- first time it is shown: the clock starts here
        ends = now + math.max(1, conf("holdSecs", 15))
        expiry[guid] = ends
    end

    local fade = math.max(0, conf("fadeTime", 0.6))
    for i = 1, #feeds do feeds[i].meter:SetExpiry(ends, fade) end
    shownGUID = guid
end

--------------------------------------------------------------------------
-- Update driver
--------------------------------------------------------------------------
if DM.available then
    local settleUntil = 0

    local function captureAll()
        local me = UnitName("player")
        for i = 1, #feeds do
            local f = feeds[i]
            local rows = f.capture(me)
            if rows then f.rows = rows end
            if f.byTarget then
                local t = DM.CaptureByTarget()
                if t then f.targets = t end
            end
        end
    end

    -- Reading is pointless mid-fight (every total is secret) and the display is
    -- suppressed then anyway, so a poll only means anything once combat has dropped.
    local function poll()
        if inCombat then return end
        captureAll()
        DM.UpdateDisplay()
    end

    ns.On("DAMAGE_METER_CURRENT_SESSION_UPDATED", poll)
    ns.On("DAMAGE_METER_COMBAT_SESSION_UPDATED", poll)
    ns.On("DAMAGE_METER_RESET", poll)
    ns.On("PLAYER_TARGET_CHANGED", DM.UpdateDisplay)

    -- Two jobs on one frame: sweep the few seconds after a fight while its session
    -- finalises, and retire a summary once its window closes. Both are cheap, and
    -- outside those moments this does nothing at all.
    local ticker, since = CreateFrame("Frame"), 0
    ticker:SetScript("OnUpdate", function(_, dt)
        if shownGUID then
            local ends = expiry[shownGUID]
            if ends and GetTime() >= ends then hideAll() end
        end
        if GetTime() > settleUntil then return end
        since = since + dt
        if since < 0.25 then return end
        since = 0
        poll()
    end)

    ns.On("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        -- A new fight invalidates the last one outright: its rows, its per-target
        -- split and every window still open against it.
        for i = 1, #feeds do feeds[i].rows, feeds[i].targets = nil, nil end
        wipe(expiry)
        hideAll()
    end)

    ns.On("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        -- The session is not finalised the instant combat drops, so let the ticker
        -- sweep the next few seconds rather than polling once and hoping.
        settleUntil = GetTime() + 4
    end)
end

--------------------------------------------------------------------------
-- /gct probe
--------------------------------------------------------------------------
-- Two things in this port are reasoned about rather than measured: whether
-- EnemyDamageTaken really gives a per-enemy split (the summary uses it to show one
-- corpse's figures rather than the fight's), and whether spell rows name their other
-- party at all (healing received depends on it entirely). Both are answerable from
-- one real fight. Kill something, then run this out of combat.
local function show(v)
    if ns.IsSecret(v) then return "<secret>" end
    if v == nil then return "nil" end
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

function ns.PrintProbe()
    if not DM.available then
        print("|cff66ccffGCT probe|r: C_DamageMeter is not present on this client.")
        return
    end

    for _, name in ipairs({ "DamageDone", "EnemyDamageTaken", "HealingDone" }) do
        local mt = MeterType and MeterType[name]
        if mt == nil then
            print("|cff66ccffGCT probe|r " .. name .. ": this client has no such meter type")
        else
            local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, SessionType.Current, mt)
            if not ok or type(session) ~= "table" then
                print("|cff66ccffGCT probe|r " .. name .. ": no session")
            else
                local sources = type(session.combatSources) == "table" and session.combatSources or {}
                print(("|cff66ccffGCT probe|r %s: total=%s dur=%s sources=%d"):format(
                    name, show(session.totalAmount), show(session.durationSeconds), #sources))
                for i = 1, math.min(#sources, 4) do
                    local s = sources[i]
                    if type(s) == "table" then
                        print(("   src[%d] isLocalPlayer=%s guid=%s creatureID=%s"):format(
                            i, show(s.isLocalPlayer), show(s.sourceGUID), show(s.sourceCreatureID)))
                        local spells = spellsOf(mt, s.sourceGUID, s.sourceCreatureID)
                        local n = spells and #spells or 0
                        for j = 1, math.min(n, 4) do
                            local sp = spells[j]
                            local d = type(sp) == "table" and sp.combatSpellDetails or nil
                            print(("      spell=%s amount=%s unitName=%s isMob=%s isPet=%s"):format(
                                show(sp.spellID), show(sp.totalAmount),
                                type(d) == "table" and show(d.unitName) or "-",
                                type(d) == "table" and show(d.isMob) or "-",
                                type(d) == "table" and show(d.isPet) or "-"))
                        end
                        if n > 4 then print(("      ... and %d more spell rows"):format(n - 4)) end
                    end
                end
            end
        end
    end

    print(("   player=%s  target=%s dead=%s"):format(
        show(UnitName("player")), show(UnitGUID("target")), show(UnitIsDead("target"))))
    print(("   captured: %s"):format(DM.CaptureByTarget() and
        "EnemyDamageTaken gave a per-target split" or "no per-target split -- corpses share the fight total"))
end
