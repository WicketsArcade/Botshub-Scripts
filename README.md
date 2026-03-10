# SmartVanquisher

**Version:** 1.1.0  
**Author:** Wicket  
**Framework:** [BotsHub](https://github.com/caustic-kronos/BotsHub) by caustic-kronos  
**Language:** AutoIt (.au3)  
**Game:** Guild Wars 1

---

## Overview

A fully map-agnostic vanquisher and cartography bot for Guild Wars 1. No map IDs, outpost IDs, or hardcoded coordinates — everything is detected at runtime from the player's current context.

The movement algorithm is inspired by a Roomba vacuum cleaner: walk straight until blocked, pick a new heading biased toward unexplored areas, repeat until the zone is fully vanquished.

---

## Features

- **Zero configuration** — start from inside any explorable zone and the bot figures out everything else
- **Bounce Roomba algorithm** — systematic area coverage without needing predefined waypoints
- **Smart heading selection** — scores 6 candidate angles by unvisited cell lookahead, always drifts toward unexplored areas
- **Direction poisoning** — blocked headings have their lookahead cells marked visited so the same wall is never retried
- **Portal safety** — checks 4 intermediate points along every proposed step; raises exclusion zone to full earshot range (~1000 units) so no step can overshoot into an exit portal
- **Entry portal exclusion** — the portal you entered through is ignored during navigation so the bot never deflects from its own spawn
- **Combat interrupt** — movement stops when foes are detected within ~1500 units; resumes to the saved waypoint after the fight
- **Loot pickup** — `PickUpItems()` called after each encounter using your BotsHub loot configuration
- **Fast wall detection** — custom `SV_MoveTo` gives up after 4 consecutive blocked ticks (~400ms) instead of `MoveTo`'s default 14 (~45s)
- **Second-run support** — if started from an outpost after a previous run, automatically re-enters the last zone

---

## Requirements

- **BotsHub 2.0** installed and configured
- Character inside an explorable zone before pressing Start
- Hero team capable of clearing Hard Mode content
- Your own skill bars loaded — the bot does **not** set builds
- Hard Mode enabled manually before entering the zone
- A loot configuration JSON in `conf/loot/` (otherwise `DefaultShouldPickItem` picks up everything)

---

## Installation

**1. Copy the bot file**
```
src/vanquishes/SmartVanquisher.au3
```

**2. Register in `BotsHub.au3`**

Add the include near the top with the other vanquish includes:
```autoit
#include 'src/vanquishes/SmartVanquisher.au3'
```

Add to the `$AVAILABLE_FARMS` string (exact name must match):
```autoit
'...|Smart Vanquisher'
```

Add to `FillFarmMap()`:
```autoit
AddFarmToFarmMap('Smart Vanquisher', SmartVanquisherFarm, 5, 120 * 60 * 1000)
```

---

## How to Use

1. Enter any explorable zone manually
2. Select **Smart Vanquisher** in the BotsHub GUI
3. Press **Start**

The bot reads map ID, outpost ID, entry position, and entry portal automatically. On completion it returns to the controlling outpost (or falls back to `/resign` if `controlled_outpost_ID` is unavailable).

---

## Algorithm Details

### Bounce Roomba

```
1. Compute initial heading away from the entry portal (into the zone)
2. Walk straight in 1000-unit steps (SV_BOUNCE_STEP)
3. On each step, check 4 intermediate points for portal proximity
4. If SV_MoveTo returns False (wall hit after ~400ms):
     a. Poison the blocked direction (mark 5 lookahead cells as visited)
     b. Score 6 candidate headings (±45°, ±90°, ±135° relative to blocked)
     c. Pick highest-scoring heading (most unvisited cells ahead)
5. If no new cells visited in 15 consecutive steps: force a bounce
6. Exit when GetAreaVanquished() returns True
```

### Combat

```
1. Before each step, CountFoesInRangeOfAgent at ~1500 units
2. Mid-step: check every sub-step — save waypoint and stop immediately if foes appear
3. Fight: skills 1-8 in order, wait for each cast, skip if on cooldown
4. Loot within ~1500 units using your configured loot filter
5. Resume to saved waypoint
```

### Portal Safety (three layers)

| Layer | Mechanism |
|---|---|
| Pre-move check | `SV_DirectionOpen` rejects headings where any of 4 intermediate points is within ~1000 units of a portal |
| Bounce scoring | `SV_PickBounceHeading` calls `SV_DirectionOpen` on all candidates — portal-adjacent directions can never be selected |
| Entry exclusion | `SV_GetPortalAgents` strips the spawn portal so the bot never avoids its own entry point |

---

## Tuning Constants

| Constant | Default | Description |
|---|---|---|
| `$SV_BOUNCE_STEP` | ~1000 | Step distance per move |
| `$SV_AGGRO_RANGE` | ~1500 | Range to detect and engage foes |
| `$SV_BOUNCE_CELL_SIZE` | ~1000 | Grid cell size for coverage tracking |
| `$SV_PORTAL_SAFE_DIST` | ~1000 | Minimum clearance from any portal |
| `$SV_FARM_DURATION` | 120 min | Hard timeout before giving up |
| `$SV_POST_COMBAT_WAIT` | 800ms | Pause after each encounter |

---

## Known Limitations

- Coverage is **probabilistic**, not guaranteed. Complex zones with tight corridors or isolated rooms may take longer or leave small gaps — the bot keeps running until `GetAreaVanquished()` is true regardless.
- `controlled_outpost_ID` returns 0 for some zones (e.g. map 98). The bot falls back to `/resign` + `ReturnToOutpost()` which works but drops you to the nearest available outpost rather than the zone's home outpost.
- Loot is only picked up within `$SV_AGGRO_RANGE` of each fight. Items dropped at range (e.g. from AoE kills while moving) may be missed.

---

## Changelog

### v1.1.0
- **Hard Mode guard:** `GetIsHardMode()` is now checked at the start of every run. If Hard Mode is not active, the bot pauses immediately with a clear error — in Normal Mode `GetAreaVanquished()` always returns True so the bot would exit in ~4 seconds and loop endlessly

### v1.0.9
- **Success now pauses:** `Return $SUCCESS` replaced with `SV_ClearState()` + `Return $PAUSE` — a completed vanquish stops and waits, it never loops into a second run automatically
- **Already-vanquished guard:** `GetAreaVanquished()` is now checked at the very start of `SV_Run()` before bouncing begins. If the zone is already clear (e.g. re-entering a previously vanquished zone), the bot pauses with a warning instead of silently "succeeding" in 4 seconds and looping

### v1.0.8
- **No automatic retry on failure:** All failure paths now return `$PAUSE` to BotsHub instead of `$FAIL`. The bot stops in the outpost and waits for you to manually press Start. A vanquish needs a deliberate restart from the correct outpost and position — blind retries don't make sense
- **`SV_ClearState()`:** Called on any pause/failure. Resets `$sv_map_id` to -1 so the next Start always re-captures zone context fresh, rather than assuming you're still in the same zone
- **`Return $PAUSE` on zone entry failure:** If `SV_EnterZoneFromOutpost()` can't get back into the zone, the bot pauses with a clear message instead of looping
- **Guard on resign:** Added `If GetMapType() = $ID_EXPLORABLE` check before the post-run resign, so we don't try to resign if we're already in an outpost

### v1.0.7
- **Portal learning system:** When the bot accidentally walks into a portal, it records the last safe position in `conf/portals/<mapID>.json`. On every subsequent run in that zone, those positions are loaded as hard exclusion zones with a ~2000 unit radius. Each map only needs to be learned once — the knowledge persists across sessions and builds up automatically
- **`SV_LoadDangerZones()`:** Reads the per-map JSON file on zone entry and populates the runtime `$sv_danger_zones` array (up to 64 zones per map)
- **`SV_LearnDangerZone(x, y)`:** Called on any accidental portal entry with the last known safe coordinates. Deduplicates against existing zones (within 500 units) before saving, so the same portal doesn't get recorded multiple times
- **`SV_DirectionOpen()`** and **`SV_NearAnyPortal()`** both now check against learned danger zones in addition to the signpost-based portal list
- **`$lastSafeX/$lastSafeY`** tracking added to the sub-step loop — always holds the last confirmed in-zone position so the learned coordinate is accurate even when zoning happens mid-step

### v1.0.6
- **Portal re-entry fix (hard):** After every `SV_MoveTo` call, `GetMapID()` is now checked against `$sv_map_id`. If we accidentally walked into a portal, the bot immediately detects the zone change, logs a warning, resigns, and returns to the outpost — rather than continuing to run in the wrong zone or crashing
- **Mid-step zone check:** A second `GetMapID()` check fires after `SV_MoveTo` returns `True` as a belt-and-suspenders catch for cases where the game zones the player without `SV_MoveTo` detecting it
- **Wrong-zone re-entry recovery:** `SV_EnterZoneFromOutpost` now uses `TravelToOutpost($sv_outpost_id)` (when known) to return after a wrong-zone entry, instead of `ReturnToOutpost()` which could land anywhere. Portal attempt log lines promoted from `SV_DBG` to `Info` so they always appear
- **Portal safe distance increased:** `$SV_PORTAL_SAFE_DIST` raised from `$RANGE_EARSHOT` (~1000) to `$RANGE_EARSHOT * 1.5` (~1500) to give more margin before `SV_NearAnyPortal` and `SV_DirectionOpen` reject a heading

### v1.0.5
- Added `SV_WaitForRez()` — when the player dies but a hero with a rez skill is still alive, the bot waits up to 30s to be resurrected instead of immediately aborting. Resumes movement after rez (saved waypoint cleared to avoid pathing into the same danger)
- Added full wipe detection with clear log: `Warn` on party wipe before resigning
- Added `IsRunFailed()` check at the top of the main loop — aborts after 5 cumulative party wipes per run (tracked by BotsHub's `TrackPartyStatus` adlib)
- Death clears `$hasResume` so the bot doesn't try to walk back into the spot it just died

### v1.0.4
- Increased `$SV_AGGRO_RANGE` from `$RANGE_EARSHOT * 1.5` (~1500) to `$RANGE_EARSHOT * 2` (~2000)

### v1.0.3
- Fixed double target call: `Attack($target, True)` now only fires when the target ID changes, preventing the party call from spamming on every skill cooldown loop iteration
- Added `$SV_DEBUG` constant (default `False`) — set to `True` to enable verbose navigation/bounce/wall logging for troubleshooting; `Warn()` and `Error()` always print regardless
- Added `SV_DBG()` helper wrapping all movement/navigation `Info()` calls under the debug flag
- Added combat target log: `Info('[SmartVanquisher] Targeting agent ID=...')` fires once per new target

### v1.0.2
- Fixed re-entry loop: `SV_EnterZoneFromOutpost` now tries **all** portal agents sorted by distance, rezoning back to the outpost between attempts if the wrong zone is entered. Falls back to `TravelToOutpost` as a last resort
- Fixed accidental portal entry: added `SV_NearAnyPortal` real-time tripwire — after each sub-step the player's actual position is checked against all portals; if too close, movement stops and the heading is bounced immediately
- Moved `SV_GetPortalAgents` call outside the `Else` branch so `$portals` is always in scope for the sub-step safety check

### v1.0.1
- `Attack($target, True)` — enabled the `callTarget` flag so the bot calls out its attack target in party chat, signalling heroes to focus the same enemy

### v1.0.0 — Initial Release
- Bounce Roomba movement algorithm
- Zero-config zone/outpost/position detection at runtime
- Smart heading selection with unvisited cell scoring
- Direction poisoning to prevent re-attempting blocked paths
- Portal safety via multi-point intermediate checks
- Combat interrupt with waypoint resume
- Fast wall detection via custom `SV_MoveTo` (4-tick timeout)
- Entry portal exclusion from navigation avoidance
- Second-run outpost re-entry support
