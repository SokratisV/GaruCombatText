local ADDON, ns = ...

-- Damage Received (by type): the cumulative damage YOU take this fight from ALL enemies,
-- combined per attack type -- all melee together, each incoming spell together, each
-- environmental type. On the shared ns.Meter engine; routed from hits where you're hit.

local MELEE_ICON = "Interface\\ICONS\\INV_Sword_04"

local playerGUID
local testAcc = 0

local meter = ns.Meter.New({ cfg = function() return ns.db.takenText end })

local function host() return ns.takenHostFrame end

-- Wherever the combat log is gone, UnitCombat.lua (or the summary) feeds this.
if ns.CombatLogLive then
ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.takenText
    if not cfg.enabled then return end
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, destGUID, destFlags = info[2], info[8], info[10]
    -- only damage dealt TO me. Flags first, GUID as a fallback: see ns.SameGUID.
    if not (ns.UnitIsMe(destFlags) or ns.SameGUID(destGUID, playerGUID)) then return end

    local frame = host()
    if not frame then return end

    -- (the attacks you avoided are counted on Actions, ActionsText.lua)

    local key, label, amount, school, crit, iconTex
    if sub == "SWING_DAMAGE" then
        amount, school, crit = info[12], info[14], info[18]
        key, label, iconTex = "swing", "Melee", MELEE_ICON
    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "SPELL_PERIODIC_DAMAGE" or sub == "SPELL_BUILDING_DAMAGE"
        or sub == "DAMAGE_SHIELD" then   -- an enemy's damage shield, when you strike it
        local spellId, spellName = info[12], info[13]
        amount, school, crit = info[15], info[17], info[21]
        key   = "spell:" .. tostring(spellId or spellName or "?")
        label = spellName or "Spell"
        iconTex = ns.SpellTexture(spellId)
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        local etype = info[12]
        amount, school = info[13], info[15]
        key   = "env:" .. tostring(etype or "?")
        label = etype and (etype:sub(1, 1) .. etype:sub(2):lower()) or "Environment"
    else
        return
    end

    amount = tonumber(amount) or 0
    if amount <= 0 or amount < (cfg.threshold or 0) then return end

    meter:Bump(frame, key, label, amount, school, crit and true or false, iconTex)
end)
end

-- WoW Forever, live. UNIT_COMBAT says how hard and in which school you were hit,
-- never by what, so the rows here are per school ("Fire", "Physical") rather than
-- per attacking spell. The attacks you avoided are counted on Actions.
if ns.UseUnitCombat then
    ns.UC.Subscribe("taken", function(r)
        local cfg = ns.db.takenText
        if not cfg.enabled or ns.test.combat then return end
        if r.amount < (cfg.threshold or 0) then return end
        local frame = host()
        if not frame then return end
        local name = r.school and ns.UC.SCHOOL_NAMES[r.school]
        local key = "school:" .. tostring(r.school or 0)
        local icon = r.school and ns.UC.SCHOOL_ICONS[r.school] or MELEE_ICON
        meter:Bump(frame, key, name or (r.school and "Mixed" or "Damage"), r.amount, r.school,
                   r.crit and true or false, icon)
    end)
end

-- Damage-meter path: poll my own DamageTaken rows and feed the growth. The avoid
-- rows ("Dodge x4") have no equivalent here -- that API reports damage, not misses.
if ns.UseDamageMeter then
    -- No per-target split here: this is what the fight did to you, not what one mob
    -- did, and the API offers no breakdown that would say otherwise.
    ns.DM.RegisterFeed({
        meter   = meter,
        capture = function() return ns.DM.Capture(ns.DM.TYPES.taken) end,
        frame   = host,
        enabled = function() return ns.db.takenText.enabled and not ns.test.combat end,
    })
    meter.ignorePersist = true
end

--------------------------------------------------------------------------
-- Fade lifecycle (live mode only)
--------------------------------------------------------------------------
-- Keep the whole feed up through the fight + a grace period: freeze fading
-- while in combat, and for `holdSecs` after it ends, then let it fade out.
--
-- None of this applies to a summary. There the numbers arrive *at* the end of the
-- fight, so a hold timer started when combat drops is already counting down
-- against an empty feed -- which is exactly why this fed straight into "the damage
-- taken immediately fades away". A summary just stays until the next fight.
if ns.SummaryMode then
    meter.noFade = true
else
local inCombat, fadeGen = false, 0
ns.On("PLAYER_REGEN_DISABLED", function()
    inCombat = true
    fadeGen = fadeGen + 1   -- cancel any pending post-combat fade
    meter.noFade = true
end)
ns.On("PLAYER_REGEN_ENABLED", function()
    inCombat = false
    fadeGen = fadeGen + 1
    local gen, hold = fadeGen, ns.db.takenText.holdSecs or 5
    if C_Timer and C_Timer.After then
        C_Timer.After(hold, function()
            if gen == fadeGen and not inCombat then meter.noFade = false end
        end)
    else
        meter.noFade = false
    end
end)
end

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST_SOURCES = {
    { label = "Melee",       school = 1,  icon = MELEE_ICON },
    { label = "Fireball",    school = 4 },
    { label = "Frostbolt",   school = 16 },
    { label = "Shadow Bolt", school = 32 },
}
function ns.TakenTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.3 then return end
    testAcc = 0
    local f = host()
    if not f or not f:IsShown() then return end
    local src = TEST_SOURCES[math.random(1, #TEST_SOURCES)]
    local amt = math.random(50, 900)
    if math.random() < 0.15 then amt = amt * 3 end
    meter:Bump(f, "test:" .. src.label, src.label, amt, src.school, math.random() < 0.2, src.icon)
end

function ns.ClearTakenText()
    meter:Clear()
end

--------------------------------------------------------------------------
-- Build / refresh
--------------------------------------------------------------------------
function ns.RefreshTakenText()
    local cfg = ns.db.takenText
    local frames = ns.takenHostFrame and { ns.takenHostFrame } or {}
    meter:Refresh(frames, function(frame) return cfg.enabled and frame == ns.takenHostFrame end)
end

function ns.BuildTakenText()
    playerGUID = UnitGUID("player")
    meter.noFade = InCombatLockdown() and true or false   -- frozen if we logged in mid-fight
    ns.RefreshTakenText()
    if not ns.ttTicker then
        ns.ttTicker = CreateFrame("Frame", nil, UIParent)
        ns.ttTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.takenText.enabled then ns.TakenTextTest(dt) end
        end)
    end
end
