local ADDON, ns = ...   -- own namespace, shared across the addon's files
local L = ns.L

-- "Healing Received" meter on the player frame: effective healing you've received,
-- one line/row per healing spell, from ANY source (your own heals, other players,
-- potions, etc.). It is NOT bound to combat:
--   * Out of combat it shows a rolling window - only the last `windowSecs` (X) of
--     healing; older healing ages out continuously.
--   * On entering combat the window freezes and totals accumulate for the whole
--     fight (counters are maintained throughout).
--   * When combat ends all the data is kept for `holdSecs` (Y); after that the
--     rolling X-second window resumes and the totals age down from there.
-- Optionally also counts mana you gain, treating it as just another "healing" line.
-- Built on the shared ns.Meter engine in windowed mode.

local playerGUID
local testAcc = 0
local holdTimer               -- post-combat "keep everything for Y seconds" timer

local meter = ns.Meter.New({ cfg = function() return ns.db.healText end, windowed = true })

local function playerFrame() return ns.healHostFrame end   -- healing-received anchor box

--------------------------------------------------------------------------
-- Routing: healing landing on me, from anyone
--------------------------------------------------------------------------
-- Wherever the combat log is gone, UnitCombat.lua (or the summary) feeds this.
if ns.CombatLogLive then
ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.healText
    if not cfg.enabled then return end       -- count in and out of combat
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcFlags, destGUID, destFlags =
        info[2], info[4], info[6], info[8], info[10]
    -- healing landing on ME. Flags first, GUID as a fallback: see ns.SameGUID.
    if not (ns.UnitIsMe(destFlags) or ns.SameGUID(destGUID, playerGUID)) then return end

    local pf = playerFrame()
    if not pf then return end

    local function icon(id) return ns.SpellTexture(id) end

    -- mana you spend on your own (self-cast) heals, shown on that spell's line
    if sub == "SPELL_CAST_SUCCESS" then
        -- track mana if it's shown OR needed for a healing/mana value
        local wantMana = cfg.showMana or cfg.valueMode == "permana" or cfg.valueMode == "both" or cfg.valueMode == "mana"
        if not wantMana then return end
        -- ...and only for mana I spent myself, never a pet's.
        if not (ns.SourceIsMine(srcFlags, false) or ns.SameGUID(srcGUID, playerGUID)) then return end
        local spellId, spellName = info[12], info[13]
        -- absorb/shield spells (PW:S, Ice Barrier, ...) aren't healing - never
        -- give them a line in the healing section, even just for their mana.
        if ns.AbsorbSpellIds and ns.AbsorbSpellIds[spellId] then return end
        local cost = ns.Meter.SpellManaCost(spellId)
        if cost <= 0 then return end
        meter:BumpMana(pf, "spell:" .. tostring(spellId or spellName or "?"),
                       spellName or L["Heal"], cost, info[14], icon(spellId))
        return
    end

    if sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        local spellId, spellName, spellSchool = info[12], info[13], info[14]
        local amount, overheal, _, crit = info[15], info[16], info[17], info[18]
        -- effective healing = total minus the part that was overheal
        local eff = (tonumber(amount) or 0) - (tonumber(overheal) or 0)
        if eff <= 0 or eff < (cfg.threshold or 0) then return end
        meter:Bump(pf, "spell:" .. tostring(spellId or spellName or "?"),
                   spellName or L["Heal"], eff, spellSchool, crit and true or false, icon(spellId))

    elseif cfg.includeMana and (sub == "SPELL_ENERGIZE" or sub == "SPELL_PERIODIC_ENERGIZE") then
        local spellId, spellName, spellSchool = info[12], info[13], info[14]
        -- field layout differs by client: classic = amount, powerType;
        -- modern = amount, overEnergize, powerType.
        local amount = tonumber(info[15]) or 0
        local over, powerType
        if info[17] == nil then
            over, powerType = 0, info[16]
        else
            over, powerType = tonumber(info[16]) or 0, info[17]
        end
        if powerType ~= 0 then return end          -- mana only (Enum.PowerType.Mana == 0)
        local gain = amount - over                 -- effective mana gained
        if gain <= 0 or gain < (cfg.threshold or 0) then return end
        meter:Bump(pf, "mana:" .. tostring(spellId or spellName or "?"),
                   spellName or ns.ManaName(), gain, spellSchool, false, icon(spellId))
    end
