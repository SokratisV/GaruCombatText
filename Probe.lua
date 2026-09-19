local ADDON, ns = ...

-- Temporary reconnaissance, not part of the addon's job.
--
-- Midnight removed the addon combat log and replaced it with C_DamageMeter, so the
-- feeds have to be rebuilt on that API. What the API looks like on WoW Forever is
-- the thing the rewrite must be designed against, and reading a retail addon's use
-- of it is a guess about a different client. /gct probe dumps the real shape.
--
-- Delete this file, its TOC line and the /gct probe branch once the feeds are ported.

local MAX_FIELDS = 26

-- A secret's type is its underlying type, so the secret test has to come first:
-- taking #v or tostring(v) on one inspects it, which throws.
local function safe(v)
    if ns.IsSecret(v) then return "|cffff8800<secret>|r" end
    local t = type(v)
    if t == "table" then
        local n = #v
        return "<table" .. (n > 0 and (", " .. n .. " entries") or "") .. ">"
    end
    if t == "string" then
        if #v > 44 then return '"' .. v:sub(1, 44) .. '..."' end
        return '"' .. v .. '"'
    end
    return tostring(v)
end

-- Named fields of one table, sorted so two runs can be diffed by eye.
local function dump(label, t, indent)
    indent = indent or "   "
    if type(t) ~= "table" then
        print(indent .. label .. " = " .. safe(t))
        return
    end
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" then keys[#keys + 1] = k end
    end
    table.sort(keys)
    print(indent .. "|cffffd100" .. label .. "|r  (" .. #keys .. " named, " .. #t .. " array)")
    for i, k in ipairs(keys) do
        if i > MAX_FIELDS then print(indent .. "   ...") break end
        print(indent .. "   ." .. k .. " = " .. safe(t[k]))
    end
end

local function dumpEnum(name, e)
    if type(e) ~= "table" then print("   " .. name .. ": |cffff5555missing|r") return end
    local parts = {}
    for k, v in pairs(e) do parts[#parts + 1] = k .. "=" .. tostring(v) end
    table.sort(parts)
    print("   " .. name .. ": " .. table.concat(parts, ", "))
end

local METER_ALIASES = {
    damage  = "DamageDone",
    healing = "HealingDone",
    taken   = "DamageTaken",
    enemy   = "EnemyDamageTaken",
}

function ns.RunProbe(which)
    if not C_DamageMeter then
        print("|cff66ccffGaru Combat Text|r: C_DamageMeter is not present on this client.")
        return
    end
    print("|cff66ccffGaru Combat Text|r: C_DamageMeter probe")

    -- The API survey alone fills the chat frame, so naming a meter type skips it
    -- and prints only the data dump. Lets the second half be read without scrolling.
    if which == "live" then return ns.ProbeLive(12) end
    if which and which ~= "" then return ns.ProbeMeter(which) end

    local fns = {}
    for k, v in pairs(C_DamageMeter) do
        if type(v) == "function" then fns[#fns + 1] = k end
    end
    table.sort(fns)
    print("   functions: " .. table.concat(fns, ", "))
    dumpEnum("DamageMeterType", Enum and Enum.DamageMeterType)
    dumpEnum("DamageMeterSessionType", Enum and Enum.DamageMeterSessionType)

    -- Which update events this client actually has, since the feeds need something
    -- to refresh on.
    if C_EventUtils and C_EventUtils.IsEventValid then
        local evts = {}
        for _, e in ipairs({ "DAMAGE_METER_CURRENT_SESSION_UPDATED",
                             "DAMAGE_METER_COMBAT_SESSION_UPDATED",
                             "DAMAGE_METER_RESET" }) do
            local ok, v = pcall(C_EventUtils.IsEventValid, e)
            evts[#evts + 1] = e .. "=" .. tostring(ok and v)
        end
        print("   events: " .. table.concat(evts, "  "))
    end

    if C_DamageMeter.GetAvailableCombatSessions then
        local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
        if ok and type(sessions) == "table" then
            print("   available sessions: " .. #sessions)
            if sessions[1] then pcall(dump, "sessions[1]", sessions[1]) end
        else
            print("   GetAvailableCombatSessions: " .. tostring(ok and sessions))
        end
    end

    return ns.ProbeMeter(which)
end

-- "It only shows when combat ends" means the question is whether these totals move
-- DURING a fight or only get finalised at the end of one. That decides whether live
-- combat text is possible on this client at all, so sample them once a second and
-- print the series.
function ns.ProbeLive(seconds)
    seconds = seconds or 12
    if not C_DamageMeter or not Enum or not Enum.DamageMeterSessionType then
        print("|cff66ccffGaru Combat Text|r: no C_DamageMeter to sample.")
        return
    end
    local ST, MT = Enum.DamageMeterSessionType, Enum.DamageMeterType
    local rows, ticks = {}, 0

    local function total(sessionType)
        local ok, s = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, MT.DamageDone)
        if not ok or type(s) ~= "table" then return "-" end
        local t = s.totalAmount
        if ns.IsSecret(t) or type(t) ~= "number" then return "?" end
        return tostring(t)
    end

    print("|cff66ccffGaru Combat Text|r: sampling DamageDone for " .. seconds
        .. "s -- |cffffd100attack now and keep attacking|r.")
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        ticks = ticks + 1
        rows[#rows + 1] = ("%ds %s cur=%s ovr=%s"):format(
            ticks,
            UnitAffectingCombat("player") and "|cffff5555FIGHT|r" or "idle",
            total(ST.Current), total(ST.Overall))
        if ticks >= seconds then
            ticker:Cancel()
            print("|cff66ccffGaru Combat Text|r: live sample (cur = Current session, ovr = Overall)")
            for _, r in ipairs(rows) do print("   " .. r) end
            print("   If cur/ovr only move once the fight ends, live combat text isn't")
            print("   possible from this API and the feeds are post-fight summaries.")
        end
    end)
end

function ns.ProbeMeter(which)
    local typeName = METER_ALIASES[(which or ""):lower()] or "DamageDone"
    local meterType = Enum and Enum.DamageMeterType and Enum.DamageMeterType[typeName]
    local sessionType = Enum and Enum.DamageMeterSessionType
        and Enum.DamageMeterSessionType.Current
    if meterType == nil or sessionType == nil then
        print("   |cffff5555Missing Enum.DamageMeterType." .. typeName
            .. " or Enum.DamageMeterSessionType.Current|r")
        return
    end
    print("   |cff55ff55--- " .. typeName .. ", Current session ---|r")

    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
    if not ok or type(session) ~= "table" then
        print("   no session returned (" .. tostring(ok and session) .. ")")
        return
    end
    pcall(dump, "session", session)

    local sources = session.combatSources
    if type(sources) ~= "table" or #sources == 0 then
        print("   |cffffd100No combatSources -- kill something, then run this again.|r")
        return
    end
    print("   combatSources: " .. #sources)
    pcall(dump, "combatSources[1]", sources[1])

    if not C_DamageMeter.GetCombatSessionSourceFromType then return end
    local first = sources[1]
    local ok2, src = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
        sessionType, meterType, first.sourceGUID, first.sourceCreatureID)
    if not ok2 or type(src) ~= "table" then
        print("   source detail unavailable (" .. tostring(ok2 and src) .. ")")
        return
    end
    pcall(dump, "source detail", src)

    local spells = src.combatSpells
    if type(spells) ~= "table" or #spells == 0 then
        print("   no combatSpells on that source")
        return
    end
    print("   combatSpells: " .. #spells)
    pcall(dump, "combatSpells[1]", spells[1])
    if type(spells[1].combatSpellDetails) == "table" then
        pcall(dump, "combatSpells[1].combatSpellDetails", spells[1].combatSpellDetails)
    end
end
