-- Replays scripted fights through UnitCombat.lua against a stubbed WoW API, and
-- checks where each hit is placed. Run by tests/run.py, which sets UC_SRC to the
-- file's source.

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
function UnitGUID(u) if u == "target" then return target end if u == "player" then return "Player-1" end end
function UnitIsUnit(a, b)
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
}
local HELPFUL = { [2050] = true, [139] = true, [8936] = true }
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
for _, kind in ipairs({ "dealt", "avoided", "taken", "dodged", "healed", "energized" }) do
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

print(("%d passed, %d failed"):format(pass, fail))
if fail > 0 then error("failures") end
