-- Replays scripted fights through UnitCombat.lua against a stubbed WoW API, and
-- checks where each hit is placed. Run by tests/run.py, which sets UC_SRC to the
-- file's source.

-- WoW's own table helpers, which the addon uses as globals.
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove

local clock = 0
function GetTime() return clock end
local timers = {}
C_Timer = { After = function(d, fn) timers[#timers + 1] = { at = clock + d, fn = fn } end }
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
function UnitCanAttack(_, u) return plates[u] ~= nil and not friendly[u] end
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

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then error("failures") end
