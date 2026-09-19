local ADDON, ns = ...

-- Midnight (and so WoW Forever) removed the addon combat log: COMBAT_LOG_EVENT_UNFILTERED
-- is a valid event that never fires. What replaces it is C_DamageMeter, which hands
-- over per-fight AGGREGATES rather than individual hits.
--
-- The feeds are built on ns.Meter, whose whole vocabulary is "here is another N of
-- damage on this line" -- increments. So rather than rewrite Meter around absolute
-- totals, this module turns the aggregates back into increments: it remembers the
-- last total it saw per spell and feeds the difference. Every behaviour the engine
-- already has -- rolling windows, fades, sorting, the radial and stack layouts --
-- keeps working untouched, and the feeds look the same as they did on a client with
-- a combat log.
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
-- windows, hold timers, fades. A summary should simply stay put until the next
-- fight replaces it.
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

-- Fills `out` with [key] = {id, amount} for the local player's spells in this meter.
local function readSpells(meterType, out)
    wipe(out)
    local src, session = localSource(meterType)
    if not src then return out, session end

    local ok, detail = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
        SessionType.Current, meterType, src.sourceGUID, src.sourceCreatureID)
    if not ok or type(detail) ~= "table" then return out, session end

    local spells = detail.combatSpells
    if type(spells) ~= "table" then return out, session end

    for i = 1, #spells do
        local sp = spells[i]
        if type(sp) == "table" then
            local id, amt = sp.spellID, sp.totalAmount
            if not ns.IsSecret(id) and not ns.IsSecret(amt) and type(amt) == "number" then
                out["spell:" .. tostring(id or 0)] = { id = id, amount = amt }
            end
        end
    end
    return out, session
end

--------------------------------------------------------------------------
-- Turning totals back into increments
--------------------------------------------------------------------------
-- A feed keeps one of these. It holds the last totals seen, so the next poll can
-- work out what actually happened since.
function DM.NewState()
    return { last = {}, spells = {}, sessionTotal = -1, rebase = false }
end

-- Shared tail of both pumps: diff `totals` against what we saw last time and push
-- the growth into the meter.
local function feedDeltas(state, totals, meter, frame, session)
    -- A new fight restarts the session's totals. Anything below the last figure we
    -- saw means the counters went backwards, so forget them rather than emit a
    -- huge delta on the next tick.
    local total = type(session) == "table" and session.totalAmount or nil
    if ns.IsSecret(total) or type(total) ~= "number" then total = nil end
    if total and total < state.sessionTotal then wipe(state.last) end
    state.sessionTotal = total or -1

    -- Adopting the current figures without emitting them: used on a target change,
    -- so the new target's feed starts from now instead of inheriting the totals
    -- built up against the previous one.
    if state.rebase then
        state.rebase = false
        wipe(state.last)
        for key, sp in pairs(totals) do state.last[key] = sp.amount end
        return false
    end

    local added = false
    for key, sp in pairs(totals) do
        local prev = state.last[key] or 0
        local delta = sp.amount - prev
        state.last[key] = sp.amount
        if delta > 0 then
            -- This API carries no school and no crit flag, hence nil/false.
            meter:Bump(frame, key, spellLabel(sp.id), delta, nil, false, ns.SpellTexture(sp.id))
            added = true
        end
    end
    return added
end

-- Poll one meter's rows for the local player and push the difference.
function DM.Pump(state, meterType, meter, frame)
    if not DM.available or not meterType or not frame then return false end
    local totals, session = readSpells(meterType, state.spells)
    return feedDeltas(state, totals, meter, frame, session)
end

-- Incoming version, for healing received. HealingDone is keyed by the HEALER, so
-- "what landed on me" means walking every source and keeping the spell rows whose
-- other party is me. Whether the client fills combatSpellDetails.unitName in at all
-- decides whether this works: when it is blank nothing matches and the feed stays
-- empty, which is the right failure -- far better than showing somebody else's
-- healing as though it were yours.
function DM.PumpIncoming(state, meterType, meter, frame, unitName)
    if not DM.available or not meterType or not frame or not unitName then return false end

    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, SessionType.Current, meterType)
    if not ok or type(session) ~= "table" then return false end
    local sources = session.combatSources
    if type(sources) ~= "table" then return false end

    local totals = state.spells
    wipe(totals)
    for i = 1, #sources do
        local s = sources[i]
        if type(s) == "table" then
            local ok2, detail = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
                SessionType.Current, meterType, s.sourceGUID, s.sourceCreatureID)
            local spells = ok2 and type(detail) == "table" and detail.combatSpells
            if type(spells) == "table" then
                for j = 1, #spells do
                    local sp = spells[j]
                    if type(sp) == "table" then
                        local d = sp.combatSpellDetails
                        local who = type(d) == "table" and d.unitName or nil
                        local amt = sp.totalAmount
                        if (not ns.IsSecret(who)) and who == unitName
                            and (not ns.IsSecret(amt)) and type(amt) == "number" then
                            -- Several healers can feed the same spell line; sum them.
                            local key = "spell:" .. tostring(sp.spellID or 0)
                            local cur = totals[key]
                            totals[key] = { id = sp.spellID,
                                            amount = (cur and cur.amount or 0) + amt }
                        end
                    end
                end
            end
        end
    end
    return feedDeltas(state, totals, meter, frame, session)
end

-- Re-baseline rather than forget. Wiping the remembered totals looks harmless but
-- isn't: the next poll would read the session's running total against a baseline of
-- zero and feed the whole fight in as one delta. Instead, mark the state so the
-- next poll adopts the current totals silently and starts counting from there.
function DM.Reset(state)
    state.rebase = true
end

--------------------------------------------------------------------------
-- Update driver
--------------------------------------------------------------------------
-- The meter fires its own update events; a slow ticker behind them covers the gap
-- between the last event and a fight ending, and costs nothing when idle.
local pumps, clears = {}, {}
function DM.Register(fn)
    pumps[#pumps + 1] = fn
end

-- A feed's "start a new fight" hook: wipe what's on screen and re-baseline.
function DM.RegisterClear(fn)
    clears[#clears + 1] = fn
end

if DM.available then
    local function runAll()
        for i = 1, #pumps do pumps[i]() end
    end
    ns.On("DAMAGE_METER_CURRENT_SESSION_UPDATED", runAll)
    ns.On("DAMAGE_METER_COMBAT_SESSION_UPDATED", runAll)
    ns.On("DAMAGE_METER_RESET", runAll)

    local ticker, since = CreateFrame("Frame"), 0
    ticker:SetScript("OnUpdate", function(_, dt)
        since = since + dt
        if since < 0.25 then return end
        since = 0
        runAll()
    end)

    -- This client withholds the meter's numbers for the duration of a fight and
    -- only lets them be read once it ends, so the feeds can only ever be a summary
    -- of the fight just finished. Clear at the start of one so each fight shows its
    -- own figures instead of accumulating, and poll a few times after it ends
    -- because the session isn't finalised the instant combat drops.
    ns.On("PLAYER_REGEN_DISABLED", function()
        for i = 1, #clears do clears[i]() end
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        for _, delay in ipairs({ 0.2, 0.8, 1.6, 3.0 }) do
            C_Timer.After(delay, runAll)
        end
    end)
end
