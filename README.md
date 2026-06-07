# Garu Combat Text

A standalone World of Warcraft **TBC Classic (2.5.5)** addon for combat text:
**damage dealt (per target)** and **healing received**. Extracted from GarUI, but
fully self-contained — no dependencies.

## Features
- **Damage dealt (per target)** — the cumulative damage you deal to your current
  target, one ever-growing number/row per source (melee, each spell, wand, pet,
  totem), school-colored, with an optional combat-time header. Tracks each target
  separately and can remember their totals when you re-select them.
- **Healing received** — a per-spell meter of effective healing from any source,
  with a rolling out-of-combat window. The value shown can be **healing**,
  **healing/mana**, **both**, or **mana only**.
- **Combat timer** — an optional "Combat M:SS" readout for your current target,
  enabled/disabled on its own and positioned freely or anchored to either feed.
- **Freeform** — each feed has its own movable anchor point. Position it anywhere
  (unlock and drag the marker), set its text alignment and grow direction, or
  optionally **pin** it to the Player / Target / Focus frame. Not tied to any frame.
- Its own saved settings; no other addons required.

## Install
Extract the `GaruCombatText` folder into:
`World of Warcraft/<version>/Interface/AddOns/`
Then enable **Garu Combat Text** at the character-select AddOns screen.

## Usage
- `/gcf` (or `/combatfeed`) — open the settings panel
- `/gcf unlock` / `/gcf lock` — show/hide the draggable anchor boxes
- `/gcf test` — toggle a live preview
- `/gcf reset` — restore default settings

## License
All rights reserved unless stated otherwise by the author.
