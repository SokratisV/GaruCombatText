-- Replays scripted fights through UnitCombat.lua against a stubbed WoW API, and
-- checks where each hit is placed. Run by tests/run.py, which sets UC_SRC to the
-- file's source.

-- WoW's own table helpers, which the addon uses as globals.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove

local clock = 0
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = clock + math.max(d, 0.001), fn = fn } end }
local function advance(to)
    while true do
        local idx, best
        for i, t in ipairs(timers) do
            if t.at <= to and (not best or t.at < best.at) then idx, best = i, t end
        end
        if not best then break end
        table.remove(timers, idx)
        clock = best.at
        best.fn()
    end
    clock = to
end

SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end
C_DamageMeter = {}
Enum = { PlayerSwingType = { MainHand = 0, OffHand = 1, Ranged = 2 } }
function GetLocale() return "enUS" end

local target, petTarget = "Creature-A", nil
local class = "WARLOCK"
-- Other enemies' nameplates, for counting every enemy: token -> GUID, and which are friends.
local plates, friendly = {}, {}
function UnitGUID(u)
    if u == "target" then return target end
    if u == "player" then return "Player-1" end
    return plates[u]
end
function UnitCanAttack(_, u)
    if u == "target" then return target ~= nil and target:find("^Creature") ~= nil end
    return plates[u] ~= nil and not friendly[u]
end
function UnitIsUnit(a, b)
    if plates[a] and b == "target" then return plates[a] == target end
    if a == "target" and b == "player" then return false end
    if a == "pettarget" and b == "target" then return petTarget ~= nil and petTarget == target end
    return a == b
end
function UnitExists(u)
    if u == "pet" then return petTarget ~= nil end
    if u == "target" then return target ~= nil end
    return true
end
function UnitName(u) if u == "pet" then return "Imp" end return "Tester" end
function UnitClass() return "X", class end

local DESC = {
    [686]  = "Sends a shadowy bolt at the enemy, causing 13 to 18 Shadow damage.",
    [172]  = "Corrupts the target, causing 40 Shadow damage over 12 sec.",
    [348]  = "Burns the enemy for 11 Fire damage and then an additional 20 Fire damage over 15 sec.",
    [702]  = "Target's melee attack power is reduced by 15 for 2 min.",
    [5782] = "Strikes fear in the enemy, causing it to run in fear for up to 10 sec.  Damage caused may interrupt the effect.",
    [2050] = "Heal your target for 47 to 58.",
    [139]  = "Heals the target of 45 damage over 15 sec.",
    [8936] = "Heals a friendly target for 93 to 107 and another 98 over 21 sec.",
    [3044] = "An instant shot that causes 13 Arcane damage.",
    [78]   = "A strong attack that increases melee damage by 11.",
    [689]  = "Transfers 2 health every 1 sec from the target to the caster.  Lasts 5 sec.",
    [1449] = "Sends out a blast of arcane energy, dealing 32 to 36 Arcane damage to all enemies within 10 yards.",
    [5176] = "Causes 13 to 16 Nature damage to the target.",
    [99001] = "Wreathes you in flame, causing 5 Fire damage to any enemy that strikes you. Lasts 10 min.",
}
local HELPFUL = { [2050] = true, [139] = true, [8936] = true }
-- Your buffs, as C_UnitAuras hands them over: { spellId, sourceUnit }
local auras, hiddenIndex, lookupHidden, locked = {}, {}, false, false
C_UnitAuras = {
    GetAuraDataByIndex = function(_, index) return auras[index] end,
    -- by spell: nil when you do not have it, or when the game will not say
    GetPlayerAuraBySpellID = function(id)
        if lookupHidden then return nil end
        for _, a in ipairs(auras) do if a.spellId == id then return a end end
    end,
}
C_Secrets = { ShouldUnitAuraIndexBeSecret = function(_, index) return hiddenIndex[index] == true end }
function InCombatLockdown() return locked end
C_Spell = {
    GetSpellDescription = function(id) return DESC[id] end,
    IsSpellHelpful = function(id) return HELPFUL[id] or false end,
}