end)
end

-- WoW Forever, live. UNIT_COMBAT reports every heal landing on you, from anyone,
-- but not whose it was: your own are placed on their spell by matching your casts;
-- everyone else's arrive on one "Healing" line. Whether its amount is the heal as
-- cast or only the effective part (overheal removed) is not documented -- the
-- Classic path above uses the effective part.
if ns.UseUnitCombat then
    ns.UC.Subscribe("healed", function(r)
        local cfg = ns.db.healText
        if not cfg.enabled or ns.test.combat then return end
        if r.amount < (cfg.threshold or 0) then return end
        local pf = playerFrame()
        if not pf then return end
        meter:Bump(pf, r.key, r.label, r.amount, r.school, r.crit and true or false, r.icon)
        -- Mana spent on a heal of yours that landed on you, once per cast, on that
        -- spell's line (as the Classic path does for self-cast heals).
        local wantMana = cfg.showMana or cfg.valueMode == "both" or cfg.valueMode == "mana"
        if wantMana and r.first and r.spell and not (ns.AbsorbSpellIds and ns.AbsorbSpellIds[r.spell]) then
            local cost = ns.Meter.SpellManaCost(r.spell)
            if cost > 0 then meter:BumpMana(pf, r.key, r.label, cost, r.school, r.icon) end
        end
    end)
    ns.UC.Subscribe("energized", function(r)
        local cfg = ns.db.healText
        if not cfg.enabled or not cfg.includeMana or ns.test.combat then return end
        -- UNIT_COMBAT does not say which power; count it only for a mana user.
        local pt = UnitPowerType("player")
        if ns.IsSecret(pt) or pt ~= 0 then return end
        if r.amount < (cfg.threshold or 0) then return end
        local pf = playerFrame()
        if not pf then return end
        meter:Bump(pf, "mana:gain", ns.ManaName(), r.amount, nil, false, "Interface\\ICONS\\INV_Potion_76")
    end)
end

-- Damage-meter path, and the one place this port cannot keep its promise. Healing
-- RECEIVED has no data source on this client: the only healing meter is HealingDone,
-- keyed by the caster, and the field that would say who a heal landed on
-- (combatSpellDetails.unitName) comes back blank on a source's own rows -- measured,
-- not assumed. So what the feed reports here is the healing you CAST. Heal yourself
-- and the two are the same number; heal somebody else and they are not. Mana gained
-- has no equivalent at all.
if ns.UseDamageMeter then
    ns.DM.RegisterFeed({
        meter   = meter,
        capture = function() return ns.DM.Capture(ns.DM.TYPES.healing) end,
        frame   = playerFrame,
        enabled = function() return ns.db.healText.enabled and not ns.test.combat end,
    })
    meter.ignorePersist = true
end

--------------------------------------------------------------------------
-- Lifecycle: freeze the window in combat, hold Y seconds after, then roll again
--------------------------------------------------------------------------
-- A summary has no rolling window to manage: the figures arrive once, complete,
-- after the fight. Freeze the window permanently and skip the hold machinery.
if ns.SummaryMode then
    meter:SetRolling(false)
    meter.noFade = true
else
local function cancelHold()
    if holdTimer then holdTimer:Cancel(); holdTimer = nil end
end

ns.On("PLAYER_REGEN_DISABLED", function()    -- entering combat
    cancelHold()
    meter:SetRolling(false)                  -- freeze: accumulate the whole fight
end)

