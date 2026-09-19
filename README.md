# Garu Combat Text

**Damage you deal and take, and healing you receive, broken down per spell.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![Version](https://img.shields.io/badge/version-2.1.0-brightgreen)
![WoW](https://img.shields.io/badge/WoW-Forever%20%2F%20TBC%20Classic-f8b700)
![Interface](https://img.shields.io/badge/interface-16001%20%7C%2020505-555)

## On WoW Forever: a post-fight summary

Midnight removed the addon combat log and replaced it with `C_DamageMeter`, which reports
per-fight aggregates rather than individual hits -- and this client withholds even those
while a fight is in progress, releasing them only once it ends. Measured: out of combat
the totals read normally; from the first moment of combat every one is unreadable until
combat drops.

Live combat text is therefore not possible on Forever. The feeds instead clear when a
fight starts and fill with that fight's figures when it ends, staying put until the next
one. The rolling-window and fade-timing settings are hidden there, because a summary has
nothing to roll or fade.

Also unavailable on Forever, for want of any field carrying them: per-hit crits, spell
schools, mana spent, and the whole **Actions** feed (dodge/parry/miss counts are
combat-log facts, and this API reports damage, not misses).

On the Classic clients nothing changes: the combat log is still there and every feed
works live, exactly as before.

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
  school-colored, with an optional combat-time header. Tracks each target separately and can
  remember their totals when you re-select them.
- 🛡️ **Damage taken (by type)** — the cumulative damage you take this fight from **all
  enemies combined, grouped by attack type** (all melee together, each incoming spell, each
  environmental type), school-colored. Optionally also counts your **misses & avoids** —
  dodge / parry / block / miss / absorb / resist — as their own "Dodge ×4" rows.
- 🎯 **Actions (per target)** — how many of *your* attacks the current target avoided this
  fight — dodge / parry / block / miss / resist / immune — as count rows. Tracks each target
  separately like Damage Dealt.
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
| `/gct reset` | Restore default settings. |

## License

[MIT](LICENSE).
