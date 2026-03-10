# SmartVanquisher

**Version:** 1.3.0  
**Author:** Wicket  
**Framework:** [BotsHub](https://github.com/caustic-kronos/BotsHub) by caustic-kronos  
**Language:** AutoIt (.au3)  
**Game:** Guild Wars 1

---

## Overview

A fully map-agnostic vanquisher and cartography bot for Guild Wars 1. No map IDs, outpost IDs, or hardcoded coordinates — everything is detected at runtime from the player's current context.

The movement algorithm uses **frontier-directed navigation**: the visited-cell grid defines a frontier (the boundary between explored and unexplored space), and the bot always steers toward the nearest unvisited frontier cell. The bounce roomba serves as the locomotion layer — when geometry blocks the direct path, it bounces toward the best open heading that still closes distance to the target. If a target proves unreachable after too many bounces, it is abandoned and the next nearest frontier cell is selected.

---

## Features

- **Zero configuration** — start from inside any explorable zone and the bot figures out everything else
- **Frontier-directed navigation** — always targets the nearest unvisited frontier cell; eliminates aimless re-visiting of already-covered areas
- **Bounce roomba locomotion** — steers toward the frontier target using scored bounce candidates; falls back gracefully when geometry blocks the direct path
- **Frontier bias in heading scoring** — bounce candidates that close distance to the current frontier target receive a +3.0 bonus, keeping detours short
- **Unreachable target abandonment** — if a frontier target can't be reached after `$SV_FRONTIER_GIVE_UP_BOUNCES` bounces without closing the gap by one cell width, it is marked visited and the next nearest frontier cell is chosen
- **Smart heading selection** — scores 6 candidate angles by unvisited cell lookahead + reflection bonus + frontier bias + ping-pong penalty
- **Direction poisoning** — blocked headings have their lookahead cells marked visited so the same wall is never retried
- **Portal safety** — checks 4 intermediate points along every proposed step; rejects any heading whose path passes within ~800 units of an exit portal. The entry portal is excluded so the bot never deflects from its own spawn
- **Combat interrupt** — movement stops when foes are detected within ~2000 units; frontier target recomputed after combat since position may have shifted
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

### Frontier-Directed Navigation

```
1. Maintain a visited-cell grid (1000-unit cells) as the bot moves
2. Frontier = any visited cell with at least one unvisited neighbour
3. Pick the nearest frontier cell as the current target
4. Steer toward it using bounce locomotion:
     a. Set heading toward target
     b. Walk in 1000-unit steps (SV_MoveTo, 4-tick wall detection)
     c. On wall hit: score 6 bounce candidates
        - Unvisited cell lookahead (0-5 pts)
        - Reflection bonus (0-2 pts, prefers 90deg bounces)
        - Frontier bias (+3 pts if heading closes gap to target)
        - Ping-pong / history penalty (-3 to -4 pts)
        - Pick highest-scoring open heading
5. If after $SV_FRONTIER_GIVE_UP_BOUNCES bounces the gap hasn't
   closed by one cell width: abandon target, mark visited, pick next
6. After combat: recompute frontier from new position
7. Exit when GetAreaVanquished() returns True (with safety guards)
```

### Wall Detection

`SV_MoveTo` is the wall detection mechanism. It issues `Move(x, y)` then polls `IsPlayerMoving()` every 100ms. After 4 consecutive stopped ticks (~400ms) without reaching the destination it returns `False` — a wall hit. This is reliable because:
- A 300ms grace period after issuing the move prevents false positives before the player starts walking
- The 4-tick threshold filters out momentary animation jitter when body-blocked
- The frontier give-up logic catches geometrically isolated targets: if bouncing repeatedly doesn't close the gap, the target is abandoned and the next frontier cell is chosen

### Combat

```
1. Before each step, CountFoesInRangeOfAgent at ~2000 units
2. Mid-step: check every sub-step — save waypoint and stop immediately if foes appear
3. Fight: skills 1-8 in order, wait for each cast, skip if on cooldown
4. Loot within ~2000 units using your configured loot filter
5. Recompute frontier target (position may have shifted during combat)
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

### v1.4.0
- **Cell size halved: 1000 → 500 units:** Finer spatial resolution means enemies near cell edges are no longer skipped. A 1000-unit cell is huge — the bot could clip one corner, mark the whole cell visited, and miss a group standing 800 units away on the other side. At 500 units the visited set grows ~4x faster; `$MAX_VISITED` raised from 10000 to 40000 and `$SV_FRONTIER_GIVE_UP_BOUNCES` raised from 12 to 20 to compensate (each step now covers ~2 cells so more bounces are needed to close the same world-space gap)
- **Confirmed-clear tracking:** A visited cell is not considered done until `CountFoesInRangeOfAgent($me, $SV_CLEAR_CHECK_RADIUS)` returns 0 while the bot is physically inside it. The `$clearedKeys` set tracks confirmed-clear cells separately from `$visitedKeys`. `SV_FindFrontierTarget` now uses a two-pass priority system: visited-but-uncleared cells are targeted first (enemies may still be present), unvisited frontier cells second. This directly prevents vanquish stalls caused by enemies the bot passed without pulling
- **`$SV_CLEAR_CHECK_RADIUS = $SV_BOUNCE_CELL_SIZE * 1.5` (~750 units):** Slightly wider than one cell to catch foes near the boundary of an adjacent cell
- **Binary search for `SV_IsVisited` on `$visitedKeys` and `$clearedKeys`:** Both sorted sets now use O(log n) insertion (`SV_MarkVisitedSorted`) and O(log n) lookup (`SV_IsVisitedBSearch`). At 500-unit cells with 40000 max entries, the difference between linear and binary search is ~200x per lookup. All hot paths — `SV_MarkVisitedFrontier` neighbour checks (8 per cell marked), `SV_UpdateFrontierCell`, `SV_PickBounceHeading` lookahead (5 per bounce candidate × 6 candidates) — now use `SV_IsVisitedBSearch`
- **`SV_MarkVisited` / `SV_IsVisited` kept for small unsorted sets:** `$abandonedKeys` and `$frontierKeys` use swap-with-last removal and can't maintain sort order; they stay on the linear path. Both sets stay small throughout a run so the cost is negligible

### v1.3.1
- **Incremental frontier set replaces O(n²) scan:** `SV_FindFrontierTarget` previously derived the frontier on every call by scanning all visited cells and checking their 8 neighbours — O(n²) with a linear `SV_IsVisited` search inside each neighbour check. On a large map with 500+ visited cells this was ~2 million comparisons per frontier pick, causing visible stuttering late in a run. Replaced with an incrementally maintained `$frontierKeys` set: when a cell is marked visited via `SV_MarkVisitedFrontier`, it is removed from the frontier and its 8 neighbours are each re-evaluated — visited neighbours with no remaining unvisited neighbours are dropped from the frontier, unvisited neighbours confirm the current cell belongs in the frontier. `SV_FindFrontierTarget` now just scans the frontier set directly (O(f) where f stays small throughout the run)
- **`SV_MarkVisitedFrontier()`:** New function replacing direct `SV_MarkVisited` calls for the main cell grid. Handles visited insertion, frontier removal, and 8-neighbour frontier updates atomically
- **`SV_UpdateFrontierCell()`:** Re-evaluates whether a visited neighbour should remain in or be removed from the frontier after one of its neighbours becomes visited
- **`SV_AddToFrontier()` / `SV_RemoveFromFrontier()`:** O(1) set operations. Removal uses swap-with-last to avoid shifting the array
- **`SV_PoisonDirection()` updated:** Now accepts and passes through the frontier set so poisoned cells are correctly removed from the frontier
- **`SV_FindFrontierTarget()` signature changed:** Now takes `$frontierKeys`/`$frontierCount` directly instead of the full `$visitedKeys` set

### v1.3.0
- **Frontier-directed navigation replaces pure bounce roomba:** The visited-cell grid now defines an explicit frontier — the boundary between explored and unexplored cells. At each navigation step the bot picks the nearest unvisited frontier cell as a medium-range target and steers toward it. The bounce roomba becomes the locomotion layer rather than the navigation brain, eliminating the aimless re-visiting behaviour visible in earlier logs
- **`SV_FindFrontierTarget()`:** Scans all visited cells, identifies those with at least one unvisited 8-directional neighbour, and returns the nearest such cell within `$SV_FRONTIER_MAX_RANGE` (~10000 units) that hasn't been abandoned
- **Frontier bias in `SV_PickBounceHeading()`:** Bounce candidates that would close the gap to the current frontier target receive a +3.0 score bonus. This keeps detours short — after a wall hit the bot picks the bounce that both avoids the wall and makes progress toward the target
- **Unreachable target abandonment:** `$SV_FRONTIER_GIVE_UP_BOUNCES` (default 12) bounces are allowed per target. If after that many bounces the distance to the target hasn't closed by at least one cell width, the target is declared unreachable, added to the abandoned set and the visited map, and the next nearest frontier cell is chosen
- **Frontier recomputed after combat and death:** Position can shift significantly during a fight or after shrine respawn. The frontier target is cleared on both events so the next target is picked from the actual post-combat position
- **`$SV_FRONTIER_GIVE_UP_BOUNCES = 12`** and **`$SV_FRONTIER_MAX_RANGE = ~10000`** added as tuning constants
- **Removed `$stepsSinceNewCell` progress check:** Superseded by the per-target abandon logic, which is more precise — it measures actual distance closed rather than counting loop iterations
- **Fixed: bot spinning without moving (portal bounce ContinueLoop):** After picking a new heading due to a portal blocking the path, the code was calling `ContinueLoop` which jumped back to the top of the While loop — skipping the entire movement block. The bot would spin logging "Portal ahead - bouncing" thousands of times per second without ever issuing a move. Fixed by removing the `ContinueLoop` so the bot falls through to compute `$targetX/$targetY` with the updated heading and actually walks
- **Fixed: frontier target immediately re-reached on first pick:** The "target reached" threshold was `dist < $CELL` (1000 units). The first frontier cell is always the cell containing the spawn point, which can be as close as 125 units away — well inside the threshold. The bot would mark it reached, pick it again, mark it reached again, looping forever without moving. Fixed by reducing the threshold to `$CELL / 4` (250 units)
- **Fixed: `$portalBlockedCount` reset unconditionally:** The cage counter was being reset to 0 on every iteration regardless of whether the direction was actually clear, defeating the cage detection logic. Now only resets when `SV_DirectionOpen` returns True (no portal blocking)

### v1.2.6
- **Portal safe distance reduced: ~1500 → ~800 units:** The previous `$RANGE_EARSHOT * 1.5` exclusion radius was so large that near map edges — where portals cluster close together — all 8 candidate headings would be simultaneously portal-blocked, triggering an infinite spin loop. The new `$RANGE_EARSHOT * 0.8` (~800 units) gives the bot much more room to maneuver near portals while still comfortably preventing accidental zone entry. The danger zone radius (650 units) and real-time `SV_NearAnyPortal` tripwire remain as secondary guards
- **Portal-cage escape (`$portalBlockedCount`):** Tracks consecutive "all directions portal-blocked" bounce cycles. After 4 in a row the bot declares itself portal-caged, calls `TryToGetUnstuck` toward `$lastSafeX/$lastSafeY` (the last confirmed safe position before getting trapped), then sets heading directly toward that safe position. Using the last safe position rather than a random escape angle is intentional — it is guaranteed not to be portal territory. The counter resets on any successful step, combat, or whenever at least one direction opens up

### v1.2.5
- **Fixed crash false-positive vanquish:** When the GW client crashes, all memory reads return 0 — including `GetFoesToKill()`. The double-read in `SV_ConfirmVanquished` was not sufficient because both reads still return 0 after a crash, 1.5s apart. Fixed by tracking `$sv_max_foes_seen` — the highest `GetFoesToKill()` value seen during the run. `SV_ConfirmVanquished` now requires this to be `> 0` before trusting any zero reading. A client crash mid-run will never trigger a false vanquish because the bot never saw the foe counter count down from a real value. Reset in `SV_ClearState` between runs

### v1.2.4 (hotfix)
- **Fixed infinite recursion in `SV_ConfirmVanquished`:** The greedy replacement of all `GetAreaVanquished()` calls also replaced the two raw calls *inside* the new helper itself, causing it to call itself recursively and hang the bot at startup. The helper now correctly calls `GetAreaVanquished()` internally for its two reads

### v1.2.4
- **Fixed false vanquish detection:** `GetFoesToKill()` returns 0 on any memory read failure (null pointer in the chain, freed agent struct during heavy combat — the source of the frequent "Tried to access an invalid address" log entries). This made `GetAreaVanquished()` fire a false positive mid-combat and exit the run prematurely. Fixed with a new `SV_ConfirmVanquished()` wrapper that: (1) checks there are no foes in earshot, (2) reads `GetFoesToKill()` twice 1.5s apart and requires both to be 0. All three `GetAreaVanquished()` call sites replaced

### v1.2.3
- **Clearer success/failure messaging:** On a successful vanquish the log now says "Zone vanquished - run complete!" clearly distinguishable from a failed run. Previously both paths logged ambiguously and BotsHub's own "Run failed" timer label was showing even on successful vanquishes (it fires for any `$PAUSE` return regardless of outcome — that is a BotsHub framework label outside our control)

### v1.2.2
- **Combat loop no longer aborts on death:** `SV_CombatLoop` was returning `$FAIL` when `IsPlayerDead()` fired mid-combat, which propagated straight to `SmartVanquisherFarm` as a run failure — completely bypassing the `SV_WaitUntilAlive` shrine-respawn logic added in v1.2.0. Now both `IsPlayerDead` and `IsPlayerAndPartyWiped` in the combat loop do `ExitLoop` instead, returning `$SUCCESS` back to the main roomba loop which then hits the death handler on the next iteration and waits for respawn

### v1.2.1
- **Cornered detection:** Tracks consecutive wall-hits on sub-step 1 (meaning the bot can't move even 250 units in any direction). After 6 in a row it declares itself cornered, calls `TryToGetUnstuck` toward a random escape target 3000 units away, resets heading to the escape angle, and clears the waypoint. This handles the case where the bounce scoring cycles through all headings but every one hits an immediate wall — the visited-cell map is all poisoned and no scored heading can escape the corner

### v1.2.0
- **Wipe handling completely rewritten:** GW auto-respawns the party at the nearest resurrection shrine after a full wipe — no re-entry needed. The bot now simply waits for the respawn and resumes the run from the shrine. Two paths:
  - *Hero with rez alive:* wait up to 30s for in-place resurrection, then resume toward last position
  - *Full wipe / no rez hero:* wait up to 60s for GW's automatic shrine respawn, then resume
  - *Either path, DP >= 60% after respawn:* return to outpost and pause — only safe option
- **`$SV_MAX_DP_TO_CONTINUE = -60`** tuning constant added — adjust to taste (e.g. `-40` to bail earlier)
- **Removed `IsRunFailed()` hard abort** — the 5-wipe counter no longer makes sense now that wipes are handled gracefully
- **`SV_WaitForRez` replaced by `SV_WaitUntilAlive`** — unified function handles both in-place rez and shrine respawn with DP check at the end

### v1.1.5
- **Danger zone radius reduced to 650 units:** The learned portal at (19800, 11176) is only 554 units from spawn. Any radius above ~650 causes the exclusion bubble to cover the entire spawn area, blocking all candidate headings. 650 is the minimum value that reliably deflects a moving bot without paralyzing it at spawn
- **Escape move when heading doesn't change:** When `SV_PickBounceHeading` returns the same heading it was given (meaning all candidates were equally bad and the fallback didn't change anything), the bot now attempts a small 300-unit `SV_MoveTo` in that direction to physically shift its position before re-evaluating — prevents infinite tight-loop re-evaluation from the same spot

### v1.1.4
- **Removed entry portal from danger zones:** v1.1.2 mistakenly added the entry portal as a runtime danger zone to deflect the bot away from it. Since spawn can be as close as ~500 units to the entry portal, the 1200-unit exclusion bubble covered the entire spawn area, blocking all candidate headings and causing infinite ping-pong. The entry portal was already correctly handled by `SV_GetPortalAgents()` stripping it from the signpost list — no danger zone needed

### v1.1.3
- **Danger zone radius reduced from `2.0x` to `1.2x` earshot (~1200 units):** A 2000-unit radius was bleeding into unrelated directions from narrow spawns
- **Least-bad fallback in `SV_PickBounceHeading`:** When all 6 candidate directions are portal-blocked, instead of reversing (which may also be blocked), the bot now picks the candidate with the greatest minimum clearance from any portal and logs a warning
- **File logging added to `BotsHub-GUI.au3`:** All log output now written to `logs\botshub-YYYYMMDD-HHMMSS.log` for post-mortem debugging

### v1.1.2
- **Hard Mode check moved to entry point:** `GetIsHardMode()` now fires in `SmartVanquisherFarm()` before any zone logic runs, not just inside `SV_Run()`. Previously a portal re-entry path could bypass the check entirely, causing the bot to see `GetAreaVanquished() = True` (Normal Mode behaviour) and exit as "success"
- **Danger zone file format changed to CSV:** The JSON UDF (`_JSON_Parse`/`_JSON_Generate`) was failing to round-trip the written file correctly. Replaced with a simple one `x,y` pair per line format — trivially readable and writable with `FileReadLine`/`FileWriteLine`, no external library needed. Existing `.json` files will be ignored and re-learned automatically
- **Entry portal registered as runtime danger zone:** On each zone entry, the detected entry portal position is added to `$sv_danger_zones` in memory (but not saved to file). This ensures `SV_DirectionOpen` and `SV_NearAnyPortal` deflect away from the spawn portal during navigation — the root cause of the bot bouncing straight back through it on the first step

### v1.1.1
- **Ball-like reflection bouncing:** `SV_PickBounceHeading` now scores candidates with a reflection bonus. ±90° from the blocked heading (the most physically natural bounce) gets +2.0, ±45° and ±135° get +0.5. This biases the bot toward maintaining forward momentum rather than reversing
- **Heading history buffer:** A circular buffer of the last 6 headings is tracked in `SV_BounceRoomba`. Candidates within 30° of a recently used heading receive a -3.0 penalty; near-exact reversals of a recent heading receive a -4.0 ping-pong penalty
- **Reverse (180°) is fallback only:** The reverse direction is no longer a scored candidate — it is only selected if every other direction is blocked by portals or danger zones
- **Candidate order changed:** Candidates are now tried ±90° first, then ±45°, then ±135° — reflecting the order of physical preference, not arbitrary insertion order

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
