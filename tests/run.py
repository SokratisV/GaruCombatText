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
    ("UnitCombat.lua", "local SWING_WINDOW    = 1.0", "local SWING_WINDOW    = 0.5",
     "melee hits half a second after their swing go unplaced (as measured in game)"),
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
