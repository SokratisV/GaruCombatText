local ADDON, ns = ...

-- Actions: the attacks avoided this fight, both ways, as count rows ("Dodge x4") on
-- the shared ns.Meter engine. Your attacks your target avoided -- dodge, parry, block,
-- miss, resist, immune -- are "miss:" rows, drawn red; the attacks on you that you
-- avoided, "avoid:" rows, drawn green (Meter.lua). Per target or every enemy, set up
-- exactly like Damage Dealt.


local playerGUID
local testAcc = 0
local meter = ns.Meter.New({ cfg = function() return ns.db.actionsText end })

-- Count: your target, or every enemy as one set for the fight (as Damage Dealt).
local function everyEnemy() return meter.isGlobal ~= nil and meter.isGlobal() end
if not ns.SummaryMode then ns.Meter.AddScope(meter, "actionsText") end
function ns.ActionsScopeChanged() if meter.ScopeChanged then meter:ScopeChanged() end end

-- Flags first, GUIDs only as a fallback: see the note above ns.SameGUID in Core.
local function pretty(m) return m:sub(1, 1) .. m:sub(2):lower() end

-- An attack on you that you avoided, onto the feed: every enemy's counting the fight,
-- your target's only when it came from your target (when that is known: the combat
-- log says who swung; on Forever nothing does, and it goes on your target's count).
local function youAvoided(m)
    local cfg = ns.db.actionsText
    if not cfg.enabled or not cfg.showIncoming or ns.test.combat then return end
    local frame = ns.actionsHostFrame
    if not frame then return end
    if everyEnemy() then meter:Fresh() end
    meter:Bump(frame, "avoid:" .. m, pretty(m), 1, 1, false, ns.AVOID_ICON[m])
end

local function destFrame(destGUID, destFlags)
    if everyEnemy() then
        if ns.UnitIsMe(destFlags) or ns.SameGUID(destGUID, UnitGUID("player")) then return nil end
        return ns.actionsHostFrame
    end
    if ns.UnitIsMyTarget(destFlags) then return ns.actionsHostFrame end
    if ns.SameGUID(destGUID, UnitGUID("target")) then return ns.actionsHostFrame end
    return nil
end

-- This feed counts what your target avoided -- dodge, parry, block, miss, resist.
-- C_DamageMeter reports damage, not misses, so the post-fight summary has nothing
-- to give it and it is switched off there. UNIT_COMBAT does report a target's
-- misses, and UnitCombat.lua matches them to your swings and casts.
ns.ActionsAvailable = not ns.UseDamageMeter

if ns.UseUnitCombat then
    ns.UC.Subscribe("avoided", function(r)
        local cfg = ns.db.actionsText
        if not cfg.enabled or ns.test.combat then return end
        if r.pet and not cfg.includePet then return end
        local frame = ns.actionsHostFrame
        if not frame then return end
        if everyEnemy() then meter:Fresh() elseif r.onTarget == false then return end
        local m = r.missType
        meter:Bump(frame, "miss:" .. m, m:sub(1, 1) .. m:sub(2):lower(), 1, 1, false, ns.AVOID_ICON[m])
    end)
    ns.UC.Subscribe("dodged", function(r)
        if everyEnemy() or UnitExists("target") then youAvoided(r.missType) end
    end)
end

if ns.ActionsAvailable then
if ns.CombatLogLive then
ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
    local cfg = ns.db.actionsText
    if not cfg.enabled then return end
    playerGUID = playerGUID or UnitGUID("player")

    local info = { CombatLogGetCurrentEventInfo() }
    local sub, srcGUID, srcFlags, destGUID, destFlags =
        info[2], info[4], info[6], info[8], info[10]
    if sub ~= "SWING_MISSED" and sub ~= "SPELL_MISSED"
        and sub ~= "RANGE_MISSED" and sub ~= "SPELL_PERIODIC_MISSED"
        and sub ~= "DAMAGE_SHIELD_MISSED" then return end   -- a resisted Thorns

    -- an attack on you that you avoided
    if ns.UnitIsMe(destFlags) or ns.SameGUID(destGUID, playerGUID) then
        local m = (sub == "SWING_MISSED") and info[12] or info[15]
        if not m then return end
        if everyEnemy() or ns.UnitIsMyTarget(srcFlags) or ns.SameGUID(srcGUID, UnitGUID("target")) then
            youAvoided(m)
        end
        return
    end

    -- source must be me (or my pet/guardian, optionally)
    local mine = ns.SourceIsMine(srcFlags, cfg.includePet)
        or ns.SameGUID(srcGUID, playerGUID)
    if not mine then return end

    local frame = destFrame(destGUID, destFlags)
    if not frame then return end

    local missType = (sub == "SWING_MISSED") and info[12] or info[15]
    if not missType then return end
    local pretty = missType:sub(1, 1) .. missType:sub(2):lower()
    if everyEnemy() then meter:Fresh() end
    meter:Bump(frame, "miss:" .. missType, pretty, 1, 1, false, ns.AVOID_ICON[missType])
end)
end

ns.On("PLAYER_TARGET_CHANGED", function()
    meter:Retarget(ns.actionsHostFrame)
end)
end

--------------------------------------------------------------------------
-- Test preview (reuses the "combat" test flag)
--------------------------------------------------------------------------
local TEST = { "DODGE", "PARRY", "BLOCK", "MISS", "RESIST" }
local TEST_IN = { "DODGE", "PARRY", "BLOCK", "MISS" }
function ns.ActionsTextTest(dt)
    testAcc = testAcc + dt
    if testAcc < 0.4 then return end
    testAcc = 0
    local f = ns.actionsHostFrame
    if not f or not f:IsShown() then return end
    if ns.db.actionsText.showIncoming and math.random() < 0.5 then
        local m = TEST_IN[math.random(1, #TEST_IN)]
        meter:Bump(f, "avoid:" .. m, pretty(m), 1, 1, false, ns.AVOID_ICON[m])
        return
    end
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
    meter:Refresh(frames, function(frame)
        return ns.ActionsAvailable and cfg.enabled and frame == ns.actionsHostFrame
    end)
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
