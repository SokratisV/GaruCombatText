# Garu Combat Text

**Damage you deal and take, and healing you receive, broken down per spell.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Version](https://img.shields.io/badge/version-2.2.0-brightgreen)
![WoW](https://img.shields.io/badge/WoW-Forever%20%2F%20TBC%20Classic-f8b700)
![Interface](https://img.shields.io/badge/interface-16001%20%7C%2020505-555)

## On WoW Forever: live, worked out from your own actions

Midnight removed the addon combat log (`COMBAT_LOG_EVENT_UNFILTERED` registers and never
fires), and `C_DamageMeter` hides every figure until a fight is over. What the client still
sends live is `UNIT_COMBAT`, the event Blizzard's own portrait hit-numbers use: each hit on
a unit with its amount, school, crit flag or kind of miss, but never who made it or with
which spell.

So on Forever the feeds are live again, with one difference that matters: **your hits are
worked out, not read.** Your casts (with their spell) and your weapon swings are readable,
and each hit on your target is matched to them by timing and school, helped by what each
spell's own description says it does.

- **Damage Dealt** is per spell again, with crits, schools and mana spent. Counting every
  enemy (the default), it also reads other enemies' nameplates (so enemy nameplates need to
  be shown), and once the fight ends its numbers are set to Blizzard's damage meter's, so
  they end exact.
- **Killing blows** count. A bolt that kills is reported on the dying enemy's nameplate just
  after your target clears, and is taken from there; a killing swing is never reported, and
  is filled in from Blizzard's damage meter once the fight is over.
- **Weapon procs** go on their own line: a seal, poison, oil, weapon enchant or shaman
  imbue you applied, matched to the hits of its school that land as you swing. Not yet
  checked in game; a paladin's, rogue's or shaman's `/gct trace` would settle it.
- **Actions** is back: your target's dodges, parries and resists, matched to your swings
  and casts.
- **Damage Taken** is grouped **by school** (Physical, Fire, ...): the game says how you
  were hit, not by what.
- **Healing Received** counts every heal on you. Your own are on their spell; everyone
  else's share one *Healing* line.

Solo the matching is close to exact, because almost everything hitting your target is you.
In a group, a teammate's hit of the same school landing inside your window can be counted as
yours. `/gct probe` after a fight shows how many hits came through readable and how each was
placed.

The approach and its timing windows come from **Forever Combat Text** by Tarolg
(MIT License, Copyright (c) 2026 Tarolg), which measured them in real fights.

On the Classic clients nothing changes: the combat log is still there and every feed reads
it directly, exactly as before.

> **Client support.** Runs on **WoW Forever** (interface `16001`) and on the
> **TBC Classic / Anniversary** client (interface `20505`) from the same files.
> Forever serves Classic content from the Midnight 12.x client, so it reports a
> Classic project id but only exposes the modern namespaced API — every call that
> moved is feature-detected rather than switched on project id.

A focused, dependency-free combat-text addon: running tallies of the **damage you deal to
your current target**, the **damage you take** (per enemy), and the **healing you receive**
(per spell). It's completely standalone — no other addons required.

<!--
Screenshots: drop images into docs/ and reference them here, e.g.
![Damage & healing feeds](docs/feeds.png)
-->

## Features

- ⚔️ **Damage dealt (per target)** — the cumulative damage you deal to your current target,
  one ever-growing number/row per source (melee, each spell, wand, pet, totem),
  school-colored, with an optional combat-time header. By default (**Count: Every enemy**)
  it adds up everything you hit as one set of totals for the fight; with **Count: Your
  target** it tracks each target separately and can remember their totals when you re-select
  them (Actions has the same choice).
- 🛡️ **Damage taken (by type)** — the cumulative damage you take this fight from **all
  enemies combined, grouped by attack type** (all melee together, each incoming spell, each
  environmental type), school-colored.
- 🎯 **Actions** — the attacks avoided this fight, both ways, as count rows: in red, *your*
  attacks your target (or every enemy) dodged, parried, blocked or resisted; in green, the
  attacks on you that you dodged, parried or blocked, and the ones that missed you.
- 💚 **Healing received** — a per-spell meter of effective healing from any source, with a
  rolling out-of-combat window. The value shown can be **healing**, **both**, or **mana only**.
- ⏱️ **Combat timer** — an optional "Combat M:SS" readout for your current target, toggled on
  its own and positioned freely or anchored to either feed.
- 🪧 **Freeform anchors** — each feed has its own movable anchor. Unlock and drag the marker
  anywhere, set its text alignment and grow direction, or optionally **pin** it to the
  Player or Target frame.
- 🌀 **Stacked or radial** — show each feed as a vertical line **or** a configurable **arc**
  (radius, span in degrees, and which way it faces).
- 🪶 **Lightweight & standalone** — its own saved settings; no dependencies.

## Usage

| Command | What it does |
|---|---|
| `/gct` (or `/garucombattext`) | Open the settings panel. |
| `/gct unlock` / `/gct lock` | Show / hide the draggable anchor boxes. |
| `/gct test` | Toggle a live preview. |
| `/gct status` | Which data source is feeding the addon, and the summary's hold window. |
| `/gct probe` | After a fight on Forever: how many hits came through readable, and how each was placed. |
| `/gct trace` | Forever: start/stop recording every cast, swing and hit into the saved settings (written to disk on `/reload`). |
| `/gct reset` | Restore default settings. |

## Tests

Offline checks, in a real Lua runtime: every file compiles, scripted fights go
through the WoW Forever matcher, and the whole addon loads against a stubbed game
and is checked feed by feed, as Forever and as Classic. Each run also breaks the
addon on purpose a few ways and fails if the tests stop noticing.

```bash
python -m pip install --target tests/.lupa lupa
python -I tests/run.py
```

## License

[MIT](LICENSE).
