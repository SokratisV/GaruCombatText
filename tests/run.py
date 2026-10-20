"""Garu Combat Text's offline checks, run in a real Lua (LuaJIT, through lupa).

    python -I tests/run.py            all checks
    python -I tests/run.py -v         ...and show each suite's output

First time only, install the Lua runtime next to this file (it is gitignored):

    python -m pip install --target tests/.lupa lupa

What runs:
  syntax    every .lua file compiles under Lua 5.1 rules, as WoW's do
  engine    engine_test.lua replays scripted fights through UnitCombat.lua
  replay    each fight in fights/, recorded in game with /gct trace, goes through
            the current UnitCombat.lua; every hit on the target must be placed
            (unless the file says "# expect-unplaced: N")
  load      load_test.lua loads the whole addon in TOC order against a stubbed
            WoW API, drives a fight through the real event handlers and checks
            what reaches each feed's meter, and works every control in the
            settings window; as WoW Forever, as Classic, and as a bare client
            without Blizzard's newer templates, so the window's fallbacks run too
  mutants   each entry in MUTANTS breaks the addon on purpose, and the suites must
            then fail. A mutant that survives means a test can no longer catch the
            thing it was written for, so the run fails.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, ".lupa"))
try:
    import lupa.luajit21 as lj
except ImportError:
    print("The Lua runtime is missing. Install it once with:")
    print("    python -m pip install --target tests/.lupa lupa")
    sys.exit(2)

VERBOSE = "-v" in sys.argv[1:]

# file, text to find, what to put instead, and what the tests must notice.
MUTANTS = [
    ("UnitCombat.lua", "local RHYTHM_SLACK    = 0.35", "local RHYTHM_SLACK    = -1",
     "a DoT tick beside a bolt in flight swaps the two"),
    ("UnitCombat.lua", "if not c.used and c.key == key and", "if not c.used and",
     "a bolt cast at one mob claims a hit on the next"),
    ("UnitCombat.lua", "if f.ticks and not f.direct then f.direct = false end", "",
     "a DoT cast takes the hit of the bolt cast after it"),
    ("UnitCombat.lua", "rec.spell, rec.first = spell, not cast.mana", "rec.spell, rec.first = spell, true",
     "a heal's mana is counted on every tick"),
    ("UnitCombat.lua", "local SWING_WINDOW    = 1.35", "local SWING_WINDOW    = 0.5",
     "melee hits half a second after their swing go unplaced (as measured in game)"),
    ("UnitCombat.lua", "local SWING_WINDOW    = 1.35", "local SWING_WINDOW    = 1.0",
     "a swing's hit held back one more animation goes unplaced"),
    ("UnitCombat.lua", "local KILL_PLATE   = 0.5", "local KILL_PLATE   = -1",
     "a killing bolt on the dying unit's nameplate is dropped"),
    ("UnitCombat.lua", 'kill("spell:" .. c.spell)', "local _ = c",
     "a killing bolt with no plate to land on is never settled"),
    ("UnitCombat.lua", "dying, plateKey = lostGuid, lostGuid", "local _ = lostGuid",
     "a killing bolt reported on target after the target cleared goes unplaced"),
    ("UnitCombat.lua", "if d and d.unit ~= unit and", "if false and",
     "a killing bolt reported on its plate and on target is counted twice"),
    ("UnitCombat.lua", "if sameRows(rows, beforeFight.damage) then", "if false then",
     "after a /reload, the meter's fight from before it is taken for this one"),
    ("UnitCombat.lua", 'elseif flag == "ABSORB" or flag == "BLOCK" or flag == "RESIST" then', "elseif true then",
     "a hit of nothing in Maul's frame is a miss, and Maul's hit is shown as Melee"),
    ("UnitCombat.lua", "if fresh and s.school == school and", "if fresh and",
     "a weapon proc takes hits of any school"),
    ("UnitCombat.lua", "local PROC_MOMENT = 0.25", "local PROC_MOMENT = 5",
     "a weapon proc takes hits far from any swing"),
    ("UnitCombat.lua", "and not m.procs[src.spell] then", "then",
     "one swing carries any number of procs"),
    ("UnitCombat.lua", "if coated == false then fresh = false end", "",
     "a poison counts on after it is gone from the weapon"),
    ("UnitCombat.lua", "            procSources().seal = nil\n", "",
     "Seal of the Crusader leaves the seal before it counting"),
    ('UnitCombat.lua', 'schoolAtOnce(lower:match("^(.-)unleash") or lower)', "schoolAtOnce(lower)",
     "a seal that deals nothing takes the Judgement's school"),
    ("UnitCombat.lua", "meter[m.to], meter[m.from] = meter[m.from], nil", "local _ = m",
     "counting every enemy, a poison is shown twice after the fight"),
    ("Meter.lua", "if cfg.roll and not t.isCount then", "if false then",
     "rolling totals jump straight to the new value"),
    ("Meter.lua", "if cfg.splash and not t.isCount and amount and amount > 0 then spawnSplash(M, s, t, amount, crit) end", "",
     "hits stop splashing off their rows"),
    ("Meter.lua", 'if cfg.splashSide == "LEFT" or cfg.splashSide == "RIGHT" then return cfg.splashSide end', "",
     "Splash side is ignored"),
    ("Meter.lua", 'local function horizontal(cfg) return cfg.layout ~= "radial" and cfg.stackDir == "horizontal" end',
     "local function horizontal(cfg) return false end", "a horizontal stack still runs one under another"),
    ("Meter.lua", 'if align == "RIGHT" then x = -(cursor + after) else x = cursor + before end',
     "x = cursor + before", "a horizontal stack cannot grow left"),
    ("Meter.lua", 'if key:sub(1, 6) == "avoid:" then return "good" end', 'if key:sub(1, 6) == "avoid:" then return "bad" end',
     "your own dodges are drawn red, like the ones made against you"),
    ("ActionsText.lua", "if everyEnemy() or UnitExists(\"target\") then youAvoided(r.missType) end", "",
     "on Forever, the attacks you avoided never reach Actions"),
    ("ActionsText.lua", "            youAvoided(m)\n", "",
     "on Classic, the attacks you avoided never reach Actions"),
    ("UnitCombat.lua", "healDone(spell, amount, school, crit, me)", "local _ = me",
     "your heals on yourself never reach Healing Done"),
    ("UnitCombat.lua", "if d and d.guid == guid and d.amount == amount and t - d.at <= 0.05 then", "if false then",
     "a heal reported on your target and its plate is counted twice"),
    ("UnitCombat.lua", 'if str(t) and yes(UnitExists("target")) and not yes(UnitCanAttack("player", "target"))',
     'if false and str(t) and yes(UnitExists("target")) and not yes(UnitCanAttack("player", "target"))',
     "every heal is taken as cast on you, never on your target"),
    ("UnitCombat.lua", "if not (ns.db and ns.db.doneText and ns.db.doneText.enabled) then return end", "do return end",
     "Healing Done is never set to the meter's after the fight"),
    ("Meter.lua", 'if cfg.growthH == "CENTER" then x = x - lastLineW / 2 end', "",
     "a centred horizontal line runs right from the anchor instead"),
    ("Meter.lua", "if flourish then t.flashT = 0 end", "",
     "a crit no longer flourishes"),
    ("Meter.lua", "t.pop, t.popLen = (cfg.pop ~= false) and 1.45 or 1, POP_LEN", "t.pop, t.popLen = 1.45, POP_LEN",
     "Pop on each hit cannot be turned off"),
    ("Meter.lua", "t.pop, t.popLen = 2.4, CRIT_POP_LEN", "t.pop, t.popLen = 1.45, POP_LEN",
     "a crit jumps no further than any other hit"),
    ("Meter.lua", "if not (cfg.killMark and (t.kills or 0) > 0) then", "if true then",
     "the killing blow's skull is never drawn"),
    ("Meter.lua", "t.kills, t.killT, t.flashT = kills and kills[key] or 0, nil, nil", "t.kills, t.killT, t.flashT = 0, nil, nil",
     "a corpse selected again loses its skull"),
    ("UnitCombat.lua", "local key = p.hit or p.key", "local key = p.key",
     "the skull goes on a blow in the moment, not the hit that killed"),
    ("EnemyText.lua", "meter:MarkKill(frame, (not everyEnemy()) and r.guid or nil, r.key)", "local _ = r",
     "a kill never reaches Damage Dealt's rows"),
    ("EnemyText.lua", 'if sub == "PARTY_KILL" then', "if false then",
     "on Classic, a killing blow is never marked"),
    ("Options.lua", "scale = math.min(1, w / needW, h / needH)", "scale = 1",
     "the settings preview overflows its box"),
    ("EnemyText.lua", "meter:BumpGUID(frame, r.killed, r.key, r.label, r.amount, r.school, r.crit and true or false, r.icon)",
     "local _ = r", "a killing bolt on the dying unit's plate never reaches Damage Dealt"),
    ("UnitCombat.lua", "local KILL_MOMENT  = 0.1", "local KILL_MOMENT  = -1",
     "a killing blow, never reported, is never settled from the meter"),
    ("UnitCombat.lua", "local SETTLE_LIMIT = 3 ", "local SETTLE_LIMIT = 1e9 ",
     "other mobs' damage is credited to the one that died"),
    ("EnemyText.lua", "meter:BumpGUID(frame, r.guid, r.key, r.label, r.amount, r.school, false, r.icon)",
     "local _ = r", "a settled killing blow never reaches Damage Dealt"),
    ("Options.lua", "set = function(v) ns.db[db][field] = v; if apply then apply() end end }, extra)",
     "set = function(v) end }, extra)", "a checkbox in the settings stops saving"),
    ("Options.lua", "if not row.vis or row.vis() then out[#out + 1] = row end", "out[#out + 1] = row",
     "settings that do not apply are shown anyway"),
    ("Options.lua", "if label:lower():find(needle, 1, true) then hits[#hits + 1] = row end",
     "hits[#hits + 1] = row", "search shows every setting, whatever is typed"),
    ("Options.lua", 'cardText = val(p.title) .. " is off."', "cardText = nil",
     "a feed that is off still shows all its settings"),
    ("Options.lua", "for _, k in ipairs(LOOK) do dst[k] = src[k] end", "",
     "Copy to copies nothing"),
    ("Options.lua", "    if position then\n        local x", "    if true then\n        local x",
     "Copy to moves feeds without being asked"),
    ("Anchors.lua", "    if ns.RefreshOptions then ns.RefreshOptions() end\nend",
     "    if ns.RefreshOptions then ns.RefreshOptions() end\n    print(\"anchors\")\nend",
     "unlocking the anchors from the window writes to chat"),
    ("UnitCombat.lua", "elseif not wantAll() then", "elseif true then",
     "counting every enemy never sees other enemies' nameplates"),
    ("UnitCombat.lua", 'if yes(UnitIsUnit(unit, "target")) then return end', "",
     "a hit on your target is counted twice, once from its own nameplate"),
    ("UnitCombat.lua", "if not s.used and s.key == key and", "if not s.used and",
     "a swing at your target takes a hit on another enemy"),
    ("UnitCombat.lua", "if c.area and not c.hits[key]", "if false and c.area and not c.hits[key]",
     "an area spell is counted on one enemy only"),
    ("UnitCombat.lua", 'emit("settledAll", {', 'local _ = ({',
     "every-enemy totals are never set to the meter's after the fight"),
    ("Meter.lua", "            fresh = false\n            M:Clear()", "            fresh = false",
     "every-enemy totals never start again on the next fight"),
    ("Meter.lua", "if s.guid ~= key then switchGUID(M, s, key) end", "switchGUID(M, s, key)",
     "changing target wipes the every-enemy totals"),
    ("EnemyText.lua", "        return ns.frames.target\n    end\n    local onFocus", "        return nil\n    end\n    local onFocus",
     "on Classic, counting every enemy still only counts your target"),
    ("UnitCombat.lua", 'emit("avoided", { missType = rec.missType, pet = rec.pet, onTarget = rec.onTarget })',
     'emit("avoided", { missType = rec.missType, pet = rec.pet })',
     "another enemy's dodge counts as your target's in a per-target Actions feed"),
    ("UnitCombat.lua", "    if shield then\n        if t - hitOnMeAt", "    if false then\n        if t - hitOnMeAt",
     "Thorns damage is never counted"),
    ("UnitCombat.lua", "if h.shield and not h.done and t - h.at <= SHIELD_WAIT then", "if false then",
     "Thorns reported before the blow that set it off is lost"),
    ("UnitCombat.lua", "local SHIELD_WAIT  = 0.6", "local SHIELD_WAIT  = 0.15",
     "Thorns waits too briefly for its blow, which comes 0.30-0.36 s later"),
    ("UnitCombat.lua", "if fighting then for school, spell in pairs(shields) do kept[school] = spell end end", "",
     "Thorns is forgotten when the buffs go hidden in combat"),
    ("UnitCombat.lua", "            if not auraSecret(index) then\n",
     "            if auraSecret(index) then break end\n            do\n",
     "a hidden buff ends the search, as in the first version"),
    ("UnitCombat.lua", "if h.target and math.abs(lostTargetAt - h.at) <= 0.1 then", "if false then",
     "a Thorns hit that kills is lost"),
    ("UnitCombat.lua", 'inCombat = yes(UnitAffectingCombat("player")) or (InCombatLockdown and InCombatLockdown()) or false',
     "inCombat = false", "after a /reload mid-fight, its kills go unseen"),
    ("UnitCombat.lua", "            local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spell)",
     "            local ok, aura = false, nil", "Thorns is not asked for by spell"),
    ("UnitCombat.lua", 'return not str(src) or src == "player"', "return true",
     "another druid's Thorns on you is counted as yours"),
    ("UnitCombat.lua", "if landed and (school == nil or school == PHYSICAL) then", "if landed then",
     "a spell hitting you sets off Thorns"),
    ("UnitCombat.lua", "do SHIELD_IDS[id] = 8 end            -- Thorns", "do end            -- Thorns",
     "Thorns is only known when its description loads"),
    ("EnemyText.lua", '        or sub == "DAMAGE_SHIELD" then   -- Thorns', '        or false then   -- Thorns',
     "on Classic, Thorns damage is not counted"),
    ("UnitCombat.lua", "ns.CombatLogLive = (C_DamageMeter == nil)", "ns.CombatLogLive = true",
     "Forever is taken for a client with a combat log"),
    ("EnemyText.lua", "meter:Bump(frame, r.key, r.label, r.amount, r.school, r.crit and true or false, r.icon)",
     "local _ = r", "Damage Dealt stops drawing what it is told"),
    ("TakenText.lua", 'local key = "school:" .. tostring(r.school or 0)', 'local key = "school:0"',
     "Damage Taken loses its schools"),
]


def toc_files():
    with open(os.path.join(ROOT, "GaruCombatText.toc"), encoding="utf-8") as f:
        return [l.strip() for l in f if l.strip() and not l.startswith("#")]


def sources(mutant=None):
    files = {}
    for name in toc_files():
        with open(os.path.join(ROOT, name), encoding="utf-8") as f:
            files[name] = f.read()
    if mutant:
        name, find, replace = mutant[0], mutant[1], mutant[2]
        if find not in files[name]:
            raise SystemExit("mutant no longer applies (text not found in %s): %s" % (name, find))
        files[name] = files[name].replace(find, replace, 1)
    return files


def test_source(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as f:
        return f.read()


def run_lua(test, **globals_):
    """Run a test script in a fresh runtime. Returns (ok, output lines)."""
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    out = []
    g = L.globals()
    g.print = lambda *a: out.append("\t".join("nil" if x is None else str(x) for x in a))
    for key, value in globals_.items():
        if isinstance(value, dict):
            value = L.table_from(value)
        elif isinstance(value, list):
            value = L.table_from(value)
        g[key] = value
    runner = L.eval("""function(src)
        local f, err = loadstring(src, '@test')
        if not f then return 'load: ' .. tostring(err) end
        local ok, e = pcall(f)
        if not ok then return tostring(e) end
        return nil
    end""")
    err = runner(test)
    if err is not None and err != "failures" and not str(err).endswith("failures"):
        out.append("ERROR " + str(err))
    return err is None, out


def syntax(files):
    L = lj.LuaRuntime(unpack_returned_tuples=True)
    load = L.eval("function(src, name) local f, err = loadstring(src, '@' .. name); return f ~= nil, err end")
    bad = []
    for name, src in files.items():
        ok, err = load(src, name)
        if not ok:
            bad.append("%s: %s" % (name, err))
    return bad


def suites(files):
    """Every suite against these sources: list of (name, ok, output)."""
    results = []
    bad = syntax(files)
    results.append(("syntax", not bad, bad))
    if bad:
        return results
    ok, out = run_lua(test_source("engine_test.lua"), UC_SRC=files["UnitCombat.lua"])
    results.append(("engine", ok, out))
    fights = os.path.join(HERE, "fights")
    for name in sorted(os.listdir(fights)) if os.path.isdir(fights) else []:
        if name.endswith(".txt"):
            with open(os.path.join(fights, name), encoding="utf-8") as f:
                fight = f.read()
            ok, out = run_lua(test_source("replay_test.lua"), UC_SRC=files["UnitCombat.lua"], FIGHT=fight)
            results.append(("replay " + name[:-4], ok, out))
    order = toc_files()
    for client in ("forever", "classic", "bare"):
        ok, out = run_lua(test_source("load_test.lua"), ORDER=order, FILES=files,
                          FOREVER=(client == "forever"), BARE=(client == "bare"))
        results.append(("load " + client, ok, out))
    return results


def summary_line(out):
    for line in reversed(out):
        if "passed" in line:
            return line.strip()
    return out[-1] if out else ""


def main():
    failed = False
    for name, ok, out in suites(sources()):
        if name == "syntax":
            print("%-14s %s" % (name, "%d files compile" % len(toc_files()) if ok else "FAILED"))
        else:
            print("%-14s %s" % (name, summary_line(out)))
        if VERBOSE or not ok:
            for line in out:
                if VERBOSE or "FAIL" in line or "ERROR" in line:
                    print("    " + line)
        failed = failed or not ok
    if failed:
        print("\nFix the failures above before trusting the mutant check.")
        return 1

    survivors = []
    for mutant in MUTANTS:
        if all(ok for _, ok, _ in suites(sources(mutant))):
            survivors.append(mutant)
    print("%-14s %d of %d caught" % ("mutants", len(MUTANTS) - len(survivors), len(MUTANTS)))
    for m in survivors:
        print("    SURVIVED: %s (%s)" % (m[3], m[0]))
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
