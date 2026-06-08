local ADDON, ns = ...

-- Actions: how many of YOUR attacks the current target avoided this fight -- dodge,
-- parry, block, miss, resist, immune, deflect, ... Per-target, set up exactly like
-- Damage Dealt: anchored to the target, switches and (optionally) persists per target.
-- Count rows ("Dodge x4") on the shared ns.Meter engine.

local bit_band = bit and bit.band or function() return 0 end
local AFFIL_MINE    = COMBATLOG_OBJECT_AFFILIATION_MINE or 0x00000001
local TYPE_PET      = COMBATLOG_OBJECT_TYPE_PET or 0x00001000
local TYPE_GUARDIAN = COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x00002000
local MINE_PET_MASK = TYPE_PET + TYPE_GUARDIAN

local playerGUID
local testAcc = 0
local meter = ns.Meter.New({ cfg = function() return ns.db.actionsText end })

local function destFrame(destGUID)
    if destGUID == UnitGUID("target") then return ns.actionsHostFrame end
    return nil
end

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.actionsText
    if not cfg.enabled then return end
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcFlags, destGUID = info[2], info[4], info[6], info[8]
    if sub ~= "SWING_MISSED" and sub ~= "SPELL_MISSED"
        and sub ~= "RANGE_MISSED" and sub ~= "SPELL_PERIODIC_MISSED" then return end

    -- source must be me (or my pet/guardian, optionally)
    local mine = (srcGUID == playerGUID)
    if not mine and cfg.includePet then
        srcFlags = srcFlags or 0
        mine = (bit_band(srcFlags, AFFIL_MINE) ~= 0) and (bit_band(srcFlags, MINE_PET_MASK) ~= 0)
    end
    if not mine then return end

    local frame = destFrame(destGUID)
    if not frame then return end

    local missType = (sub == "SWING_MISSED") and info[12] or info[15]
    if not missType then return end
    local pretty = missType:sub(1, 1) .. missType:sub(2):lower()
    meter:Bump(frame, "miss:" .. missType, pretty, 1, 1, false, ns.AVOID_ICON[missType])
end)

ns.On("PLAYER_TARGET_CHANGED", function()
    meter:Retarget(ns.actionsHostFrame)
end)

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST = { "DODGE", "PARRY", "BLOCK", "MISS", "RESIST" }
function ns.ActionsTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.4 then return end
    testAcc = 0
    local f = ns.actionsHostFrame
    if not f or not f:IsShown() then return end
    local m = TEST[math.random(1, #TEST)]
    meter:Bump(f, "miss:" .. m, m:sub(1, 1) .. m:sub(2):lower(), 1, 1, false, ns.AVOID_ICON[m])
end

function ns.ClearActionsText()
    meter:Clear()
end

--------------------------------------------------------------------------
-- Build / refresh
--------------------------------------------------------------------------
function ns.RefreshActionsText()
    local cfg = ns.db.actionsText
    local frames = ns.actionsHostFrame and { ns.actionsHostFrame } or {}
    meter:Refresh(frames, function(frame) return cfg.enabled and frame == ns.actionsHostFrame end)
end

function ns.BuildActionsText()
    playerGUID = UnitGUID("player")
    ns.RefreshActionsText()
    if not ns.acTicker then
        ns.acTicker = CreateFrame("Frame", nil, UIParent)
        ns.acTicker:SetScript("OnUpdate", function(_, dt)
            if ns.test.combat and ns.db.actionsText.enabled then ns.ActionsTextTest(dt) end
        end)
    end
end
