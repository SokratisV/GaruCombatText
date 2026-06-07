# Garu Combat Text

**Standalone combat text for World of Warcraft (TBC Classic / Anniversary): damage you deal, per target, and healing you receive.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Version](https://img.shields.io/badge/version-1.1-brightgreen)
![WoW](https://img.shields.io/badge/WoW-TBC%20Classic%20%2F%20Anniversary-f8b700)
![Interface](https://img.shields.io/badge/interface-20505-555)

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
  school-colored, with an optional combat-time header. Tracks each target separately and can
  remember their totals when you re-select them.
- 🛡️ **Damage taken (per enemy)** — the cumulative damage you take this fight, one row per
  source enemy (or environment), school-colored.
- 💚 **Healing received** — a per-spell meter of effective healing from any source, with a
  rolling out-of-combat window. The value shown can be **healing**, **both**, or **mana only**.
- ⏱️ **Combat timer** — an optional "Combat M:SS" readout for your current target, toggled on
  its own and positioned freely or anchored to either feed.
- 🪧 **Freeform anchors** — each feed has its own movable anchor. Unlock and drag the marker
  anywhere, set its text alignment and grow direction, or optionally **pin** it to the
  Player or Target frame.
- 🪶 **Lightweight & standalone** — its own saved settings; no dependencies.

## Usage

| Command | What it does |
|---|---|
| `/gct` (or `/garucombattext`) | Open the settings panel. |
| `/gct unlock` / `/gct lock` | Show / hide the draggable anchor boxes. |
| `/gct test` | Toggle a live preview. |
| `/gct reset` | Restore default settings. |

## License

[MIT](LICENSE).
