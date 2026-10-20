local ADDON, ns = ...

-- Live combat text on WoW Forever.
--
-- Forever has no addon combat log (COMBAT_LOG_EVENT_UNFILTERED registers and never
-- fires), and C_DamageMeter hides every figure until a fight ends. What it still
-- sends, live and unhidden, is UNIT_COMBAT -- the event Blizzard's own portrait
-- hit-numbers run on. It reports a hit on a unit (amount, school, crit, or which
-- kind of miss) but never who made it or with what.
--
-- What IS readable about your own side of a fight closes that gap:
--   * UNIT_SPELLCAST_SUCCEEDED for player and pet: each cast, with its spell ID;
--   * PLAYER_SWING: each weapon swing, melee or ranged;
--   * the spell's own description (C_Spell.GetSpellDescription): its school, and
--     whether it hits at once, ticks, or heals.
-- So a hit on your target is matched to them by time and school. That is WORKED
-- OUT, NOT READ. Solo it is close to exact, since nearly everything that hits your
-- target is you; in a group, a teammate's hit of the same school landing inside
-- your window can be taken for yours.
--
-- The approach, the timing windows and the description parsing are adapted from
-- Forever Combat Text by Tarolg (MIT License, Copyright (c) 2026 Tarolg), whose
-- windows were measured in real fights. This is a smaller engine than FCT's: it
-- leaves out FCT's combat-log colour channel, which buys accuracy in groups at the
-- cost of reconfiguring Blizzard's own combat log.
--
-- The feeds subscribe to what this works out (UC.Subscribe) and Bump their meters
-- just as their combat-log handlers do on Classic, so rolling windows, fades,
-- per-target memory and every layout behave as they always have.

-- If UNIT_COMBAT amounts ever turn out hidden during combat on this client (the
-- /gct probe check), set this to true to fall back to DamageMeter.lua's post-fight
-- summary. It has to be a constant: the flags below are read while files load,
-- before saved settings exist.
local FORCE_SUMMARY = false

-- C_DamageMeter's presence is the signal that the combat log is gone (Midnight
-- replaced the one with the other).
ns.CombatLogLive = (C_DamageMeter == nil)
ns.UseUnitCombat = (not ns.CombatLogLive) and not FORCE_SUMMARY

ns.UC = {}
local UC = ns.UC
if not ns.UseUnitCombat then return end

--------------------------------------------------------------------------
-- Plain values only
--------------------------------------------------------------------------
-- A secret may be stored and drawn but never compared or added, so everything the
-- game hands over is tested first.
local function plain(v) return not ns.IsSecret(v) end
local function num(v) return plain(v) and type(v) == "number" and v == v end
local function str(v) return plain(v) and type(v) == "string" and v ~= "" end
local function yes(v) return plain(v) and v == true end

local band = (bit and bit.band) or function(a, b) return a == b and a or 0 end
local function sameSchool(a, b)
    if not a or not b then return true end     -- unknown on either side: no veto
    return band(a, b) ~= 0
end

--------------------------------------------------------------------------
-- Windows (measured by FCT in recorded fights; see its Mine.lua)
--------------------------------------------------------------------------
local DIRECT_WINDOW   = 3.0   -- a bolt's hit lands within this of its cast
local PHYSICAL_WINDOW = 1.5   -- a strike or shot: no long flight to wait out
-- A melee swing's hit comes within this. FCT used 0.5; on the user's client the
-- hit landed 0.48 s and 0.52 s after its PLAYER_SWING (/gct trace, 18 Oct 2026,
-- druid, 3.1 s weapon), so at 0.5 half of all melee went unplaced. And a swing's
-- hit is sometimes held back one more attack animation: FCT 0.6.6 measured a
-- rogue's at 0.98 to 1.31 s after the swing instead of 0.49 s, 27 of 180 times,
-- mostly with a Sinister Strike between the two; it waits up to 1.35 s for any
-- swing whose animation it does not know. A swing is claimed once, oldest first,
-- so a fast weapon's next swing never takes a hit an older one is still owed.
local SWING_WINDOW    = 1.35
local RANGED_WINDOW   = 2.0   -- a wand bolt or arrow flies
local LATE_SWING      = 0.35  -- a swing may be reported this long after its hit
local FIRST_TICK_WAIT = 3.6   -- a DoT with no tick by then never landed
local TICK_GAP        = 0.9   -- no DoT ticks faster than this
local RHYTHM_SLACK    = 0.35  -- a tick on its beat lands this close to it
local DOT_FALLBACK    = 18    -- a DoT whose description gives no duration
local DOT_SLACK       = 1.0   -- its last tick may land this long after
local HEAL_WINDOW     = 0.5   -- a direct heal lands as its cast completes
local PET_GAP         = 1.0   -- a pet swings at most this often
local MAX             = 24    -- of each list

local PHYSICAL = 1
local SCHOOLS = { physical = 1, holy = 2, fire = 4, nature = 8, frost = 16, shadow = 32, arcane = 64 }
UC.SCHOOL_NAMES = { [1] = "Physical", [2] = "Holy", [4] = "Fire", [8] = "Nature",
                    [16] = "Frost", [32] = "Shadow", [64] = "Arcane" }
UC.SCHOOL_ICONS = {
    [1]  = "Interface\\ICONS\\INV_Sword_04",
    [2]  = "Interface\\ICONS\\Spell_Holy_HolyBolt",
    [4]  = "Interface\\ICONS\\Spell_Fire_FireBolt02",
    [8]  = "Interface\\ICONS\\Spell_Nature_Lightning",
    [16] = "Interface\\ICONS\\Spell_Frost_FrostBolt02",
    [32] = "Interface\\ICONS\\Spell_Shadow_ShadowBolt",
    [64] = "Interface\\ICONS\\Spell_Nature_StarFall",
}
local MELEE_ICON = "Interface\\ICONS\\INV_Sword_04"

-- Auto Shot and wand Shoot fire a cast event for every shot as well as a ranged
-- swing; the swing is the one that is matched, so the cast is not counted twice.
local AUTO_RANGED = { [75] = true, [5019] = true }

--------------------------------------------------------------------------
-- What a spell does, from its own description
--------------------------------------------------------------------------
-- "causing 120 Shadow damage over 18 sec": damages, Shadow, ticks;
-- "causing 60 Shadow damage.": damages, Shadow, hits at once;
-- "Burns the enemy for 25 Fire damage and then an additional 40 Fire damage over
-- 15 sec.": both; "Heals a friendly target for 47 to 58.": heals, at once.
-- English clients only. Elsewhere, or until the text has loaded, a spell is
-- matched as "may hit, school unknown" and its school is learned from its hits.
local AREA_WORDS = { "enemies within", "nearby enemies", "all enemies", "enemies in ", "in the area",
                     "selected area", "area of effect", "targets within", "additional targets",
                     "nearest ally", "nearby targets", "enemy targets" }

