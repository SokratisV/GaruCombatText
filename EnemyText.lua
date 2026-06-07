local ADDON, ns = ...

-- "Damage Stream" (Apex-Legends style): the cumulative damage YOU deal to your
-- target, one ever-growing number/row per damage source (melee, each spell,
-- wand, item, pet). Anchored beside the target frame (and optionally focus).
-- Built on the shared ns.Meter engine; this file is just routing + lifecycle.

local bit_band = bit and bit.band or function() return 0 end

local AFFIL_MINE    = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PET      = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
local TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000
local MINE_PET_MASK = TYPE_PET + TYPE_GUARDIAN
local MELEE_ICON    = "Interface\\ICONS\\INV_Sword_04"

local playerGUID
local testAcc = 0

local meter = ns.Meter.New({ cfg = function() return ns.db.enemyText end })

--------------------------------------------------------------------------
-- This client's mana cost for a spell, or 0 if unknown / not a mana spell.
--------------------------------------------------------------------------
local function spellManaCost(spellId)
    if not spellId then return 0 end
    local ok, costs
    if C_Spell and C_Spell.GetSpellPowerCost then
        ok, costs = pcall(C_Spell.GetSpellPowerCost, spellId)
    elseif GetSpellPowerCost then
        ok, costs = pcall(GetSpellPowerCost, spellId)
    end
    if ok and type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == 0 or c.name == "MANA" then   -- Enum.PowerType.Mana
                return c.cost or 0
            end
        end
    end
    return 0
end

--------------------------------------------------------------------------
-- Routing: damage I (or my pet) deal to the target / focus
--------------------------------------------------------------------------
local function destFrame(destGUID)
    if not ns.frames then return nil end
    if destGUID == UnitGUID("target") then return ns.frames.target end
    if ns.db.enemyText.onFocus and destGUID == UnitGUID("focus") then return ns.frames.focus end
    return nil
end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.enemyText
    if not cfg.enabled then return end
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcFlags, destGUID = info[2], info[4], info[6], info[8]

    -- is the source me (or, optionally, my pet/guardian)?
    local mine = (srcGUID == playerGUID)
    if not mine and cfg.includePet then
        srcFlags = srcFlags or 0
        mine = (bit_band(srcFlags, AFFIL_MINE) ~= 0) and (bit_band(srcFlags, MINE_PET_MASK) ~= 0)
    end
    if not mine then return end

    local frame = destFrame(destGUID)
    if not frame then return end

    -- mana spent: attribute a cast's mana cost to that spell's line (player only)
    if sub == "SPELL_CAST_SUCCESS" then
        if not cfg.showMana or srcGUID ~= playerGUID then return end
        local spellId, spellName = info[12], info[13]
        local cost = spellManaCost(spellId)
        if cost <= 0 then return end
        meter:BumpMana(frame, "spell:" .. tostring(spellId or spellName or "?"),
                       spellName or "Spell", cost, info[14],
                       GetSpellTexture and GetSpellTexture(spellId) or nil)
        return
    end

    local key, label, amount, school, crit, iconTex
    if sub == "SWING_DAMAGE" then
        amount, school, crit = info[12], info[14], info[18]
        key, label, iconTex = "swing", "Melee", MELEE_ICON
    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "SPELL_PERIODIC_DAMAGE" or sub == "SPELL_BUILDING_DAMAGE" then
        local spellId, spellName = info[12], info[13]
        amount, school, crit = info[15], info[17], info[21]
        key   = "spell:" .. tostring(spellId or spellName or "?")
        label = spellName or "Spell"
        iconTex = GetSpellTexture and GetSpellTexture(spellId) or nil
    else
        return
    end

    amount = tonumber(amount) or 0
    if amount <= 0 or amount < (cfg.threshold or 0) then return end

    meter:Bump(frame, key, label, amount, school, crit and true or false, iconTex)
end)

ns.On("PLAYER_TARGET_CHANGED", function()
    meter:Retarget(ns.frames and ns.frames.target)
end)
ns.On("PLAYER_FOCUS_CHANGED", function()
    meter:Retarget(ns.frames and ns.frames.focus)
end)

--------------------------------------------------------------------------
-- Blizzard floating combat text (the numbers it floats over the target)
--------------------------------------------------------------------------
function ns.ApplyBlizzardFCT()
    local hide = ns.db.enemyText.hideBlizzardFCT
    pcall(SetCVar, "floatingCombatTextCombatDamage", hide and "0" or "1")
    pcall(SetCVar, "floatingCombatTextCombatDamageAllAutos", hide and "0" or "1")
end

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST_SOURCES = {
    { key = "swing",      label = "Melee",       school = 1,  icon = MELEE_ICON },
    { key = "spell:133",  label = "Fireball",    school = 4 },
    { key = "spell:8056", label = "Frostbolt",   school = 16 },
    { key = "spell:2643", label = "Multi-Shot",  school = 1 },
    { key = "spell:5019", label = "Shoot",       school = 1 },
    { key = "spell:686",  label = "Shadow Bolt", school = 32 },
}
function ns.EnemyTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.3 then return end
    testAcc = 0
    local f = ns.frames and ns.frames.target
    if not f or not f:IsShown() then return end
    local src = TEST_SOURCES[math.random(1, #TEST_SOURCES)]
    local amt = math.random(80, 1400)
    if math.random() < 0.15 then amt = amt * 3 end
    meter:Bump(f, src.key, src.label, amt, src.school, math.random() < 0.2, src.icon)
    if ns.db.enemyText.showMana and src.key ~= "swing" then
        local trackers = meter:Trackers(f)
        local t = trackers and trackers[src.key]
        if t then t.mana = (t.mana or 0) + math.random(30, 260) end
    end
end

function ns.ClearEnemyText()
    meter:Clear()
end

-- Seconds of combat with the current target (freezes 3s after the last hit), or nil.
function ns.CombatDuration()
    local cs, lh = meter:CombatInfo(ns.frames and ns.frames.target)
    if not cs then return nil end
    local now = GetTime()
    local endT = (lh and (now - lh) > 3) and lh or now
    return endT - cs
end

--------------------------------------------------------------------------
-- Build / refresh
--------------------------------------------------------------------------
function ns.RefreshEnemyText()
    local cfg = ns.db.enemyText
    local frames = ns.frames and { ns.frames.target, ns.frames.focus } or {}
    meter:Refresh(frames, function(frame)
        return cfg.enabled and ns.frames
            and (frame == ns.frames.target
                 or (cfg.onFocus and frame == ns.frames.focus))
    end)
    ns.ApplyBlizzardFCT()
end

function ns.BuildEnemyText()
    playerGUID = UnitGUID("player")
    ns.RefreshEnemyText()

    if not ns.etTicker then
        ns.etTicker = CreateFrame("Frame", nil, UIParent)
        ns.etTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.enemyText.enabled then ns.EnemyTextTest(dt) end
        end)
    end
end