ns.On("PLAYER_REGEN_ENABLED", function()     -- leaving combat
    cancelHold()
    -- keep all the fight's data for Y seconds, then resume the rolling X window
    local hold = ns.db.healText.holdSecs or 0
    if hold > 0 and C_Timer and C_Timer.NewTimer then
        holdTimer = C_Timer.NewTimer(hold, function()
            holdTimer = nil
            if not InCombatLockdown() then meter:SetRolling(true) end
        end)
    else
        meter:SetRolling(true)
    end
end)
end

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST_SOURCES = {
    { key = "spell:2050",  label = "Lesser Heal",   school = 2 },
    { key = "spell:139",   label = "Renew",         school = 2 },
    { key = "spell:774",   label = "Rejuvenation",  school = 8 },
    { key = "spell:25297", label = "Healing Wave",  school = 8 },
    { key = "spell:2061",  label = "Flash Heal",    school = 2 },
    { key = "spell:33763", label = "Lifebloom",     school = 8 },
}
local TEST_MANA   = { key = "mana:29166",   label = "Innervate",        school = 8 }
function ns.HealTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.3 then return end
    testAcc = 0
    local pf = playerFrame()
    if not pf or not pf:IsShown() then return end
    local cfg = ns.db.healText
    local src = TEST_SOURCES[math.random(1, #TEST_SOURCES)]
    if cfg.includeMana and math.random() < 0.25 then src = TEST_MANA end
    local amt = math.random(60, 900)
    if math.random() < 0.15 then amt = amt * 2 end
    meter:Bump(pf, src.key, ns.SampleName(src.key, src.label), amt, src.school, math.random() < 0.2,
               ns.SpellTexture(tonumber(src.key:match("%d+"))))
    -- feed mana so the healing/mana value has something to divide by in preview
    local wantMana = cfg.showMana or cfg.valueMode == "permana" or cfg.valueMode == "both" or cfg.valueMode == "mana"
    if wantMana and src.key:sub(1, 5) == "spell" then
        meter:BumpMana(pf, src.key, ns.SampleName(src.key, src.label), math.random(40, 220), src.school,
                       ns.SpellTexture(tonumber(src.key:match("%d+"))))
    end
end

function ns.ClearHealText()
    meter:Clear()
end

--------------------------------------------------------------------------
-- Build / refresh
--------------------------------------------------------------------------
function ns.RefreshHealText()
    local cfg = ns.db.healText
    local frames = playerFrame() and { playerFrame() } or {}
    meter:Refresh(frames, function(frame)
        return cfg.enabled and frame == playerFrame()
    end)
end

function ns.BuildHealText()
    playerGUID = UnitGUID("player")
    meter:SetRolling(not InCombatLockdown())   -- accumulate if reloading mid-fight, else roll
    ns.RefreshHealText()

    if not ns.htTicker then
        ns.htTicker = CreateFrame("Frame", nil, UIParent)
        ns.htTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.healText.enabled then ns.HealTextTest(dt) end
        end)
    end
end

--------------------------------------------------------------------------
-- Healing Done: the healing YOU cast this fight, on anyone, one row per spell
--------------------------------------------------------------------------
-- One set of totals for the fight: cleared when the next one starts, held for
-- holdSecs once it ends, then each row fades as the others' do. Heals out of combat
-- show and fade on their own. On the Classic clients the combat log says every heal
-- of yours and how much of it was overhealing (left out, as on Healing Received). On
-- Forever the game reports a heal where it lands but not whose it was; yours are
-- matched to your casts (UnitCombat.lua) on you, your target, and anyone else it
-- reports, and once the fight is over every row is set to Blizzard's damage meter's
-- figure for that spell, so the totals end exact.
local doneMeter = ns.Meter.New({ cfg = function() return ns.db.doneText end })
doneMeter.isGlobal = function() return true end     -- one set of totals, whoever you heal
local doneGen = 0

local function doneFrame() return ns.doneHostFrame end

if not ns.SummaryMode then
    ns.On("PLAYER_REGEN_DISABLED", function()
        doneGen = doneGen + 1
        doneMeter:Clear()
        doneMeter.noFade = true
    end)
    ns.On("PLAYER_REGEN_ENABLED", function()
        doneGen = doneGen + 1
        local g = doneGen
        C_Timer.After(ns.db.doneText.holdSecs or 10, function()
            if g == doneGen and not InCombatLockdown() then doneMeter.noFade = nil end
        end)
    end)
end

if ns.CombatLogLive then
ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.doneText
    if not cfg.enabled or ns.test.combat then return end
    playerGUID = playerGUID or UnitGUID("player")
    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcFlags = info[2], info[4], info[6]
    if sub ~= "SPELL_HEAL" and sub ~= "SPELL_PERIODIC_HEAL" then return end
    if not (ns.SourceIsMine(srcFlags, cfg.includePet) or ns.SameGUID(srcGUID, playerGUID)) then return end
    local f = doneFrame()
    if not f then return end
    local spellId, spellName, spellSchool = info[12], info[13], info[14]
    local amount, overheal, _, crit = info[15], info[16], info[17], info[18]
    local eff = (tonumber(amount) or 0) - (tonumber(overheal) or 0)
    if eff <= 0 or eff < (cfg.threshold or 0) then return end
    doneMeter:Bump(f, "spell:" .. tostring(spellId or spellName or "?"), spellName or L["Heal"], eff,
                   spellSchool, crit and true or false, ns.SpellTexture(spellId))
end)
end

