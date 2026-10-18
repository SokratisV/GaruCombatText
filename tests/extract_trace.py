"""Turn a /gct trace recording into a replayable fight for tests/fights/.

    python -I tests/extract_trace.py <WTF/.../SavedVariables/GaruCombatText.lua> tests/fights/<date>-<what>.txt "what it was" ...

Record in game first: /gct trace, fight, /reload (the game writes saved variables
to disk on a reload or logout). Each extra argument becomes a "# " header line;
add "# expect-unplaced: N" by hand when N hits really were someone else's.
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
start = src.index('["trace"]')
block = src[start:]
block = block[block.index('["lines"]'):]
block = block[:block.index("},")]
lines = []
for m in re.finditer(r'^"((?:[^"\\]|\\.)*)",\s*$', block, re.M):
    lines.append(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
    for h in sys.argv[3:]:
        f.write("# " + h + "\n")
    f.write("\n".join(lines) + "\n")
print(len(lines), "lines")
