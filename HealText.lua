local ADDON, ns = ...   -- own namespace; Shim.lua fills it (delegating to GarUI when present)

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
ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.healText
    if not cfg.enabled then return end       -- count in and out of combat
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, destGUID = info[2], info[4], info[8]
    if destGUID ~= playerGUID then return end

    local pf = playerFrame()
    if not pf then return end

    local function icon(id) return GetSpellTexture and GetSpellTexture(id) or nil end

    -- mana you spend on your own (self-cast) heals, shown on that spell's line
    if sub == "SPELL_CAST_SUCCESS" then
        -- track mana if it's shown OR needed for a healing/mana value
        local wantMana = cfg.showMana or cfg.valueMode == "permana" or cfg.valueMode == "both" or cfg.valueMode == "mana"
        if not wantMana or srcGUID ~= playerGUID then return end
        local spellId, spellName = info[12], info[13]
        -- absorb/shield spells (PW:S, Ice Barrier, ...) aren't healing - never
        -- give them a line in the healing section, even just for their mana.
        if ns.AbsorbSpellIds and ns.AbsorbSpellIds[spellId] then return end
        local cost = ns.Meter.SpellManaCost(spellId)
        if cost <= 0 then return end
        meter:BumpMana(pf, "spell:" .. tostring(spellId or spellName or "?"),
                       spellName or "Heal", cost, info[14], icon(spellId))
        return
    end

    if sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
        local spellId, spellName, spellSchool = info[12], info[13], info[14]
        local amount, overheal, _, crit = info[15], info[16], info[17], info[18]
        -- effective healing = total minus the part that was overheal
        local eff = (tonumber(amount) or 0) - (tonumber(overheal) or 0)
        if eff <= 0 or eff < (cfg.threshold or 0) then return end
        meter:Bump(pf, "spell:" .. tostring(spellId or spellName or "?"),
                   spellName or "Heal", eff, spellSchool, crit and true or false, icon(spellId))

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
                   spellName or "Mana", gain, spellSchool, false, icon(spellId))
    end
end)

--------------------------------------------------------------------------
-- Lifecycle: freeze the window in combat, hold Y seconds after, then roll again
--------------------------------------------------------------------------
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
    meter:Bump(pf, src.key, src.label, amt, src.school, math.random() < 0.2,
               GetSpellTexture and GetSpellTexture(tonumber(src.key:match("%d+"))) or nil)
    -- feed mana so the healing/mana value has something to divide by in preview
    local wantMana = cfg.showMana or cfg.valueMode == "permana" or cfg.valueMode == "both" or cfg.valueMode == "mana"
    if wantMana and src.key:sub(1, 5) == "spell" then
        meter:BumpMana(pf, src.key, src.label, math.random(40, 220), src.school,
                       GetSpellTexture and GetSpellTexture(tonumber(src.key:match("%d+"))) or nil)
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
