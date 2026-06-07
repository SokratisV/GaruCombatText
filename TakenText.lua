local ADDON, ns = ...

-- Damage Taken (per enemy): the cumulative damage YOU take this fight, one row per
-- source (each enemy, or an environmental type), on the shared ns.Meter engine.
-- Built like the Damage Dealt feed, but routed from hits where you are the target.

local MELEE_ICON = "Interface\\ICONS\\INV_Sword_04"

local playerGUID
local testAcc = 0

local meter = ns.Meter.New({ cfg = function() return ns.db.takenText end })

local function host() return ns.takenHostFrame end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.takenText
    if not cfg.enabled then return end
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcName, destGUID = info[2], info[4], info[5], info[8]
    if destGUID ~= playerGUID then return end   -- only damage dealt TO me

    local frame = host()
    if not frame then return end

    -- Misses / avoids (no damage number): DODGE, PARRY, BLOCK, MISS, ABSORB, RESIST,
    -- IMMUNE, DEFLECT, EVADE. Shown as count rows ("Dodge x4") when enabled.
    if sub == "SWING_MISSED" or sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SPELL_PERIODIC_MISSED" then
        if not cfg.showAvoid then return end
        local missType = (sub == "SWING_MISSED") and info[12] or info[15]
        if not missType then return end
        local pretty = missType:sub(1, 1) .. missType:sub(2):lower()
        meter:Bump(frame, "miss:" .. missType, pretty, 1, 1, false, nil)
        return
    end

    local key, label, amount, school, crit, iconTex
    if sub == "SWING_DAMAGE" then
        amount, school, crit = info[12], info[14], info[18]
        key, label, iconTex = "src:" .. tostring(srcGUID or "?"), srcName or "Melee", MELEE_ICON
    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE"
        or sub == "SPELL_PERIODIC_DAMAGE" or sub == "SPELL_BUILDING_DAMAGE" then
        local spellId = info[12]
        amount, school, crit = info[15], info[17], info[21]
        key, label = "src:" .. tostring(srcGUID or "?"), srcName or "Spell"
        iconTex = GetSpellTexture and GetSpellTexture(spellId) or nil
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

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST_SOURCES = {
    { label = "Snarling Wolf",   school = 1,  icon = MELEE_ICON },
    { label = "Fire Elemental",  school = 4 },
    { label = "Frost Mage",      school = 16 },
    { label = "Shadow Acolyte",  school = 32 },
}
function ns.TakenTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.3 then return end
    testAcc = 0
    local f = host()
    if not f or not f:IsShown() then return end
    if ns.db.takenText.showAvoid and math.random() < 0.3 then
        local MT = { "DODGE", "PARRY", "BLOCK", "MISS" }
        local m = MT[math.random(1, #MT)]
        meter:Bump(f, "miss:" .. m, m:sub(1, 1) .. m:sub(2):lower(), 1, 1, false, nil)
        return
    end
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
    ns.RefreshTakenText()
    if not ns.ttTicker then
        ns.ttTicker = CreateFrame("Frame", nil, UIParent)
        ns.ttTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.takenText.enabled then ns.TakenTextTest(dt) end
        end)
    end
end