local handlers, ns = {}, {}
function ns.On(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end
function ns.IsSecret(v) return issecretvalue(v) end
function ns.SpellName(id) return "S" .. id end
function ns.SpellTexture(id) return "tex" .. id end
local function fire(ev, ...) for _, fn in ipairs(handlers[ev] or {}) do fn(ev, ...) end end

local chunk = assert(loadstring(UC_SRC, "@UnitCombat.lua"))
chunk("GaruCombatText", ns)
assert(ns.UseUnitCombat, "UseUnitCombat should be on where C_DamageMeter exists")
assert(not ns.CombatLogLive, "CombatLogLive should be off where C_DamageMeter exists")

local got = {}
for _, kind in ipairs({ "dealt", "avoided", "taken", "dodged", "healed", "energized", "settled", "settledAll" }) do
    ns.UC.Subscribe(kind, function(r) got[#got + 1] = { kind = kind, r = r, at = clock } end)
end

-- Actions, at a time.
local function cast(t, spell, unit) advance(t); fire("UNIT_SPELLCAST_SUCCEEDED", unit or "player", "guid", spell) end
local function swing(t, hand) advance(t); fire("PLAYER_SWING", nil, ({ main = 0, off = 1, ranged = 2 })[hand or "main"]) end
local function hit(t, amount, school, flag) advance(t); fire("UNIT_COMBAT", "target", "WOUND", flag or "", amount, school) end
local function miss(t, what, school) advance(t); fire("UNIT_COMBAT", "target", what, "", 0, school) end
local function onMe(t, event, amount, school, flag) advance(t); fire("UNIT_COMBAT", "player", event, flag or "", amount, school) end
local function retarget(t, guid) advance(t); target = guid; fire("PLAYER_TARGET_CHANGED") end

local pass, fail = 0, 0
local function expect(name, t, kind, check)
    advance(t)
    local found
    for i, g in ipairs(got) do
        if g.kind == kind then found = g; table.remove(got, i) break end
    end
    local ok, why = found ~= nil, "nothing emitted"
    if found then ok, why = check(found.r) end
    if ok then pass = pass + 1 else fail = fail + 1; print("FAIL  " .. name .. ": " .. tostring(why)) end
end
local function key(k, amount)
    return function(r)
        if r.key ~= k then return false, "key " .. tostring(r.key) .. ", wanted " .. k end
        if amount and r.amount ~= amount then return false, "amount " .. tostring(r.amount) end
        return true
    end
end
local function nothing(name, t)
    advance(t)
    if #got == 0 then pass = pass + 1 return end
    fail = fail + 1
    local g = got[1]
    print("FAIL  " .. name .. ": expected nothing, got " .. g.kind .. " " .. tostring(g.r.key or g.r.missType))
    got = {}
end

-- 1. A bolt in flight.
cast(10, 686); hit(11.2, 300, 32)
expect("Shadow Bolt lands", 11.3, "dealt", key("spell:686", 300))

-- 2. A Corruption tick lands while a Shadow Bolt is in flight. With only a cast
--    window to go on, the bolt would take the tick and the two swap.
cast(20, 172); cast(21.6, 686)
hit(23.0, 10, 32)
expect("Corruption tick on its (guessed) beat beats the bolt in flight", 23.01, "dealt", key("spell:172", 10))
hit(23.1, 280, 32)
expect("...and the bolt still lands as itself", 23.11, "dealt", key("spell:686", 280))
hit(26.0, 10, 32); expect("second tick", 26.01, "dealt", key("spell:172", 10))
hit(29.0, 10, 32); expect("third tick", 29.01, "dealt", key("spell:172", 10))

-- 3. A spell that deals no damage never takes a hit.
cast(40, 702); hit(40.5, 99, 32)
nothing("Curse of Weakness takes no hit", 41.5)
cast(42, 5782); hit(42.3, 77, 32)
nothing("Fear ('damage caused may interrupt') takes no hit", 43.5)

-- 4. Hits at once and ticks.
cast(50, 348); hit(51.4, 11, 4)
expect("Immolate's hit at once", 51.41, "dealt", key("spell:348", 11))
hit(53.0, 4, 4); expect("Immolate's tick", 53.01, "dealt", key("spell:348", 4))

-- 5. Melee.
class = "WARRIOR"
swing(60); hit(60.1, 50, 1)
expect("a swing's hit", 60.11, "dealt", key("swing", 50))
hit(61.0, 45, 1); swing(61.2)
expect("a hit reported before its swing", 61.21, "dealt", key("swing", 45))
swing(62); miss(62.05, "DODGE", 1)
expect("a dodged swing", 62.06, "avoided", function(r) return r.missType == "DODGE", tostring(r.missType) end)
cast(63, 78); swing(63); hit(63.05, 120, 1)
expect("Heroic Strike takes its hit, not the swing", 63.06, "dealt", key("spell:78", 120))
-- The two gaps measured in a real fight on Forever (/gct trace, 18 Oct 2026): a
-- melee hit lands about half a second after its swing is reported.
swing(64.5); hit(65.02, 47, 1)
expect("a hit 0.52 s after its swing (measured)", 65.03, "dealt", key("swing", 47))
swing(67.6); hit(68.08, 43, 1)
expect("a hit 0.48 s after its swing (measured)", 68.09, "dealt", key("swing", 43))

-- 6. Ranged.
class = "HUNTER"
swing(70, "ranged"); cast(70, 75); hit(70.6, 80, 1)
expect("an Auto Shot (once, not twice)", 70.61, "dealt", key("spell:75", 80))
nothing("Auto Shot's own cast event adds nothing", 70.7)
cast(71, 3044); hit(71.3, 13, 64)
expect("Arcane Shot", 71.31, "dealt", key("spell:3044", 13))

-- 7. A bolt cast at one mob never claims a hit on the next.
class = "WARLOCK"
cast(80, 686); retarget(80.5, "Creature-B"); hit(81.2, 250, 32)
nothing("bolt at A, hit on B", 82)

-- 8. A hidden amount uses up its cast, adds nothing.
retarget(89, "Creature-A")
cast(90, 686); hit(91, SECRET, 32)
nothing("a hidden amount emits nothing", 91.1)
hit(91.5, 200, 32)
nothing("...and its cast cannot claim the next hit", 92)

-- 9. Pet.
petTarget = target
hit(100, 30, 1)
expect("a hit while your pet is on the target", 100.01, "dealt", function(r)
    return r.key == "pet:swing" and r.pet == true, tostring(r.key) end)
hit(100.5, 30, 1)
nothing("but at most one a second", 101.5)
petTarget = nil

-- 10. Heals on you.
cast(110, 2050); onMe(110.1, "HEAL", 50, 2)
expect("your Lesser Heal ('Heal your target for')", 110.11, "healed", function(r)
    return r.key == "spell:2050" and r.first == true, tostring(r.key) .. " first=" .. tostring(r.first) end)
cast(111, 139); onMe(111.2, "HEAL", 70, 2)
expect("a heal right as you cast Renew is someone else's", 111.21, "healed", key("heal:other", 70))
onMe(114, "HEAL", 15, 2)
expect("Renew's first tick", 114.01, "healed", function(r)
    return r.key == "spell:139" and r.first == true, tostring(r.key) .. " first=" .. tostring(r.first) end)
onMe(117, "HEAL", 15, 2)
expect("Renew's second tick carries no mana", 117.01, "healed", function(r)
    return r.key == "spell:139" and r.first == false, "first=" .. tostring(r.first) end)
cast(130, 8936); onMe(130.1, "HEAL", 100, 8)
expect("Regrowth's hit at once", 130.11, "healed", function(r)
    return r.key == "spell:8936" and r.first == true, tostring(r.key) end)
onMe(133, "HEAL", 14, 8)
expect("Regrowth's tick does not count its mana again", 133.01, "healed", function(r)
    return r.key == "spell:8936" and r.first == false, tostring(r.key) .. " first=" .. tostring(r.first) end)

-- 11. Hits on you.
onMe(140, "WOUND", 40, 4)
expect("Fire on you", 140.01, "taken", function(r) return r.amount == 40 and r.school == 4, tostring(r.school) end)
onMe(141, "DODGE", 0, 1)
expect("you dodge", 141.01, "dodged", function(r) return r.missType == "DODGE", tostring(r.missType) end)
onMe(141.5, "WOUND", 0, 1)
nothing("a hit of nothing on you, with no flag, is no miss", 141.6)
onMe(142, "WOUND", 0, 1, "ABSORB")
expect("a fully absorbed hit", 142.01, "dodged", function(r) return r.missType == "ABSORB", tostring(r.missType) end)
onMe(143, "ENERGIZE", 25)
expect("power gained", 143.01, "energized", function(r) return r.amount == 25, tostring(r.amount) end)

-- 12. Drain Life: "health every 1 sec", a channel ticking each second.
cast(150, 689)
hit(151, 2, 32); expect("Drain Life tick 1", 151.01, "dealt", key("spell:689", 2))
hit(152, 2, 32); expect("Drain Life tick 2", 152.01, "dealt", key("spell:689", 2))

-- 12b. A DoT cast never waits for a hit at once: a bolt cast just after it keeps
--      its own hit.
retarget(199, "Creature-C")
cast(200, 172); cast(200.5, 686); hit(201.5, 260, 32)
expect("a bolt cast after Corruption keeps its hit", 201.51, "dealt", key("spell:686", 260))

-- 12c. A swing's hit held back one more attack animation, an ability having gone
--      off between the two (FCT 0.6.6: a rogue's, 0.98 to 1.31 s after the swing).
swing(170); cast(170.3, 78); hit(170.4, 120, 1)
expect("the ability takes the first hit", 170.41, "dealt", key("spell:78", 120))
hit(171.25, 48, 1)
expect("the swing's own hit, 1.25 s after it", 171.26, "dealt", key("swing", 48))

-- 14. Killing blows: never reported, settled from the meter once the fight ends.
--     The shape is the recorded one (/gct trace, 18 Oct 2026): the killing swing's
--     PLAYER_SWING and the target clearing come in the same frame, and no hit follows.
local meterRows
ns.DM = { TYPES = { damage = 0 }, Capture = function() return meterRows end }
local function fight(t) advance(t); fire("PLAYER_REGEN_DISABLED") end
local function peace(t) advance(t); fire("PLAYER_REGEN_ENABLED") end
class = "DRUID"

retarget(300, "Creature-K1"); fight(300)
swing(301); hit(301.5, 44, 1)
expect("before the kill: a swing", 301.51, "dealt", key("swing", 44))
swing(303); retarget(303, nil)                 -- the kill: no hit is ever reported
peace(303.3)
meterRows = { ["spell:6603"] = { id = 6603, amount = 91 } }   -- the meter counted the killing 47
expect("the killing swing, settled to the dead mob", 304, "settled", function(r)
    if r.guid ~= "Creature-K1" then return false, "guid " .. tostring(r.guid) end
    return r.key == "swing" and r.amount == 47, tostring(r.key) .. " " .. tostring(r.amount)
end)
nothing("settled once, not on every later look at the meter", 309)

-- A kill whose blow was reported (a DoT tick, in the same frame) adds nothing.
retarget(320, "Creature-K2"); fight(320)
cast(320, 172); hit(323, 10, 32); expect("tick", 323.01, "dealt", key("spell:172", 10))
hit(326, 10, 32); expect("the killing tick, reported", 326.01, "dealt", key("spell:172", 10))
retarget(326, nil)
peace(326.4)
meterRows = { ["spell:172"] = { id = 172, amount = 20 } }
nothing("nothing missing, nothing settled", 332)

-- A gap far beyond one blow means other mobs' damage is mixed in: not guessed at.
retarget(340, "Creature-K3"); fight(340)
swing(341); hit(341.5, 40, 1); expect("swing", 341.51, "dealt", key("swing", 40))
swing(343); retarget(343, nil)
peace(343.3)
meterRows = { ["spell:6603"] = { id = 6603, amount = 900 } }
nothing("a top-up of 860 after hits of 40 is refused", 349)

-- Switching to another mob mid-fight is not a kill.
retarget(360, "Creature-K4"); fight(360)
swing(361); hit(361.5, 40, 1); expect("swing", 361.51, "dealt", key("swing", 40))
swing(363); retarget(363, "Creature-K5")
peace(364)
meterRows = { ["spell:6603"] = { id = 6603, amount = 80 } }
nothing("a target switch is not a kill", 370)

-- A bolt that kills is reported a frame or two after your target clears, on the
-- dying unit's nameplate (FCT 0.6.10): it is your target's hit, live, even with
-- the feed counting only your target.
class = "WARLOCK"
retarget(375, "Creature-K6"); fight(375)
plates.nameplate7, plates.nameplate8 = "Creature-K6", "Creature-K9"
cast(376, 686); cast(376.5, 686)                -- two bolts in flight
retarget(377, nil)                              -- the first lands: the target clears first
advance(377.03); fire("UNIT_COMBAT", "nameplate7", "WOUND", "CRITICAL", 290, 32)
expect("the killing bolt, on the dying unit's plate", 377.04, "dealt", function(r)
    if r.killed ~= "Creature-K6" then return false, "killed " .. tostring(r.killed) end
    return r.key == "spell:686" and r.amount == 290 and r.crit == true, tostring(r.key) .. " " .. tostring(r.amount)
end)
-- the same hit, reported on "target" too with no target left (/gct trace, 19 Oct 2026)
fire("UNIT_COMBAT", "target", "WOUND", "CRITICAL", 290, 32)
nothing("one hit, reported on its plate and on target: counted once", 377.04)
advance(377.05); fire("UNIT_COMBAT", "nameplate8", "WOUND", "", 60, 32)
nothing("another enemy's plate is still not your target's", 377.1)
advance(377.6); fire("UNIT_COMBAT", "nameplate7", "WOUND", "", 40, 32)
nothing("nor the dead unit's plate, once the moment has passed", 377.7)
peace(377.8)
meterRows = { ["spell:686"] = { id = 686, amount = 290 } }
nothing("its hit came: nothing to settle", 384)

-- With nameplates hidden it never comes, but the bolt in flight marks the kill.
retarget(385, "Creature-K7"); fight(385)
cast(386, 686); retarget(387, nil)
peace(387.3)
meterRows = { ["spell:686"] = { id = 686, amount = 270 } }
expect("a killing bolt with no plate to land on, settled to the dead mob", 388, "settled", function(r)
    if r.guid ~= "Creature-K7" then return false, "guid " .. tostring(r.guid) end
    return r.key == "spell:686" and r.amount == 270, tostring(r.key) .. " " .. tostring(r.amount)
end)
nothing("settled once", 393)
plates.nameplate7, plates.nameplate8 = nil, nil
class = "DRUID"

-- 15. Counting every enemy: hits on other enemies' nameplates count too, and the
--     meter's totals for the fight replace the feed's once it is over.
local function onPlate(t, token, amount, school) advance(t); fire("UNIT_COMBAT", token, "WOUND", "", amount, school) end
local function where(kind, k, onTarget)
    return function(r)
        if r.key ~= k then return false, "key " .. tostring(r.key) end
        if r.onTarget ~= onTarget then return false, "onTarget " .. tostring(r.onTarget) end
        return true
    end
end
ns.db = { enemyText = { scope = "target" }, actionsText = { scope = "target" } }
plates.nameplate1 = "Creature-A1"

-- per target: other enemies' plates are not even looked at
retarget(400, "Creature-B1")
cast(400, 172)
retarget(400.5, "Creature-C1")
onPlate(403, "nameplate1", 10, 32)
nothing("counting your target: a hit on another enemy's plate is ignored", 403.5)

ns.db.enemyText.scope = "all"
retarget(410, "Creature-A1")
cast(410, 172)                                            -- Corruption on A
retarget(411, "Creature-B2")                              -- then on to B
onPlate(413, "nameplate1", 10, 32)                        -- A's tick, on A's plate
expect("every enemy: a DoT ticking on the mob you left", 413.01, "dealt", where("dealt", "spell:172", false))

plates.nameplate2 = "Creature-B2"                         -- B's own plate
cast(420, 686); cast(420.4, 686)                          -- two bolts in flight
hit(421, 280, 32); onPlate(421, "nameplate2", 280, 32)    -- the first lands, reported twice
expect("the target's hit, once", 421.01, "dealt", where("dealt", "spell:686", true))
nothing("...not again from the target's own plate", 421.3)
hit(421.4, 275, 32)                                       -- the second, which a duplicate would have robbed
expect("...so the second bolt still has its cast", 421.41, "dealt", key("spell:686", 275))

plates.nameplate3 = "Player-Friend"; friendly.nameplate3 = true
swing(430); onPlate(430.3, "nameplate3", 50, 1)
nothing("a friend's plate: never counted", 431.5)

plates.nameplate4, plates.nameplate5 = "Creature-D1", "Creature-E1"
cast(440, 1449)                                           -- Arcane Explosion
hit(440.05, 34, 64); onPlate(440.08, "nameplate4", 33, 64); onPlate(440.1, "nameplate5", 35, 64)
expect("area: on the target", 440.2, "dealt", where("dealt", "spell:1449", true))
expect("area: on a second enemy", 440.2, "dealt", where("dealt", "spell:1449", false))
expect("area: on a third enemy", 440.2, "dealt", where("dealt", "spell:1449", false))
onPlate(440.6, "nameplate4", 30, 64)
nothing("area: once per enemy, and only in its cast's moment", 441)

swing(450); onPlate(450.4, "nameplate4", 45, 1)
nothing("a swing at your target never takes a hit on another enemy", 451.5)

-- Damage Dealt counting every enemy, Actions still per target: another enemy's
-- resist must say it was not on your target, or Actions would take it as one.
local function plateMiss(t, token, what, school) advance(t); fire("UNIT_COMBAT", token, what, "", 0, school) end
plates.nameplate6 = "Creature-H1"
retarget(455, "Creature-H1")
cast(455, 3044)                                           -- Arcane Shot at H1
retarget(455.1, "Creature-B2")                            -- then on to B
plateMiss(455.3, "nameplate6", "RESIST", 64)              -- H1 resists it, on its plate
expect("another enemy's resist is marked as not on your target", 455.4, "avoided", function(r)
    return r.onTarget == false and r.missType == "RESIST", "onTarget " .. tostring(r.onTarget) end)

-- once the fight is over, the meter's totals are the feed's
retarget(460, "Creature-F1"); fight(460)
cast(460, 686); hit(461, 300, 32); expect("bolt", 461.01, "dealt", key("spell:686", 300))
swing(462); hit(462.5, 40, 1); expect("swing", 462.51, "dealt", key("swing", 40))
peace(463)
meterRows = { ["spell:686"] = { id = 686, amount = 610 }, ["spell:6603"] = { id = 6603, amount = 85 } }
-- The meter is looked at several times as it settles; each look sets the same
-- totals again, which changes nothing.
local settledAll = {}
advance(470)
for i = #got, 1, -1 do
    if got[i].kind == "settledAll" then settledAll[got[i].r.key] = got[i].r.total; table.remove(got, i) end
end
if settledAll["spell:686"] == 610 and settledAll["swing"] == 85 then pass = pass + 1
else fail = fail + 1; print("FAIL  every enemy: the meter's totals, per spell, once the fight is over: " ..
    tostring(settledAll["spell:686"]) .. " / " .. tostring(settledAll["swing"])) end
nothing("every enemy: and no per-target kill top-up as well", 470)
ns.db.enemyText.scope = "target"

-- 16. Damage shields: Thorns hits whatever melee-hits you, in that same moment, with
--     no cast or swing of yours to go by.
retarget(500, "Creature-S1"); class = "DRUID"
nothing("(quiet before)", 500)
-- each blow on you is also damage taken, rightly; here only damage dealt matters
local function noDealt(name, t)
    advance(t)
    for i = #got, 1, -1 do if got[i].kind == "taken" then table.remove(got, i) end end
    nothing(name, t)
end
hit(501, 6, 8)
nothing("without Thorns up, a lone Nature hit is someone else's", 501.5)
auras = { { spellId = 782, sourceUnit = "player" } }        -- Thorns, rank 2: no description needed
ns.UC.RebuildShields()
onMe(503, "WOUND", 12, 1); hit(503.01, 6, 8)
expect("Thorns: the hit on whatever just struck you", 503.02, "dealt", key("spell:782", 6))
hit(505, 6, 8); onMe(505.05, "WOUND", 11, 1)              -- reported the other way round
expect("Thorns: reported before the blow that set it off", 505.1, "dealt", key("spell:782", 6))
hit(507, 6, 8)
noDealt("Thorns: no blow on you, not Thorns", 507.5)
onMe(509, "WOUND", 20, 32); hit(509.01, 6, 8)
noDealt("Thorns: a Shadow Bolt on you is no melee blow", 509.5)
cast(511, 5176); onMe(511.9, "WOUND", 12, 1); hit(511.9, 15, 8); hit(511.91, 6, 8)
expect("a Wrath landing that moment keeps its hit", 512, "dealt", key("spell:5176", 15))
expect("...and Thorns takes the other", 512, "dealt", key("spell:782", 6))
auras = { { spellId = 782, sourceUnit = "party1" } }        -- another druid's Thorns on you
ns.UC.RebuildShields()
onMe(514, "WOUND", 12, 1); hit(514.01, 6, 8)
noDealt("someone else's Thorns on you is theirs", 514.5)
auras = { { spellId = 99001, sourceUnit = "player" } }      -- a shield known only by its text
ns.UC.RebuildShields()
onMe(516, "WOUND", 12, 1); hit(516.01, 5, 4)
expect("a damage shield known by what its text says", 516.02, "dealt", key("spell:99001", 5))
auras = {}
ns.UC.RebuildShields()

-- 17. As recorded with Thorns up (/gct trace, 18 Oct 2026): the shield's hit came
--     0.30-0.36 s before its blow was reported, and in combat the buffs went hidden.
auras = { { spellId = 782, sourceUnit = "player" } }; ns.UC.RebuildShields()
hit(520, 6, 8); onMe(520.33, "WOUND", 9, 1)
expect("Thorns: the blow on you reported 0.33 s after it (measured)", 520.4, "dealt", key("spell:782", 6))
hit(522, 6, 8); hit(522.1, 6, 8); onMe(522.3, "WOUND", 6, 1); onMe(522.4, "WOUND", 6, 1)
expect("two mobs: one Thorns hit for each blow", 522.5, "dealt", key("spell:782", 6))
expect("...and the second", 522.5, "dealt", key("spell:782", 6))
-- a hidden buff ahead of a shield is stepped over, not taken for the end of the list
auras = { { spellId = 1 }, { spellId = 99001, sourceUnit = "player" } }; hiddenIndex = { [1] = true }
ns.UC.RebuildShields()
onMe(524, "WOUND", 12, 1); hit(524.01, 5, 4)
expect("a shield behind a hidden buff is still found", 524.02, "dealt", key("spell:99001", 5))
-- Thorns, asked for by spell, when the whole list is hidden
auras = { { spellId = 782, sourceUnit = "player" } }; hiddenIndex = { [1] = true }
ns.UC.RebuildShields()
onMe(526, "WOUND", 12, 1); hit(526.01, 6, 8)
expect("Thorns found by spell when the buff list is hidden", 526.02, "dealt", key("spell:782", 6))
-- in combat the buffs can go unreadable altogether: the shield is kept...
locked, lookupHidden, hiddenIndex = true, true, { [1] = true }
ns.UC.RebuildShields()
onMe(528, "WOUND", 12, 1); hit(528.01, 6, 8)
expect("in combat, with the buffs unreadable, Thorns is kept", 528.02, "dealt", key("spell:782", 6))
-- ...and let go once combat is over and it can be seen to be gone
locked, lookupHidden, hiddenIndex, auras = false, false, {}, {}
ns.UC.RebuildShields()
onMe(530, "WOUND", 12, 1); hit(530.01, 6, 8)
noDealt("out of combat, gone is gone", 531)

-- 14b. More from the Wrath kills (/gct trace, 19 Oct 2026). With nameplates hidden
--      the killing bolt came on "target" alone, after the target had cleared.
class = "DRUID"
function UnitAffectingCombat() return false end
retarget(600, "Creature-W1"); fight(600)
cast(601, 5176); retarget(601.3, nil)
hit(601.33, 31, 8)
expect("the killing Wrath, on target with no target left", 601.34, "dealt", function(r)
    if r.killed ~= "Creature-W1" then return false, "killed " .. tostring(r.killed) end
    return r.key == "spell:5176" and r.amount == 31, tostring(r.key) .. " " .. tostring(r.amount)
end)
peace(601.5)
meterRows = { ["spell:5176"] = { id = 5176, amount = 31 } }
nothing("its hit came: nothing to settle", 607)

-- After a /reload the meter, first read, can still hold the fight from before it:
-- Moonfire, Melee and Thorns, after a fight of Wrath alone. Not taken.
ns.db.enemyText.scope = "all"
meterRows = { ["spell:8925"] = { id = 8925, amount = 33 }, ["spell:6603"] = { id = 6603, amount = 42 } }
fire("PLAYER_ENTERING_WORLD")                     -- the reload, out of combat
retarget(610, "Creature-W2"); fight(610)
cast(611, 5176); hit(611.2, 30, 8); expect("Wrath", 611.21, "dealt", key("spell:5176", 30))
peace(612)
nothing("the meter still on the fight before the reload is not taken", 612.6)
meterRows = { ["spell:5176"] = { id = 5176, amount = 30 } }
expect("this fight's figures, once the meter has them", 613.6, "settledAll", function(r)
    return r.key == "spell:5176" and r.total == 30, tostring(r.key) .. " " .. tostring(r.total)
end)
advance(618)
local before = {}
for i = #got, 1, -1 do
    if got[i].kind == "settledAll" then
        if got[i].r.key ~= "spell:5176" then before[#before + 1] = got[i].r.key end
        table.remove(got, i)
    end
end
if #before == 0 and #got == 0 then pass = pass + 1
else fail = fail + 1; print("FAIL  and nothing of the fight before: " .. table.concat(before, ", ")) end
ns.db.enemyText.scope = "target"

-- Maul lands on the swing it replaces, in the swing's own frame, with a hit of
-- nothing and no flag before it. That is no miss, and must not use up Maul's cast.
DESC[6808] = "Increases the druid's next attack by 18 damage."
retarget(620, "Creature-W3")
cast(621, 6808); hit(621, 0, 1); swing(621); hit(621, 64, 1)
expect("Maul's hit is Maul's", 621.01, "dealt", key("spell:6808", 64))
nothing("and the hit of nothing is not a miss", 621.5)

-- 14c. Weapon procs: a seal, poison, oil or enchant of yours, riding on your swings.
--      The game never says which spell a proc was; a hit of the source's school in
--      a swing's moment, one per swing, is taken as it.
DESC[20154] = "Fills the Paladin with holy spirit for 30 sec. The Paladin's attacks deal additional 3 to 13 Holy damage. Only one Seal can be active on the Paladin at any one time. Unleashing this Seal's energy will judge an enemy, instantly causing 15 to 16 Holy damage."
DESC[21082] = "Fills the Paladin with the spirit of a crusader for 30 sec, increasing melee attack power by 20 and attack speed by 10%. Only one Seal can be active on the Paladin at any one time. Unleashing this Seal's energy will cause the target to take additional Holy damage."
DESC[8679]  = "Coats a weapon with poison that lasts for 30 min. Each strike has a 20% chance of poisoning the enemy which instantly inflicts 19 to 25 Nature damage. 40 charges."
DESC[2823]  = "Coats a weapon with poison that lasts for 30 min. Each strike has a 30% chance of poisoning the enemy for 36 Nature damage over 12 sec."
DESC[3595]  = "When applied to a melee weapon it gives a 10% chance of casting Frostbolt at the opponent when it hits. Lasts 30 minutes."
DESC[13898] = "Permanently enchant a melee weapon to often strike for 40 additional fire damage."
local coated = true
function GetWeaponEnchantInfo() return coated, 1000, 0, 1, false, nil, nil, nil end
retarget(630, "Creature-P1")
cast(630, 20154)                                           -- Seal of Righteousness
swing(631); hit(631.05, 9, 2)
expect("the seal's hit, in its swing's moment", 631.06, "dealt", key("spell:20154", 9))
hit(631.1, 7, 2)
nothing("one proc per swing", 631.2)
hit(631.5, 50, 1)
expect("and the swing's own blow", 631.51, "dealt", key("swing", 50))
swing(632); hit(632.05, 12, 16)
nothing("a Frost hit is not the Holy seal's", 632.1)
hit(633, 9, 2)
nothing("a Holy hit away from any swing of yours is not the seal's", 633.1)
cast(634, 21082)                                           -- Seal of the Crusader: deals nothing
swing(635); hit(635.05, 9, 2)
nothing("a seal that deals nothing ends the one before", 635.1)
cast(636, 20154); swing(675); hit(675.05, 9, 2)
nothing("a seal is gone after 30 s", 675.1)

class = "ROGUE"
cast(700, 8679)                                            -- Instant Poison
cast(700.5, 2823)                                          -- Deadly Poison: only ticks, not a source
swing(701); hit(701.02, 22, 8)
expect("Instant Poison's hit", 701.03, "dealt", key("spell:8679", 22))
local kept = ns.db.weaponProcs and ns.db.weaponProcs["Player-1"] and ns.db.weaponProcs["Player-1"].poison
if kept and kept.spell == 8679 then pass = pass + 1
else fail = fail + 1; print("FAIL  the poison is kept in saved settings, for after a /reload") end
coated = false
swing(703); hit(703.02, 22, 8)
nothing("no poison left on the weapon, no poison hit", 703.1)
coated = true
cast(710, 3595)                                            -- Frost Oil
swing(711); hit(711.08, 30, 16)
expect("Frost Oil's Frostbolt, 0.08 s after the swing", 711.09, "dealt", key("spell:3595", 30))

-- Counting every enemy, the meter has a poison's damage under its own spell, not
-- the one that put it on the weapon: the two are paired by name, not shown twice.
local NAMES = { [8679] = "Instant Poison", [8680] = "Instant Poison" }
ns.SpellName = function(id) return NAMES[id] or ("S" .. id) end
ns.db.enemyText.scope = "all"
fight(730)
swing(731); hit(731.02, 20, 8); expect("poison", 731.03, "dealt", key("spell:8679", 20))
hit(731.5, 40, 1); expect("blow", 731.51, "dealt", key("swing", 40))
peace(732)
meterRows = { ["spell:8680"] = { id = 8680, amount = 20 }, ["spell:6603"] = { id = 6603, amount = 40 } }
advance(738)
local settledKeys = {}
for i = #got, 1, -1 do
    if got[i].kind == "settledAll" then settledKeys[got[i].r.key] = got[i].r.total; table.remove(got, i) end
end
if settledKeys["spell:8679"] == 20 and settledKeys["swing"] == 40 and settledKeys["spell:8680"] == nil and #got == 0 then
    pass = pass + 1
else
    fail = fail + 1
    local parts = {}
    for k, v in pairs(settledKeys) do parts[#parts + 1] = k .. "=" .. v end
    print("FAIL  the meter's poison row is the live one's: " .. table.concat(parts, ", "))
end
ns.db.enemyText.scope = "target"

-- 14d. Which attack a kill is marked on (the skull on Damage Dealt): the killing hit
--      when it comes on the dying unit's plate, else the blow in the moment the
--      target cleared; nothing when nothing of yours was in it.
local killedList = {}
ns.UC.Subscribe("killed", function(r) killedList[#killedList + 1] = r end)
local function lastKilled(name, t, guid, k)
    advance(t)
    local r = killedList[#killedList]
    if r and r.guid == guid and r.key == k then pass = pass + 1
    else fail = fail + 1; print(("FAIL  %s: got %s %s"):format(name, tostring(r and r.guid), tostring(r and r.key))) end
end
class = "DRUID"
retarget(800, "Creature-X1"); fight(800)
swing(801); hit(801.5, 40, 1); expect("swing", 801.51, "dealt", key("swing", 40))
swing(803); retarget(803, nil)                   -- killed by the swing: no hit comes
lastKilled("a killing swing gets the mark", 804, "Creature-X1", "swing")
retarget(810, "Creature-X2")
plates.nameplate9 = "Creature-X2"
cast(810, 686); swing(811.95); retarget(812, nil)  -- a swing in the moment too
advance(812.03); fire("UNIT_COMBAT", "nameplate9", "WOUND", "", 300, 32)
expect("the killing bolt", 812.04, "dealt", key("spell:686", 300))
lastKilled("the killing hit beats the swing in the same moment", 813, "Creature-X2", "spell:686")
plates.nameplate9 = nil
local before = #killedList
retarget(820, "Creature-X3"); retarget(825, nil)   -- cleared by hand, nothing of yours in it
advance(826)
if #killedList == before then pass = pass + 1 else fail = fail + 1; print("FAIL  a target cleared by hand is no kill") end
peace(827)
advance(840)
for i = #got, 1, -1 do if got[i].kind == "settled" or got[i].kind == "settledAll" then table.remove(got, i) end end

-- 14e. Healing Done: your heals, wherever the game reports them landing.
local done, doneSettled = {}, {}
ns.UC.Subscribe("healDone", function(r) done[#done + 1] = r end)
ns.UC.Subscribe("healSettled", function(r) doneSettled[#doneSettled + 1] = r end)
local function lastDone(name, t, k, amount, on)
    advance(t)
    local r = done[#done]
    if r and r.key == k and r.amount == amount and (on == nil or r.on == on) then pass = pass + 1
    else fail = fail + 1; print(("FAIL  %s: got %s %s on %s"):format(name, tostring(r and r.key), tostring(r and r.amount), tostring(r and r.on))) end
    done = {}
end
local function noDone(name, t)
    advance(t)
    if #done == 0 then pass = pass + 1 else fail = fail + 1; print("FAIL  " .. name .. ": got " .. tostring(done[1].key)); done = {} end
end
local function healOn(t, unit, amount) advance(t); fire("UNIT_COMBAT", unit, "HEAL", "", amount, 2) end
retarget(900, "Player-Friend")                       -- a friend: heals go to them
cast(901, 2050); healOn(901.2, "target", 50)
lastDone("a heal on your friendly target", 901.3, "spell:2050", 50, "Player-Friend")
nothing("and it is no heal received", 901.4)
healOn(903, "target", 70)
noDone("someone else's heal on your target is not yours", 903.1)
cast(905, 139); healOn(905.1, "target", 99)          -- someone's heal in the cast's own moment
noDone("not in its HoT's cast moment", 905.2)
healOn(908, "target", 15)
lastDone("your Renew ticking on your target", 908.1, "spell:139", 15, "Player-Friend")
plates.nameplate11, friendly.nameplate11 = "Player-Friend", true
cast(910, 2050); cast(910.1, 2050)                  -- two heals on the way
healOn(910.2, "target", 48); healOn(910.2, "nameplate11", 48)
advance(910.3)
if #done == 1 then pass = pass + 1 else fail = fail + 1; print("FAIL  one heal, reported on your target and its plate, counted once: " .. #done) end
done = {}
healOn(910.4, "target", 51)
lastDone("...and the second heal still has its cast", 910.5, "spell:2050", 51)
plates.party1, friendly.party1 = "Player-Friend", true
cast(912, 2050); healOn(912.2, "party1", 52)
lastDone("a heal reported on a party member", 912.3, "spell:2050", 52, "Player-Friend")
plates.nameplate11, plates.party1 = nil, nil
retarget(915, "Creature-H1")                         -- an enemy targeted: heals go to you
cast(916, 2050); onMe(916.2, "HEAL", 55, 2)
lastDone("a heal on yourself, with an enemy targeted", 916.3, "spell:2050", 55, "Player-1")
expect("...and on Healing Received", 916.31, "healed", key("spell:2050", 55))
-- A heal that lands as its cast completes comes a moment ahead of the cast, in the same
-- frame (/gct trace, 21 Oct 2026): it is still the cast's, not a HoT tick or someone's.
cast(925, 8936); onMe(928, "HEAL", 14, 8)          -- Regrowth's HoT has its first tick
expect("Regrowth's tick", 928.01, "healed", key("spell:8936", 14))
done = {}
onMe(930, "HEAL", 193, 8); cast(930, 2050)          -- a heal, then its own cast, one frame
expect("a heal reported just ahead of its own cast is that cast's", 930.01, "healed", key("spell:2050", 193))
onMe(931, "HEAL", 14, 8)
expect("...and the HoT keeps its tick", 931.01, "healed", key("spell:8936", 14))
done = {}
-- once the fight is over, the meter's healing of yours, per spell
ns.db.doneText = { enabled = true }
ns.DM.TYPES.healing = 2
fight(920); peace(921)
meterRows = { ["spell:2050"] = { id = 2050, amount = 205 } }
advance(923)
local s1 = doneSettled[1]
if s1 and s1.key == "spell:2050" and s1.total == 205 then pass = pass + 1
else fail = fail + 1; print("FAIL  Healing Done set to the meter's after the fight: " .. tostring(s1 and s1.key) .. " " .. tostring(s1 and s1.total)) end
ns.db.doneText = nil
advance(930)
for i = #got, 1, -1 do if got[i].kind == "settled" or got[i].kind == "settledAll" then table.remove(got, i) end end

-- 13. What descriptions say.
local function facts(name, id, want)
    local f = ns.UC.Facts(id) or {}
    for k, v in pairs(want) do
        if f[k] ~= v then
            fail = fail + 1
            print(("FAIL  facts %s: %s = %s, wanted %s"):format(name, k, tostring(f[k]), tostring(v)))
            return
        end
    end
    pass = pass + 1
end
facts("Shadow Bolt", 686,  { damages = true, school = 32, direct = true, ticks = nil })
facts("Corruption",  172,  { damages = true, school = 32, ticks = true, direct = false, duration = 12 })
facts("Immolate",    348,  { school = 4, direct = true, ticks = true })
facts("Curse of Weakness", 702, { damages = false })
facts("Fear",        5782, { damages = false })
facts("Lesser Heal", 2050, { heals = true, hot = false, direct = true })
facts("Renew",       139,  { heals = true, hot = true, direct = false })
facts("Regrowth",    8936, { heals = true, hot = true, direct = true })
facts("Heroic Strike", 78, { damages = true, school = 1, direct = true })
facts("Arcane Explosion", 1449, { damages = true, school = 64, direct = true, area = true })
facts("Shadow Bolt is not an area spell", 686, { area = nil })
facts("Seal of Righteousness", 20154, { weaponProc = "seal", procSchool = 2, damages = false })
facts("Seal of the Crusader: its Holy is the Judgement's", 21082, { weaponProc = "seal", procSchool = nil })
facts("Instant Poison", 8679, { weaponProc = "poison", procSchool = 8 })
facts("Deadly Poison only ticks", 2823, { weaponProc = "poison", procSchool = nil })
facts("Frost Oil", 3595, { weaponProc = "oil", procSchool = 16 })
facts("Fiery Weapon", 13898, { weaponProc = "enchant", procSchool = 4 })

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then error("failures") end