if ns.UseUnitCombat then
    ns.UC.Subscribe("healDone", function(r)
        local cfg = ns.db.doneText
        if not cfg.enabled or ns.test.combat then return end
        if r.amount < (cfg.threshold or 0) then return end
        local f = doneFrame()
        if not f then return end
        doneMeter:Bump(f, r.key, r.label, r.amount, r.school, r.crit and true or false, r.icon)
    end)
    -- the meter's figure for each spell, once the fight is over; a spell the meter
    -- counts under another ID than the cast takes the row of the same name
    ns.UC.Subscribe("healSettled", function(r)
        local cfg = ns.db.doneText
        if not cfg.enabled or ns.test.combat then return end
        local f = doneFrame()
        if not f then return end
        local rows = doneMeter:Trackers(f)
        local key = r.key
        if rows and not rows[key] then
            for k, t in pairs(rows) do
                if t.label == r.label and k ~= key then key = k break end
            end
        end
        doneMeter:SetTotal(f, key, r.label, r.total, r.school, r.icon)
    end)
end

local DONE_TEST = {
    { key = "spell:2061",  label = "Flash Heal",   school = 2 },
    { key = "spell:139",   label = "Renew",        school = 2 },
    { key = "spell:2050",  label = "Lesser Heal",  school = 2 },
    { key = "spell:774",   label = "Rejuvenation", school = 8 },
}
local doneAcc = 0
function ns.DoneTextTest(dt)
    doneAcc = doneAcc + dt
    if doneAcc < 0.35 then return end
    doneAcc = 0
    local f = doneFrame()
    if not f or not f:IsShown() then return end
    local src = DONE_TEST[math.random(1, #DONE_TEST)]
    local amt = math.random(80, 700)
    doneMeter:Bump(f, src.key, ns.SampleName(src.key, src.label), amt, src.school, math.random() < 0.2,
                   ns.SpellTexture(tonumber(src.key:match("%d+"))))
end

function ns.ClearDoneText() doneMeter:Clear() end

function ns.RefreshDoneText()
    local cfg = ns.db.doneText
    local f = doneFrame()
    doneMeter:Refresh(f and { f } or {}, function(frame) return cfg.enabled and frame == f end)
end

function ns.BuildDoneText()
    ns.RefreshDoneText()
    if not ns.hdTicker then
        ns.hdTicker = CreateFrame("Frame", nil, UIParent)
        ns.hdTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.doneText.enabled then ns.DoneTextTest(dt) end
        end)
    end
end