-- Damage shields: harm the unit that strikes you ("Nature damage to attackers when
-- hit", "Holy damage to any enemy that strikes a party member").
local REACTIVE_WORDS = { "attacker", "that strikes", "who strikes", "strikes you", "when struck" }

-- Weapon procs: what rides on your swings, from what you put on your weapon (FCT
-- 0.6.7 and 0.6.8). The school is what its hits are of; a source with none (Seal of
-- the Crusader, Crippling Poison, Windfury) takes no hit. Only procs that hit at once:
-- Deadly Poison's ticks are not in the swing's moment.
--   seal     "Only one Seal can be active", with "<school> damage" before the text
--            about unleashing it (that part is the Judgement, a cast of its own)
--   poison   "Coats a weapon with poison ... 19 to 25 Nature damage."
--   oil      "When applied to a melee weapon it gives a 10% chance of casting
--            Frostbolt"
--   enchant  "Permanently enchant a melee weapon to often strike for 40 additional
--            fire damage."
--   imbue    a shaman's: "Imbue the Shaman's weapon with fire ... additional Fire damage"
local BOLT_SCHOOLS = { frostbolt = 16, ["shadow bolt"] = 32, shadowbolt = 32, fireball = 4, firebolt = 4 }
local function schoolAtOnce(text)
    -- the first "<school> damage" not followed by " over" (that would be ticks)
    for word, rest in text:gmatch("(%a+) damage([^%.]*)") do
        if SCHOOLS[word] and SCHOOLS[word] ~= 1 and not rest:find("^ over") then return SCHOOLS[word] end
    end
end
local function weaponProc(lower)
    if lower:find("only one seal", 1, true) then
        return "seal", schoolAtOnce(lower:match("^(.-)unleash") or lower)
    end
    if lower:find("coats a weapon", 1, true) then return "poison", schoolAtOnce(lower) end
    if lower:find("applied to a melee weapon", 1, true) and lower:find("chance of casting", 1, true) then
        for word, school in pairs(BOLT_SCHOOLS) do
            if lower:find(word, 1, true) then return "oil", school end
        end
        return "oil", nil
    end
    if lower:find("enchant a melee weapon", 1, true) then return "enchant", schoolAtOnce(lower) end
    if lower:find("imbue", 1, true) and lower:find("weapon", 1, true) then return "imbue", schoolAtOnce(lower) end
end

local function parse(text)
    local lower = text:lower()
    local f = {}
    -- What it puts on your weapon, it does through your swings: it never hits at
    -- its own cast. Read before anything else (an oil's text says no "damage").
    local proc, procSchool = weaponProc(lower)
    if proc then
        f.weaponProc, f.procSchool = proc, procSchool
        f.damages, f.direct = false, false
        return f
    end

    -- "Heal your target for 47 to 58." (Lesser Heal), "Heals a friendly target
    -- for", "Heals the target of 45 damage over 15 sec." (Renew), "Heals 66
    -- damage over 8 sec." (a bandage). Checked before damage: Renew's text has
    -- "45 damage over" in it too.
    if lower:find("^heals?[%s,]") or lower:find("heals? [%a%s]-for %d") or lower:find("heals? [%a%s]-of %d")
        or lower:find("restores %d+ health") then
        f.heals = true
        f.hot = (lower:find("over %d+ sec") or lower:find("every %d")) and true or false
        -- Regrowth heals at once "and another 98 over 21 sec"; Renew only ticks.
        f.direct = (not f.hot) or lower:find("and another", 1, true) ~= nil
            or lower:find("additional", 1, true) ~= nil
        f.duration = tonumber(lower:match("over (%d+) sec"))
        return f
    end

    -- Damage needs a school or an amount before "damage"; "damage" alone does
    -- not count (Fear's "damage caused may interrupt the effect").
    local damages = false
    for word in lower:gmatch("(%a+) damage") do
        if SCHOOLS[word] then damages = true break end
    end
    if not damages and (lower:find("%d damage") or lower:find("weapon damage", 1, true)
        or lower:find("melee damage", 1, true) or lower:find("health every", 1, true)
        or lower:find("drains", 1, true)) then
        damages = true
    end
    if not damages then f.damages = false return f end
    f.damages = true

    -- Each "<school> damage" is over time when " over" or "every" follows it
    -- before the next "damage" or the end of its sentence.
    local at = 1
    while true do
        local first, last, word = lower:find("(%a+) damage", at)
        if not first then break end
        if SCHOOLS[word] then
            f.school = f.school or SCHOOLS[word]
            local rest = lower:sub(last + 1)
            local stop = math.min(rest:find("damage", 1, true) or #rest + 1, rest:find("%.") or #rest + 1)
            local after = rest:sub(1, stop - 1)
            if after:find("^ over") or after:find("every", 1, true) then f.ticks = true
            else f.direct = true end
        end
        at = last + 1
    end
    if lower:find("every %d") or lower:find("%d+ damage over %d") then f.ticks = true end
    if not f.school and (lower:find("weapon damage", 1, true) or lower:find("melee damage", 1, true)) then
        f.school, f.direct = PHYSICAL, true
    end
    f.duration = tonumber(lower:match("over (%d+) sec")) or tonumber(lower:match("for (%d+) sec"))
    -- Hits more than its target: "all enemies within 10 yards" (Arcane Explosion),
    -- "nearby enemies" (Swipe, Thunder Clap), "enemies in a cone" (Cone of Cold),
    -- "in a selected area" (Flamestrike, Blizzard), "up to 3 targets" (Multi-Shot),
    -- "additional targets" (Chain Lightning), "his nearest ally" (Cleave).
    for _, w in ipairs(AREA_WORDS) do
        if lower:find(w, 1, true) then f.area = true break end
    end
    if lower:find("up to %d+ targets") then f.area = true end
    for _, w in ipairs(REACTIVE_WORDS) do
        if lower:find(w, 1, true) then f.reactive = true break end
    end
    -- Only ticks: it never hits at once, so its cast must not wait for a hit (it
    -- would take the next bolt's, cast after it).
    if f.ticks and not f.direct then f.direct = false end
    -- Harm without "<school> damage" (Drain Life's "health every"): it harms,
    -- and nothing more can be said.
    if not f.direct and not f.ticks then f.direct, f.ticks = nil, nil end
    return f
end

local factCache, learnedSchool, periods = {}, {}, {}
local function English()
    local l = GetLocale and GetLocale()
    return l == "enUS" or l == "enGB"
end

function UC.Facts(spell)
    if not num(spell) then return nil end
    local cached = factCache[spell]
    if cached ~= nil then return cached or nil end
    if not English() or not (C_Spell and C_Spell.GetSpellDescription) then
        factCache[spell] = false
        return nil
    end
    local ok, text = pcall(C_Spell.GetSpellDescription, spell)
    if not ok or not str(text) then
        -- Not loaded yet: ask for it and try again on the next cast.
        if C_Spell.RequestLoadSpellData then pcall(C_Spell.RequestLoadSpellData, spell) end
        return nil
    end
    local f = parse(text)
    if C_Spell.IsSpellHelpful then
        local ok2, helpful = pcall(C_Spell.IsSpellHelpful, spell)
        if ok2 and plain(helpful) and type(helpful) == "boolean" then f.helpful = helpful end
    end
    factCache[spell] = f
    return f
end
ns.On("SPELL_TEXT_UPDATE", function(_, spell) if num(spell) then factCache[spell] = nil end end)

--------------------------------------------------------------------------
-- Subscribers
--------------------------------------------------------------------------
-- dealt    { key, label, amount, school, crit, icon, pet }   a hit of yours on your target
--          (onTarget false: on another enemy's plate; killed = guid: the blow
--          that killed the target that just cleared, on that unit's plate)
-- killed   { guid, key, label, icon, school }   your target died, and this attack did it
-- healDone { key, label, amount, school, crit, icon, on }    a heal of yours, on `on`
-- healSettled { key, label, icon, school, total }   after a fight: the meter's healing of yours
-- avoided  { missType, pet }                                 your target avoided you
-- taken    { amount, school, crit }                          a hit on you
-- dodged   { missType }                                      you avoided a hit
-- healed   { key, label, amount, school, crit, icon, spell, first }   a heal on you
-- energized{ amount }                                        power gained
-- cast     { unit, spell, label, school, offensive }         a cast of yours
local subs = {}
function UC.Subscribe(kind, fn)
    subs[kind] = subs[kind] or {}
    subs[kind][#subs[kind] + 1] = fn
end
local function emit(kind, r)
    local list = subs[kind]
    if not list then return end
    for i = 1, #list do list[i](r) end
end

--------------------------------------------------------------------------
-- Probe statistics, per fight
--------------------------------------------------------------------------
local stats, lastStats
local function newStats()
    return { at = GetTime(), target = 0, targetHidden = 0, plates = 0, player = 0, playerHidden = 0,
             casts = 0, swings = 0, unplaced = 0, missesPlaced = 0, rules = {} }
end
stats = newStats()

--------------------------------------------------------------------------
-- Fight recorder (/gct trace)
--------------------------------------------------------------------------
-- What the matcher was told and what it made of it, kept in saved variables
-- (GaruCombatTextDB.trace) so a real fight can be read back off disk after a
-- /reload and the matcher improved from it, rather than guessed at from the probe's
-- totals. Off until asked for; plain values only (a secret is written "s"); the
-- newest TRACE_MAX lines are kept. Each line starts with seconds since load.
--   P                                    the addon loaded (a /reload or login)
--   R+ / R-                              combat started / ended
--   T <target>                           target changed
--   C <unit> <spell> <school> <direct> <ticks> <offensive> <duration> <heals> <hot>
--                                        a cast of yours, and what its text says;
--                                        then proc:<kind> for a seal, poison, oil...
--   W <kind> <spell> <school>            a weapon proc source of yours, applied
--   C <unit> <spell> auto                Auto Shot / Shoot: left to its swing
--   S <arg1> <arg2> <hand>               PLAYER_SWING, its payload as it came
--   U <unit> <event> <flag> <amount> <school> [dying]       a UNIT_COMBAT report;
--                                        "dying": on the plate of the target that just cleared;
--                                        "other": a heal on someone else (party, target, plate)
--   > <decision> [key]                   what became of the report above it
--   K <guid> <key>                       your target cleared at your blow, or with a
--                                        bolt of yours in flight at it: a kill by that
--   KB <guid> <key>                      the attack the kill is marked on (the killing
--                                        hit, when it came on the dying unit's plate)
--   A <school:spell ...> | none          your damage shields that are up, when that changes
--   M <key> <meter> <shown>              after the fight: the meter's total for a
--                                        kill's attack, and what the feed had shown
local TRACE_MAX = 600
local traceT0 = GetTime()
local function w(v)
    if ns.IsSecret(v) then return "s" end
    if v == nil then return "-" end
    if v == "" then return '""' end
    return tostring(v)
end
local function tracing()
    local t = ns.db and ns.db.trace
    return t ~= nil and t.on == true and type(t.lines) == "table"
end
local function note(...)
    if not tracing() then return end
    local lines = ns.db.trace.lines
    local parts = { ("%.2f"):format(GetTime() - traceT0) }
    for i = 1, select("#", ...) do parts[#parts + 1] = w((select(i, ...))) end
    lines[#lines + 1] = table.concat(parts, " ")
    while #lines > TRACE_MAX do table.remove(lines, 1) end
end
function UC.Tracing() return tracing() end
function UC.SetTrace(on)
    if not ns.db then return end
    ns.db.trace = ns.db.trace or {}
    ns.db.trace.on = on and true or false
    if on then
        ns.db.trace.lines = {}
        traceT0 = GetTime()
        local v = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")
        note("P", v, select(2, UnitClass("player")))
    end
end
function UC.TraceSize()
    return tracing() and #ns.db.trace.lines or 0
end
ns.On("PLAYER_ENTERING_WORLD", function() note("P") end)

local function rule(name)
    stats.rules[name] = (stats.rules[name] or 0) + 1
    UC.lastRule = name
end

--------------------------------------------------------------------------
-- What you have done, recently
--------------------------------------------------------------------------
local casts, dots, swings, heals, hots, held = {}, {}, {}, {}, {}, {}
local swingMoments = {}   -- your melee swings, kept a while for the procs they carry
local petLast = 0
local epoch = 0

local function now() return GetTime() end

-- Your target, by GUID while that is readable, else by how often it has changed.
-- Keyed so a bolt cast at one mob is never matched to a hit on the next.
local function targetKey()
    local guid = UnitGUID("target")
    if str(guid) then return guid end
    return "epoch:" .. epoch
end
ns.On("PLAYER_TARGET_CHANGED", function() epoch = epoch + 1 end)

local function trim(list, keep)
    for i = #list, 1, -1 do
        if not keep(list[i]) then table.remove(list, i) end
    end
    while #list > MAX do table.remove(list, 1) end
end

local function tidy(t)
    trim(casts, function(c)
        if c.area and t - c.at <= 0.3 then return true end   -- AREA_MOMENT: its other hits
        return not c.used and t - c.at <= (c.school == PHYSICAL and PHYSICAL_WINDOW or DIRECT_WINDOW)
    end)
    trim(swings, function(s)
        return not s.used and t - s.at <= (s.hand == "ranged" and RANGED_WINDOW or SWING_WINDOW)
    end)
    trim(dots, function(d)
        if t > d.to then return false end
        if not d.last and t - d.from > FIRST_TICK_WAIT then return false end   -- never landed
        return true
    end)
    trim(heals, function(h) return not h.used and t - h.at <= HEAL_WINDOW end)
    trim(hots, function(h) return t <= h.to end)
end

local playerClass
local function rangedSpell()
    playerClass = playerClass or select(2, UnitClass("player"))
    return playerClass == "HUNTER" and 75 or 5019
end

--------------------------------------------------------------------------
-- Inputs: casts and swings
--------------------------------------------------------------------------
local function helpfulSpell(spell)
    if not (C_Spell and C_Spell.IsSpellHelpful) then return nil end
    local ok, h = pcall(C_Spell.IsSpellHelpful, spell)
    if ok and plain(h) and type(h) == "boolean" then return h end
    return nil
end

-- What is on your weapon, as you last applied it. Kept in saved settings per
-- character, as a poison lasts long past a /reload (GetTime carries on across one;
-- a source stamped later than now is from before a restart of the computer and goes).
-- A seal lasts 30 s on Forever (FCT, SpellDuration), an imbue 5 min, a poison 30 min
-- or an hour, an oil 30 min, an enchant until replaced.
local PROC_KEEP = { seal = 35, imbue = 310, poison = 3660, oil = 1860, enchant = math.huge }
local spareSources = {}
local function procSources()
    local db = ns.db
    local me = UnitGUID("player")
    if not (db and str(me)) then return spareSources end
    db.weaponProcs = db.weaponProcs or {}
    db.weaponProcs[me] = db.weaponProcs[me] or {}
    return db.weaponProcs[me]
end

-- Whether a weapon has a poison or oil on it, where the game says so; nil when it
-- does not say.
local function weaponCoated()
    if not GetWeaponEnchantInfo then return nil end
    local ok, main, _, _, _, off = pcall(GetWeaponEnchantInfo)
    if not ok or not plain(main) or not plain(off) then return nil end
    if main == nil and off == nil then return nil end
    return main == true or off == true
end

-- The newest source of this school that can still be on, or nil.
local function procFor(t, school)
    local best
    local coated
    for kind, s in pairs(procSources()) do
        local fresh = s.at <= t and t - s.at <= (PROC_KEEP[kind] or 0)
        if fresh and (kind == "poison" or kind == "oil") then
            if coated == nil then coated = weaponCoated() end
            if coated == false then fresh = false end
        end
        if fresh and s.school == school and (not best or s.at > best.at) then best = s end
    end
    return best
end

-- Who a heal of yours is cast on: your target, when that is a living friend, else
-- you (the game's own rule for a heal with no friendly target). A guess the game never
-- confirms -- a self-cast key or a mouseover macro heals someone else -- so a heal
-- landing on you still takes a cast that was meant for your target, when nothing
-- landed on the target for it.
local function healTargetGUID()
    local t = UnitGUID("target")
    if str(t) and yes(UnitExists("target")) and not yes(UnitCanAttack("player", "target"))
        and not (UnitIsDeadOrGhost and yes(UnitIsDeadOrGhost("target"))) then
        return t
    end
    local me = UnitGUID("player")
    return str(me) and me or nil
end

local function onCast(unit, spell)
    if not (str(unit) and (unit == "player" or unit == "pet")) or not num(spell) then return end
    if AUTO_RANGED[spell] then note("C", unit, spell, "auto") return end
    local t = now()
    tidy(t)
    stats.casts = stats.casts + 1

    local f = UC.Facts(spell)
    local helpful = (f and f.helpful)
    if helpful == nil then helpful = helpfulSpell(spell) end
    local school = (f and f.school) or learnedSchool[spell]
    local key = targetKey()

    -- A seal, poison, oil, enchant or imbue of yours: its hits come on your swings.
    if unit == "player" and f and f.weaponProc then
        if f.procSchool then
            procSources()[f.weaponProc] = { spell = spell, at = t, school = f.procSchool }
            note("W", f.weaponProc, spell, f.procSchool)
        elseif f.weaponProc == "seal" then
            -- only one seal is up: one that deals nothing (the Crusader) ends the last
            procSources().seal = nil
            note("W", "seal", spell, "none")
        end
    end

    -- A heal of yours. Only your own count as "yours" on a heal that lands on
    -- you; anyone else's still shows, just not under a spell of theirs.
    if unit == "player" and f and f.heals then
        -- One cast, one mana cost: Regrowth's direct heal and its ticks share this,
        -- so whichever lands first carries the cost and the other does not.
        local cast = { mana = false }
        local on = healTargetGUID()
        if f.direct then heals[#heals + 1] = { spell = spell, at = t, cast = cast, on = on } end
        if f.hot then
            -- a recast refreshes the HoT on that one; on someone else it is a second one
            for i = #hots, 1, -1 do
                if hots[i].spell == spell and hots[i].on == on then table.remove(hots, i) end
            end
            hots[#hots + 1] = { spell = spell, from = t, to = t + (f.duration or 15) + DOT_SLACK, cast = cast,
                                on = on, lastBy = {} }
        end
    end

    -- Something that might hurt your target: anything not known to be harmless.
    local offensive = not helpful and not (f and (f.heals or f.damages == false))
    if offensive then
        if not f or f.direct ~= false then
            casts[#casts + 1] = { spell = spell, unit = unit, at = t, school = school, key = key,
                                  unknown = (f == nil or f.school == nil), area = f and f.area, hits = {} }
        end
        if f and f.ticks then
            -- A recast refreshes the DoT rather than stacking a second one.
            for i = #dots, 1, -1 do
                if dots[i].spell == spell and dots[i].key == key then table.remove(dots, i) end
            end
            -- Its beat: measured in an earlier fight, else Classic's usual 3 s as a
            -- guess until two ticks have been seen. A wrong guess (Agony's 2 s)
            -- only costs the DoT its priority; it never makes a hit its tick.
            local known = periods[spell]
            dots[#dots + 1] = { spell = spell, unit = unit, school = school, key = key, from = t,
                                to = t + (f.duration or DOT_FALLBACK) + DOT_SLACK,
                                period = known or 3, guessed = (known == nil),
                                area = f and f.area, lastBy = {} }
        end
    end

    if f and f.weaponProc then
        note("C", unit, spell, f.procSchool, f.direct, f.ticks, offensive and true or false,
             f.duration, f.heals, f.hot, "proc:" .. f.weaponProc)
    else
        note("C", unit, spell, school, f and f.direct, f and f.ticks, offensive and true or false,
             f and f.duration, f and f.heals, f and f.hot)
    end
    emit("cast", { unit = unit, spell = spell, label = ns.SpellName(spell), school = school,
                   offensive = offensive and true or false })
end

local HANDS
local function hands()
    if HANDS then return HANDS end
    HANDS = {}
    local kinds = Enum and Enum.PlayerSwingType
    if kinds then
        if kinds.MainHand then HANDS[kinds.MainHand] = "main" end
        if kinds.OffHand  then HANDS[kinds.OffHand]  = "off"  end
        if kinds.Ranged   then HANDS[kinds.Ranged]   = "ranged" end
    end
    return HANDS
end

local placeSwing   -- defined with the hit matching, below

local function onSwing(swingType)
    if not num(swingType) then return end
    local hand = hands()[swingType]
    if not hand then return end
    local t = now()
    tidy(t)
    stats.swings = stats.swings + 1
    local key = targetKey()
    if hand ~= "ranged" then
        swingMoments[#swingMoments + 1] = { at = t, key = key, procs = {} }
        while swingMoments[1] and (t - swingMoments[1].at > 2 or #swingMoments > 8) do
            table.remove(swingMoments, 1)
        end
    end
    -- The order of a hit and its swing is not fixed: a hit already waiting for one
    -- takes this swing.
    for _, h in ipairs(held) do
        if not h.done and h.key == key and t - h.at <= LATE_SWING and (hand == "ranged" or h.physical) then
            h.done = true
            rule("late swing")
            placeSwing(h.rec, hand)
            return
        end
    end
    swings[#swings + 1] = { hand = hand, at = t, key = key }
end

local function swingKey(hand)
    return hand == "ranged" and ("spell:" .. rangedSpell()) or "swing"
end

--------------------------------------------------------------------------
-- Damage shields of yours that are up
--------------------------------------------------------------------------
-- Thorns, Lightning Shield, Retribution Aura: no cast or swing of yours goes with
-- their damage -- it lands on whatever melee-hits you, in that same moment. So the
-- matcher needs to know which are up, and in which school, read from your buffs
-- (C_UnitAuras, checked for secrecy first as FCT does). Known by spell (the ranks,
-- as PrettyTooltip's SpellRanks lists them), or by what a buff's text says.
-- Only one you cast yourself counts: a party paladin's aura on you is theirs.
local SHIELD_IDS = {}
for _, id in ipairs({ 467, 782, 1075, 8914, 9756, 9910 }) do SHIELD_IDS[id] = 8 end            -- Thorns
for _, id in ipairs({ 324, 325, 905, 945, 8134, 10431, 10432 }) do SHIELD_IDS[id] = 8 end      -- Lightning Shield
for _, id in ipairs({ 7294, 10298, 10299, 10300, 10301 }) do SHIELD_IDS[id] = 2 end            -- Retribution Aura

local shields = {}   -- school -> the spell of yours that is up

local function auraSecret(index)
    if not (C_Secrets and C_Secrets.ShouldUnitAuraIndexBeSecret) then return false end
    local ok, secret = pcall(C_Secrets.ShouldUnitAuraIndexBeSecret, "player", index, "HELPFUL")
    return not ok or not plain(secret) or secret == true
end

local function readable(aura)
    if type(aura) ~= "table" or not plain(aura) then return false end
    if canaccesstable and not canaccesstable(aura) then return false end
    return true
end

-- yours, or the game will not say whose (solo, that is you)
local function castByYou(aura)
    local src = aura.sourceUnit
    return not str(src) or src == "player"
end

local lastShields = ""
function UC.RebuildShields()
    -- In combat the game hides your buffs from addons, so a read then can come back
    -- with nothing (/gct trace, 18 Oct 2026: Thorns placed at 26.20, then not at all
    -- at 28.24, with Thorns still up). A shield is only let go once the buffs can
    -- be read again and it is really gone: out of combat.
    local fighting = InCombatLockdown and InCombatLockdown()
    local kept = {}
    if fighting then for school, spell in pairs(shields) do kept[school] = spell end end
    wipe(shields)
    for school, spell in pairs(kept) do shields[school] = spell end
    if not C_UnitAuras then return end
    -- The known shields, asked for by spell: a hidden buff earlier in the list
    -- cannot hide them (the first trace with Thorns up never saw it).
    if C_UnitAuras.GetPlayerAuraBySpellID then
        for spell, school in pairs(SHIELD_IDS) do
            local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spell)
            if ok and readable(aura) and castByYou(aura) then shields[school] = spell end
        end
    end
    -- Then every buff -- a known shield where that lookup is missing, any other by
    -- what its text says -- stepping over the ones the game keeps hidden rather
    -- than stopping at them.
    if C_UnitAuras.GetAuraDataByIndex then
        for index = 1, 40 do
            if not auraSecret(index) then
                local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
                if not ok then break end
                if aura == nil then break end                   -- the end of the list
                if readable(aura) then
                    local spell = aura.spellId
                    if num(spell) and castByYou(aura) then
                        local school = SHIELD_IDS[spell]
                        if not school then
                            local f = UC.Facts(spell)
                            school = f and f.reactive and f.school or nil
                        end
                        if school and not shields[school] then shields[school] = spell end
                    end
                end
            end
        end
    end
    -- What was read goes to the recorder, when it changes.
    local parts = {}
    for school, spell in pairs(shields) do parts[#parts + 1] = school .. ":" .. spell end
    table.sort(parts)
    local now = table.concat(parts, " ")
    if now ~= lastShields then
        lastShields = now
        note("A", now ~= "" and now or "none")
    end
end
if CreateFrame then
    local watcher = CreateFrame("Frame")
    if watcher.RegisterUnitEvent then watcher:RegisterUnitEvent("UNIT_AURA", "player") end
    watcher:SetScript("OnEvent", function() UC.RebuildShields() end)
end
ns.On("PLAYER_ENTERING_WORLD", function() UC.RebuildShields() end)

-- The shield's hit on the attacker is reported at once; the melee blow on you that
-- set it off comes 0.30-0.36 s later (/gct trace, 18 Oct 2026: five Thorns hits,
-- every one first), as melee always is here. So a shield hit waits for its blow,
-- and is taken the other way round only within a moment.
local hitOnMeAt = -10      -- the last melee blow on you that claimed no shield hit
local lostTargetAt = -10   -- your target last cleared in combat: it died, most likely
local lostGuid             -- ...and which unit it was
local lastDying            -- the last report taken as that unit's killing blow
local SHIELD_WAIT  = 0.6   -- a shield hit waits this long for its blow
local SHIELD_AFTER = 0.15  -- a blow reported first: a shield hit this close after

--------------------------------------------------------------------------
-- Hits on your target: whose, and with what
--------------------------------------------------------------------------
local function petAttacking(unit)
    if not yes(UnitExists("pet")) then return false end
    return yes(UnitIsUnit("pettarget", unit or "target"))
end

-- A DoT whose tick lands on its learned beat.
local function onBeat(d, t)
    local p = d.period
    if not p then return false end
    local base = d.last or d.from
    local n = math.floor((t - base) / p + 0.5)
    if n < 1 then return false end
    return math.abs((t - base) - n * p) <= RHYTHM_SLACK
end

local function tick(d, t)
    if d.last then
        local gap = t - d.last
        if (d.guessed or not d.period) and gap >= TICK_GAP and gap <= 3.3 then
            d.period = math.floor(gap * 2 + 0.5) / 2     -- to the half second
            d.guessed = false
            periods[d.spell] = d.period
        end
    end
    d.last = t
end

local function spellRecord(spell, rec, unit)
    rec.key   = "spell:" .. spell
    rec.label = ns.SpellName(spell) or ("Spell " .. spell)
    rec.icon  = ns.SpellTexture(spell)
    rec.pet   = (unit == "pet")
    return rec
end

--------------------------------------------------------------------------
-- Killing blows
--------------------------------------------------------------------------
-- The blow that kills your target is never reported. The mob dies, your target
-- clears in that same frame, and the UNIT_COMBAT that would have followed (a melee
-- hit is reported about half a second after its PLAYER_SWING) has no "target"
-- left to arrive on (/gct trace, 18 Oct 2026: three kills, the two by melee left
-- no report at all; the one by a DoT tick was reported, in the same frame).
--
-- The amount is not lost, only late: C_DamageMeter, hidden during combat, gives
-- the fight's totals once it ends. So a target that clears at the moment of
-- something of yours is noted as a kill by that attack, and once the meter speaks,
-- whatever it counted for that attack beyond what the feed showed is credited to
-- the dead unit. Only the killing attack is topped up, only by what is missing,
-- and not at all when the gap is larger than such a hit could be -- that much
-- means damage on other mobs is mixed in, and splitting it would be a guess.
--
-- A bolt that kills is different: it is reported, a frame or two after your target
-- has cleared, on the dying enemy's nameplate (FCT 0.6.10, a warlock's bolts). So a
-- hit on the plate of the unit that was your target a moment ago is taken as your
-- target's, live, and goes on that unit's own totals. The bolt's cast also marks the
-- kill (it is in flight at that unit when the target clears), so with nameplates
-- hidden it is still settled from the meter; when its hit did come, nothing is missing.
local KILL_MOMENT  = 0.1    -- a target clearing this close to your blow: that blow killed it
local KILL_PLATE   = 0.5    -- the killing bolt comes on the dying unit's plate within this
local SETTLE_AT    = { 0.5, 1.5, 3, 5 }   -- the meter is not final the instant combat drops
local SETTLE_LIMIT = 3      -- a top-up may be at most this many of the attack's largest hits

local tally, biggest, kills = {}, {}, {}   -- this fight: shown per key, largest hit per key, kills
local pendingKill                          -- the kill just noticed, waiting for its killing hit
local emitKill                             -- (below, once keyLabel is)
local lastBlow                             -- { at, key }: the last thing of yours that landed or swung
local fightNo, inCombat, prevTarget = 0, false, nil

local function blow(key, t)
    lastBlow = { at = t or now(), key = key }
end

local function out(rec)
    -- A miss names what missed: "miss:DODGE/swing", "miss:RESIST/spell:686".
    local placed = rec.missType and ("miss:" .. rec.missType .. (rec.key and ("/" .. rec.key) or "")) or rec.key
    if rec.hidden then note(">", UC.lastRule, placed, "hidden") else note(">", UC.lastRule, placed) end
    if rec.key and not rec.pet and rec.onTarget ~= false then blow(rec.key) end
    if rec.missType then
        stats.missesPlaced = stats.missesPlaced + 1
        emit("avoided", { missType = rec.missType, pet = rec.pet, onTarget = rec.onTarget })
    elseif rec.amount then
        if not rec.pet then
            tally[rec.key] = (tally[rec.key] or 0) + rec.amount
            if rec.amount > (biggest[rec.key] or 0) then biggest[rec.key] = rec.amount end
        end
        emit("dealt", rec)
    end
end

placeSwing = function(rec, hand)
    if hand == "ranged" then
        local spell = rangedSpell()
        spellRecord(spell, rec, "player")
    else
        rec.key, rec.label, rec.icon, rec.pet = "swing", "Melee", MELEE_ICON, false
    end
    out(rec)
end

-- Physical-looking misses come off swings; spell-looking ones off casts.
local SWING_MISSES = { MISS = true, DODGE = true, PARRY = true, BLOCK = true, DEFLECT = true, EVADE = true }

-- An area spell's hits land on every enemy near it in its cast's own moment (FCT
-- 0.3.42: every recorded Frost Nova, Arcane Explosion and Flamestrike hit did),
-- so a hit on another enemy then is that cast's too -- once per enemy.
local AREA_MOMENT = 0.3

-- A spell's hit is reported without the delay a melee blow's has, so a proc lands in
-- its swing's moment, not its blow's: Frost Oil's Frostbolt 0.06 to 0.1 s after the
-- swing (FCT 0.6.8, a warlock's staff). Not yet seen here for a seal or a poison.
local PROC_MOMENT = 0.25

-- Whose hit this was, on your target or (for an every-enemy feed) another enemy's
-- nameplate. key: the unit's key, which casts and DoTs remember; unit: its token.
local function placeOnTarget(rec, t, key, unit)
    key = key or targetKey()
    unit = unit or "target"
    rec.onTarget = (unit == "target") and not rec.killed
    local school = rec.school
    local physical = (school == nil or school == PHYSICAL)
    local isMiss = rec.missType ~= nil

    -- 1. A DoT of yours, on its beat.
    if not isMiss then
        for _, d in ipairs(dots) do
            if d.key == key and t >= d.from and sameSchool(d.school, school) and onBeat(d, t) then
                tick(d, t); rule("tick on beat")
                return out(spellRecord(d.spell, rec, d.unit))
            end
        end
    end

    -- 2. The oldest cast of yours at this unit, of this school, still in flight;
    --    or an area spell of yours cast this moment. A swing-type miss looks for a
    --    swing first.
    local swingFirst = isMiss and SWING_MISSES[rec.missType]
    local function tryCast()
        for _, c in ipairs(casts) do
            local window = (c.school == PHYSICAL) and PHYSICAL_WINDOW or DIRECT_WINDOW
            if not c.used and c.key == key and t >= c.at and t - c.at <= window
                and sameSchool(c.school, school) then
                c.used = true
                c.hits[key] = true
                if c.unknown and school and not learnedSchool[c.spell] then
                    learnedSchool[c.spell] = school
                end
                rule(c.unknown and "cast (school learned)" or "cast")
                out(spellRecord(c.spell, rec, c.unit))
                return true
            end
        end
        for _, c in ipairs(casts) do
            if c.area and not c.hits[key] and math.abs(t - c.at) <= AREA_MOMENT and sameSchool(c.school, school) then
                c.hits[key] = true
                rule("area")
                out(spellRecord(c.spell, rec, c.unit))
                return true
            end
        end
    end
    local function trySwing()
        for _, s in ipairs(swings) do
            local window = (s.hand == "ranged") and RANGED_WINDOW or SWING_WINDOW
            -- a swing is aimed at one unit: only a hit on that one is its
            if not s.used and s.key == key and t - s.at <= window and (physical or s.hand == "ranged") then
                s.used = true
                rule("swing")
                placeSwing(rec, s.hand)
                return true
            end
        end
    end
    if swingFirst then
        if trySwing() or tryCast() then return end
    else
        if tryCast() then return end
    end

    -- 2b. A proc of what is on your weapon, riding on a melee swing of yours at this
    --     unit: of its school, in the swing's moment, at most one per swing.
    if not isMiss and school and school ~= PHYSICAL then
        local src = procFor(t, school)
        if src then
            for _, m in ipairs(swingMoments) do
                local after = t - m.at
                if m.key == key and after >= -0.02 and after <= PROC_MOMENT and not m.procs[src.spell] then
                    m.procs[src.spell] = true
                    rule("weapon proc")
                    return out(spellRecord(src.spell, rec, "player"))
                end
            end
        end
    end

    -- 3. A DoT of yours whose beat is not known yet -- on this unit, or anywhere
    --    for one that covers an area (Consecration, Blizzard), each enemy on its own.
    if not isMiss then
        for _, d in ipairs(dots) do
            if t >= d.from and sameSchool(d.school, school) then
                if d.key == key and not d.area then
                    if (d.last and t - d.last >= TICK_GAP) or (not d.last and t - d.from >= 0.8) then
                        tick(d, t); rule("tick")
                        return out(spellRecord(d.spell, rec, d.unit))
                    end
                elseif d.area then
                    local last = d.lastBy[key]
                    if (last and t - last >= TICK_GAP) or (not last and t - d.from >= 0.8) then
                        d.lastBy[key] = t; rule("area tick")
                        return out(spellRecord(d.spell, rec, d.unit))
                    end
                end
            end
        end
    end

    -- 3b. Your damage shield, on the unit that struck you: in the moment a melee hit
    --     landed on you, or -- the order of the two is not fixed -- in a moment's
    --     wait for that hit (claimShield, below).
    local shield = not isMiss and school and school ~= PHYSICAL and shields[school]
    if shield then
        if t - hitOnMeAt <= SHIELD_AFTER then
            hitOnMeAt = -10                     -- that blow has its shield hit now
            rule("damage shield")
            return out(spellRecord(shield, rec, "player"))
        end
        local h = { at = t, rec = rec, shield = shield, target = (unit == "target") }
        held[#held + 1] = h
        note(">", "held for a hit on you")
        C_Timer.After(SHIELD_WAIT + 0.02, function()
            if not h.done then
                h.done = true
                -- The blow that killed it: a mob that dies in the shield's moment
                -- never has its blow on you reported (as with your own killing
                -- swing), so the shield hit cannot wait for it.
                if h.target and math.abs(lostTargetAt - h.at) <= 0.1 then
                    rule("damage shield")
                    note(">", "damage shield, the blow that killed it")
                    out(spellRecord(h.shield, h.rec, "player"))
                else
                    stats.unplaced = stats.unplaced + 1
                    note(">", "no hit on you came: unplaced", rec.amount)
                end
            end
            for i = #held, 1, -1 do if held[i].done then table.remove(held, i) end end
        end)
        return
    end

    -- 4. A weapon swing.
    if not swingFirst and trySwing() then return end

    -- 5. Your pet, if it is on this unit (its swings are not reported, so at most
    --    one hit a second).
    if physical and not isMiss and t - petLast >= PET_GAP and petAttacking(unit) then
        petLast = t
        rule("pet")
        rec.key, rec.label, rec.icon, rec.pet = "pet:swing", UnitName("pet") or "Pet", MELEE_ICON, true
        if not str(rec.label) then rec.label = "Pet" end
        return out(rec)
    end

    -- 6. Physical, unexplained: wait a moment in case its swing is reported late.
    if physical or isMiss then
        local h = { at = t, rec = rec, physical = physical, key = key }
        held[#held + 1] = h
        note(">", "held for a late swing")
        C_Timer.After(LATE_SWING + 0.02, function()
            if not h.done then
                h.done = true; stats.unplaced = stats.unplaced + 1
                note(">", "no late swing came: unplaced", rec.missType or rec.amount)
            end
            for i = #held, 1, -1 do if held[i].done then table.remove(held, i) end end
        end)
        return
    end

    -- 7. Someone else's.
    stats.unplaced = stats.unplaced + 1
    note(">", "unplaced")
end

--------------------------------------------------------------------------
-- Hits and heals on you
--------------------------------------------------------------------------
local function myGUID()
    local me = UnitGUID("player")
    return str(me) and me or nil
end

-- Healing Done: a heal of yours, wherever it landed.
local function healDone(spell, amount, school, crit, on)
    emit("healDone", spellRecord(spell, { amount = amount, school = school, crit = crit, on = on }, "player"))
end

-- A HoT of yours ticking on `guid` now: on its beat for that unit, never in its cast's
-- own moment (a heal landing then is somebody else's).
local function hotTick(h, guid, t)
    local last = h.lastBy[guid]
    if (last and t - last >= TICK_GAP) or (not last and t - h.from >= 0.8) then
        h.lastBy[guid] = t
        return true
    end
end

local function placeHealOnMe(amount, school, crit, t)
    local rec = { amount = amount, school = school, crit = crit }
    local me = myGUID()
    local function mine(spell, cast, name)
        rule(name)
        note(">", name, "spell:" .. spell)
        spellRecord(spell, rec, "player")
        rec.spell, rec.first = spell, not cast.mana
        cast.mana = true
        healDone(spell, amount, school, crit, me)
        return emit("healed", rec)
    end
    -- a heal cast at you first; then one meant for your target, which landed on you
    for pass = 1, 2 do
        for _, h in ipairs(heals) do
            if not h.used and t - h.at <= HEAL_WINDOW and (pass == 2 or h.on == me) then
                h.used = true
                return mine(h.spell, h.cast, "your heal")
            end
        end
    end
    for _, h in ipairs(hots) do
        if (h.on == nil or h.on == me) and hotTick(h, me or "player", t) then
            return mine(h.spell, h.cast, "your heal over time")
        end
    end
    rule("someone else's heal")
    note(">", "someone else's heal")
    rec.key, rec.label, rec.icon = "heal:other", "Healing", "Interface\\ICONS\\Spell_Holy_Heal"
    emit("healed", rec)
end

--------------------------------------------------------------------------
-- UNIT_COMBAT
--------------------------------------------------------------------------
local FEEDBACK = { MISS = true, DODGE = true, PARRY = true, BLOCK = true, RESIST = true, EVADE = true,
                   IMMUNE = true, DEFLECT = true, ABSORB = true, REFLECT = true }

-- Hits on enemies other than your target come on their nameplates, and are only
-- wanted by a feed counting every enemy.
local function wantAll()
    local db = ns.db
    if not db then return false end
    return (db.enemyText and db.enemyText.scope == "all") or (db.actionsText and db.actionsText.scope == "all") or false
end

-- Heals on someone else (Healing Done): only yours count, and only where the game
-- reports them -- your target, a friendly nameplate, and party or raid members if it
-- reports those at all (not yet seen; /gct trace records any that come). The heal
-- cast at that unit just before, or a HoT of yours on it ticking on its beat. One
-- heal reported twice (on your target and on its plate) is counted once.
local lastDone
local OTHER_UNITS = { "^target$", "^focus$", "^pet$", "^party%d$", "^raid%d+$", "^nameplate%d+$" }
local function healOnOther(unit, flag, amount, school)
    local known = false
    for _, p in ipairs(OTHER_UNITS) do if unit:find(p) then known = true break end end
    if not known then return false end
    if yes(UnitCanAttack("player", unit)) then return false end       -- an enemy healing
    local guid = UnitGUID(unit)
    if not str(guid) then return true end
    if guid == myGUID() then return true end                          -- counted on you
    note("U", unit, "HEAL", flag, amount, school, "other")
    if not num(amount) or amount <= 0 then return true end
    local t = now()
    tidy(t)
    local d = lastDone
    if d and d.guid == guid and d.amount == amount and t - d.at <= 0.05 then
        note(">", "the same heal, on its other unit")
        return true
    end
    lastDone = { guid = guid, amount = amount, at = t }
    stats.healsOthers = (stats.healsOthers or 0) + 1
    local crit = (flag == "CRITICAL")
    for _, h in ipairs(heals) do
        if not h.used and h.on == guid and t - h.at <= HEAL_WINDOW then
            h.used = true
            rule("your heal on another")
            note(">", "your heal on another", "spell:" .. h.spell)
            healDone(h.spell, amount, school, crit, guid)
            return true
        end
    end
    for _, h in ipairs(hots) do
        if h.on == guid and hotTick(h, guid, t) then
            rule("your heal over time on another")
            note(">", "your heal over time on another", "spell:" .. h.spell)
            healDone(h.spell, amount, school, crit, guid)
            return true
        end
    end
    note(">", "someone else's heal on another")
    return true
end

local function onUnitCombat(unit, event, flag, amount, school)
    if not str(unit) or not str(event) then return end
    if event == "HEAL" and unit ~= "player" then
        if unit == "target" and yes(UnitIsUnit("target", "player")) then return end   -- reported on you too
        if healOnOther(unit, str(flag) and flag or "", amount, school) then return end
    end
    local plateKey, dying
    if unit ~= "target" and unit ~= "player" then
        if not unit:find("^nameplate%d+$") then return end
        -- your target's own plate reports the same hit as "target" does
        if yes(UnitIsUnit(unit, "target")) then return end
        plateKey = UnitGUID(unit)
        if not str(plateKey) then return end
        if plateKey == lostGuid and now() - lostTargetAt <= KILL_PLATE then
            -- the unit that was your target a moment ago: the blow that killed it
            dying = plateKey
        elseif not wantAll() then
            return
        -- an enemy; a friend's plate, or one the game will not say, is left out
        elseif not yes(UnitCanAttack("player", unit)) then
            return
        end
    end
    if unit == "target" and yes(UnitIsUnit("target", "player")) then return end
    -- The killing bolt can come on "target" too, with no target left (/gct trace,
    -- 19 Oct 2026: two of three Wrath kills came on both, in the same frame, the
    -- third on the plate alone; with nameplates hidden, on "target" alone).
    if unit == "target" and not str(UnitGUID("target")) and lostGuid and now() - lostTargetAt <= KILL_PLATE then
        dying, plateKey = lostGuid, lostGuid
    end
    if dying then note("U", unit, event, flag, amount, school, "dying")
    else note("U", unit, event, flag, amount, school) end

    local t = now()
    tidy(t)
    if dying then
        -- one hit, reported on both: counted once
        local d = lastDying
        if d and d.unit ~= unit and t - d.at <= 0.05 and d.event == event and d.school == school
            and (d.amount == amount or not (num(amount) and num(d.amount))) then
            lastDying = nil
            note(">", "the same hit, on its other unit")
            return
        end
        lastDying = { unit = unit, at = t, event = event, school = school, amount = amount }
    end
    flag = str(flag) and flag or ""
    school = (num(school) and school >= 1 and school <= 255) and school or nil
    local hidden = not num(amount)

    if unit == "player" then
        stats.player = stats.player + 1
        if hidden and (event == "WOUND" or event == "HEAL" or event == "ENERGIZE") then
            stats.playerHidden = stats.playerHidden + 1
            return
        end
        if event == "WOUND" then
            -- a melee blow that landed, even one absorbed or blocked whole, sets off a
            -- damage shield: it claims the oldest shield hit waiting for one
            local landed = amount > 0 or flag == "ABSORB" or flag == "BLOCK"
            if landed and (school == nil or school == PHYSICAL) then
                local claimed = false
                for _, h in ipairs(held) do
                    if h.shield and not h.done and t - h.at <= SHIELD_WAIT then
                        h.done, claimed = true, true
                        rule("damage shield")
                        out(spellRecord(h.shield, h.rec, "player"))
                        break
                    end
                end
                hitOnMeAt = claimed and -10 or t
            end
            if amount > 0 then
                emit("taken", { amount = amount, school = school, crit = (flag == "CRITICAL") })
            else
                emit("dodged", { missType = (flag == "ABSORB" or flag == "BLOCK" or flag == "RESIST") and flag or "MISS" })
            end
        elseif event == "HEAL" then
            if amount > 0 then placeHealOnMe(amount, school, flag == "CRITICAL", t) end
        elseif event == "ENERGIZE" then
            if amount > 0 then emit("energized", { amount = amount }) end
        elseif FEEDBACK[event] then
            emit("dodged", { missType = event })
        end
        return
    end

    -- On your target (or another enemy): only harm counts.
    local counted = (plateKey and not dying) and "plates" or "target"
    local rec
    if event == "WOUND" then
        stats[counted] = stats[counted] + 1
        if hidden then
            -- Still matched, so the cast it belongs to is used up and cannot claim
            -- the next hit; it just adds nothing to the totals.
            stats.targetHidden = stats.targetHidden + 1
            rec = { school = school, hidden = true }
        elseif amount > 0 then
            rec = { amount = amount, school = school, crit = (flag == "CRITICAL") }
        elseif flag == "ABSORB" or flag == "BLOCK" or flag == "RESIST" then
            rec = { missType = flag, school = school }
        else
            -- A hit of nothing, with no flag: not a miss (a miss comes as its own
            -- event). One came in the frame of a Maul, before its swing and its 64
            -- (/gct trace, 19 Oct 2026; the meter counted Maul 64 and no other
            -- swing), and taken as a miss it used up Maul's cast, so Maul's hit was
            -- shown as Melee. Left out.
            stats[counted] = stats[counted] - 1
            note(">", "a hit of nothing: left out")
            return
        end
    elseif FEEDBACK[event] then
        stats[counted] = stats[counted] + 1
        rec = { missType = event, school = school }
    else
        return
    end
    if dying then
        rec.killed = dying
        stats.dying = (stats.dying or 0) + 1
    end
    placeOnTarget(rec, t, plateKey, plateKey and unit)
    -- the killing hit names the attack that gets the skull
    if dying and rec.key and pendingKill and pendingKill.guid == dying then
        pendingKill.hit = pendingKill.hit or rec.key
    end
end

ns.On("UNIT_COMBAT", function(_, ...) onUnitCombat(...) end)
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spell) onCast(unit, spell) end)
-- The swing's payload is recorded as it came, both arguments: which one carries
-- the swing type was taken from FCT rather than seen here.
ns.On("PLAYER_SWING", function(_, a, swingType)
    local hand = num(swingType) and hands()[swingType] or nil
    note("S", a, swingType, hand)
    onSwing(swingType)
    if hand then blow(swingKey(hand)) end
end)

-- A target that clears, in combat, at the moment of a blow of yours: a kill.
ns.On("PLAYER_TARGET_CHANGED", function()
    local guid = UnitGUID("target")
    note("T", guid)
    local t = now()
    if not str(guid) then
        if inCombat then lostTargetAt, lostGuid = t, prevTarget end
        if inCombat and prevTarget then
            local marked = {}
            -- which attack gets the skull: the killing hit, if it comes on the dying
            -- unit's plate in a moment; else the blow or bolt noted here
            local pending = { guid = prevTarget }
            pendingKill = pending
            C_Timer.After(KILL_PLATE + 0.05, function() emitKill(pending) end)
            local function kill(key)
                if marked[key] then return end
                marked[key] = true
                pending.key = pending.key or key
                kills[#kills + 1] = { guid = prevTarget, key = key, at = t }
                note("K", prevTarget, key)
            end
            if lastBlow and t - lastBlow.at <= KILL_MOMENT then kill(lastBlow.key) end
            -- a bolt of yours still in flight at it, whose hit has not come
            for _, c in ipairs(casts) do
                local window = (c.school == PHYSICAL) and PHYSICAL_WINDOW or DIRECT_WINDOW
                if not c.used and c.key == prevTarget and t - c.at <= window and c.unit == "player" then
                    kill("spell:" .. c.spell)
                end
            end
        end
        prevTarget = nil
    else
        prevTarget = guid
    end
end)

local function keyLabel(key)
    if key == "swing" then return "Melee", MELEE_ICON, PHYSICAL end
    local spell = tonumber(key:match("^spell:(%d+)$"))
    if not spell then return key, nil, nil end
    local f = factCache[spell]
    return ns.SpellName(spell) or ("Spell " .. spell), ns.SpellTexture(spell),
           (f and (f.school or f.procSchool)) or learnedSchool[spell]
end

-- A kill, once its killing hit has had its moment to come: the attack that did it,
-- for the feeds to mark. Nothing when nothing of yours was in it (the target was
-- cleared by hand).
emitKill = function(p)
    if p.done then return end
    p.done = true
    if pendingKill == p then pendingKill = nil end
    local key = p.hit or p.key
    if not key then return end
    local label, icon, school = keyLabel(key)
    note("KB", p.guid, key)
    emit("killed", { guid = p.guid, key = key, label = label, icon = icon, school = school })
end

-- Once the meter gives the fight's totals: credit each kill's missing blow.
-- Damage Dealt counting every enemy: the meter's totals for the fight are exactly
-- that feed's figures, so each of its spells is set to the meter's number once the
-- fight is over -- every hit on every enemy, killing blows included, and anything
-- the matching missed or took wrongly. Set, not added: looking again changes nothing.
local function everyEnemyDealt()
    return ns.db and ns.db.enemyText and ns.db.enemyText.scope == "all"
end

-- The meter can still hold the fight before this one when it is first read: after
-- a /reload, the first fight's read half a second after it ended gave the fight from
-- before the reload (/gct trace, 19 Oct 2026: Moonfire, Melee and Thorns, after a
-- fight of Wrath alone), and set on an every-enemy feed that showed spells never
-- cast. So the meter is read before each fight too, and a read after it that is the
-- same to the last figure is not taken: a later attempt will see this fight's.
-- Per meter: damage, and healing for Healing Done.
local lastRead, beforeFight = {}, {}   -- the meter as last read; as it read before this fight

local function readMeter(kind)
    local DM = ns.DM
    kind = kind or "damage"
    return DM and DM.Capture and DM.TYPES and DM.TYPES[kind] and DM.Capture(DM.TYPES[kind]) or nil
end

local function sameRows(a, b)
    if not (a and b) then return false end
    for key, r in pairs(a) do
        if not b[key] or b[key].amount ~= r.amount then return false end
    end
    for key in pairs(b) do
        if not a[key] then return false end
    end
    return true
end

-- Healing Done, once the fight is over: the meter's healing of yours, per spell, is
-- exactly that feed's figures -- heals on people the game did not report, overhealing
-- the live numbers may have counted, all set right. Set, not added.
local function settleHealing()
    if not (ns.db and ns.db.doneText and ns.db.doneText.enabled) then return end
    local rows = readMeter("healing")
    if not rows or sameRows(rows, beforeFight.healing) then return end
    lastRead.healing = rows
    for key, r in pairs(rows) do
        local label, icon, school = keyLabel(key)
        local total = math.floor(r.amount + 0.5)
        note(">", "settled healing", key, total)
        emit("healSettled", { key = key, label = label, icon = icon, school = school, total = total })
    end
end

local function settle(fight)
    if fight ~= fightNo or inCombat then return end
    settleHealing()
    local rows = readMeter()
    if not rows then return end   -- not released yet; a later attempt will see it
    if sameRows(rows, beforeFight.damage) then
        note(">", "the meter still shows the last fight")
        return
    end
    lastRead.damage = rows
    local all = everyEnemyDealt()
    if not all and #kills == 0 then return end
    local meter = {}
    for key, r in pairs(rows) do
        -- the meter's melee is spell 6603 (Auto Attack), or 0
        if key == "spell:6603" or key == "spell:0" then key = "swing" end
        meter[key] = (meter[key] or 0) + r.amount
    end
    if all then
        -- The meter can count a spell under another ID than the one shown live: a
        -- poison's damage is not the spell that put it on your weapon. A row the feed
        -- has that the meter lacks takes the meter's row of the same name.
        local byName = {}
        for key in pairs(tally) do
            if meter[key] == nil then
                local label = keyLabel(key)
                if label then byName[label] = key end
            end
        end
        local moves = {}
        for key in pairs(meter) do
            if tally[key] == nil then
                local label = keyLabel(key)
                if byName[label] then
                    moves[#moves + 1] = { from = key, to = byName[label] }
                    byName[label] = nil
                end
            end
        end
        for _, m in ipairs(moves) do
            meter[m.to], meter[m.from] = meter[m.from], nil
        end
        for key, total in pairs(meter) do
            local label, icon, school = keyLabel(key)
            total = math.floor(total + 0.5)
            emit("settledAll", { key = key, label = label, icon = icon, school = school, total = total })
            if tally[key] ~= total then
                note(">", "settled all", key, total, tally[key] or 0)
                stats.settled = (stats.settled or 0) + 1
                tally[key] = total
            end
        end
        return   -- one set of totals, now exact: no per-target kills to top up
    end
    local byKey = {}
    for _, k in ipairs(kills) do
        byKey[k.key] = byKey[k.key] or {}
        table.insert(byKey[k.key], k)
    end
    for key, list in pairs(byKey) do
        note("M", key, meter[key], tally[key] or 0)
        local missing = math.floor((meter[key] or 0) - (tally[key] or 0) + 0.5)
        local share = math.floor(missing / #list)
        if missing >= 1 then
            if biggest[key] and share > SETTLE_LIMIT * biggest[key] then
                if not list.refused then
                    list.refused = true
                    stats.refused = (stats.refused or 0) + 1
                    note(">", "settle refused", key, missing)
                end
            else
                local label, icon, school = keyLabel(key)
                for i, k in ipairs(list) do
                    local amount = (i == #list) and (missing - share * (#list - 1)) or share
                    if amount > 0 then
                        emit("settled", { guid = k.guid, key = key, label = label, icon = icon,
                                          school = school, amount = amount })
                        stats.settled = (stats.settled or 0) + 1
                        note(">", "settled", key, amount, k.guid)
                    end
                end
                tally[key] = (tally[key] or 0) + missing
            end
        end
    end
end

-- A /reload in the middle of a fight brings no PLAYER_REGEN_DISABLED: the fight is
-- already on. Ask the game instead, or a kill in it goes unseen (/gct trace, 18 Oct
-- 2026: a Thorns hit that killed, after a reload mid-fight, was left out).
ns.On("PLAYER_ENTERING_WORLD", function()
    inCombat = yes(UnitAffectingCombat("player")) or (InCombatLockdown and InCombatLockdown()) or false
    if not inCombat then lastRead.damage, lastRead.healing = readMeter(), readMeter("healing") end
end)

ns.On("PLAYER_REGEN_ENABLED", function()
    note("R-")
    inCombat = false
    local fight = fightNo
    for _, delay in ipairs(SETTLE_AT) do
        C_Timer.After(delay, function() settle(fight) end)
    end
end)
ns.On("PLAYER_REGEN_DISABLED", function()
    note("R+")
    inCombat = true
    fightNo = fightNo + 1
    wipe(tally); wipe(biggest); wipe(kills)
    beforeFight.damage, beforeFight.healing = lastRead.damage, lastRead.healing
    lastStats = (stats.target + stats.player > 0) and stats or lastStats
    -- The cast or swing that opened the fight came just before combat began (a
    -- bolt puts you in combat when it lands, not when it leaves your hands), and
    -- belongs to this fight's count, not the last one's.
    local opened = newStats()
    local t = now()
    local seen = {}   -- Immolate is in both lists, once
    for _, c in ipairs(casts) do if t - c.at <= DIRECT_WINDOW then seen[c.at] = true end end
    for _, d in ipairs(dots) do if t - d.from <= DIRECT_WINDOW then seen[d.from] = true end end
    for _ in pairs(seen) do opened.casts = opened.casts + 1 end
    for _, s in ipairs(swings) do if t - s.at <= RANGED_WINDOW then opened.swings = opened.swings + 1 end end
    stats = opened
end)

--------------------------------------------------------------------------
-- /gct probe
--------------------------------------------------------------------------
-- The check this port stands on: are UNIT_COMBAT amounts readable during combat
-- on this client, and how much of what hits your target is placed as yours.
-- Fight something, then run it.
function UC.PrintProbe()
    local s = (stats.target + stats.player > 0) and stats or lastStats
    local P = "|cff66ccffGCT probe|r"
    if not s then
        print(P .. ": nothing recorded yet. Fight something, then run /gct probe again.")
        return
    end
    print(P .. (s == stats and " (this fight" or " (last fight") .. ", UNIT_COMBAT):")
    local function hiddenWord(n, of)
        if of == 0 then return "none" end
        return n == 0 and "|cff40ff40none hidden|r" or ("|cffff4040" .. n .. " of " .. of .. " hidden|r")
    end
    print(("   on your target: %d reports, amounts %s"):format(s.target, hiddenWord(s.targetHidden, s.target)))
    if (s.dying or 0) > 0 then
        print(("   of them on a dying target's nameplate (a killing blow, shown live): %d"):format(s.dying))
    end
    if (s.plates or 0) > 0 then
        print(("   on other enemies' nameplates (counting every enemy): %d reports"):format(s.plates))
    end
    local placed, parts = 0, {}
    for name, n in pairs(s.rules) do
        if not name:find("heal") then placed = placed + n; parts[#parts + 1] = name .. " " .. n end
    end
    table.sort(parts)
    print(("   placed as yours: %d  (%s)"):format(placed, #parts > 0 and table.concat(parts, ", ") or "-"))
    print(("   not placed (someone else's, or unexplained): %d"):format(s.unplaced))
    print(("   on you: %d reports, amounts %s"):format(s.player, hiddenWord(s.playerHidden, s.player)))
    local hp = {}
    for _, name in ipairs({ "your heal", "your heal over time", "someone else's heal" }) do
        if s.rules[name] then hp[#hp + 1] = name .. " " .. s.rules[name] end
    end
    if #hp > 0 then print("   heals on you: " .. table.concat(hp, ", ")) end
    print(("   your casts seen: %d, swings seen: %d"):format(s.casts, s.swings))
    if (s.settled or 0) + (s.refused or 0) > 0 then
        print(("   corrected from the meter after the fight: %d%s"):format(s.settled or 0,
            (s.refused or 0) > 0 and ("  (refused, too large to be one blow: " .. s.refused .. ")") or ""))
    end
    if s.targetHidden > 0 or s.playerHidden > 0 then
        print("   |cffff4040Hidden amounts can be shown but not added up, so they are left out of")
        print("   the totals.|r If most are hidden, the post-fight summary is the better fit here.")
    end
end
