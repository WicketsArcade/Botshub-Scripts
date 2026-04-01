#CS ===========================================================================
#################################
#                               #
#   Smart Vanquisher Bot        #
#                               #
#################################
; Version: 1.6.3
; Author: Wicket
; Framework: BotsHub by caustic-kronos
;
; A fully map-agnostic vanquisher. No map IDs, outpost IDs, or coordinates
; need to be configured. Everything is detected at runtime:
;
;   - Zone map ID        -> read from GetMapID() on start
;   - Return outpost ID  -> read from GetAreaInfoByID().controlled_outpost_ID
;   - Entry position     -> read from GetMyAgent() X/Y immediately on start
;
; HOW TO START:
;   Simply be inside any explorable zone (already past the portal, loaded in)
;   and press Start in the BotsHub GUI. The bot captures its context and runs.
;   If started from an outpost it will error and stop safely.
;
; HOW TO REGISTER IN BotsHub.au3:
;   1.  #include 'src/vanquishes/SmartVanquisher.au3'
;   2.  Add '|Smart Vanquisher' to $AVAILABLE_FARMS string
;   3.  In FillFarmMap():
;         AddFarmToFarmMap('Smart Vanquisher', SmartVanquisherFarm, 5, $SV_FARM_DURATION)
;
; ALGORITHM OVERVIEW:
;
;   BOUSTROPHEDON SWEEP + FRONTIER FALLBACK
;     Primary navigation: a boustrophedon (lawnmower) sweep covers the map
;     in row-by-row order with no backtracking.  The sweep plan is built
;     dynamically from the visited-cell bounding box and rebuilt whenever
;     the bot explores beyond the current plan boundary.
;
;     Sweep order:
;       Row 0 (southernmost): west → east
;       Row 1:                east → west
;       Row 2:                west → east  ...
;     Y increases northward; rows advance north each step.
;
;     Target selection:
;       - The sweep plan is a flat ordered array of cell-grid coordinates.
;       - Each loop iteration advances past any waypoints already confirmed
;         clear, targeting the next uncleared waypoint in sequence.
;       - Waypoints unreachable after $SV_FRONTIER_GIVE_UP_BOUNCES bounces
;         are skipped (marked abandoned) and the sweep advances.
;       - When the sweep plan is exhausted but GetFoesToKill() > 0, the bot
;         falls back to BFS+momentum frontier targeting to hunt remaining
;         enemies the sweep missed (e.g. outside the visited bounding box).
;
;     Locomotion (bounce roomba):
;       - Pick a heading toward the current sweep waypoint.
;       - Walk in 500-unit steps using SV_MoveTo (fast wall detection).
;       - On wall hit: bounce to the best open heading that still closes
;         distance to the target, scored by unvisited lookahead + reflection
;         bonus + heading history penalty + frontier bias.
;
;   CONFIRMED-CLEAR TRACKING
;     A visited cell is not considered done until CountFoesInRangeOfAgent
;     returns 0 while the bot is physically inside it.  The sweep advance
;     logic skips only confirmed-clear cells; uncleared visited cells are
;     re-targeted so the bot pauses and checks for enemies.
;
;   COMBAT
;     Foes within ~2000 units interrupt movement.  The bot stands still,
;     fights, loots, then resumes the sweep from the current waypoint.
;
;   PORTAL SAFETY
;     All non-entry portals are detected as static agents with GadgetID != 0.
;     SV_DirectionOpen checks 4 intermediate points along every proposed step -
;     if any point is within ~800 units of a portal the heading is rejected.
;     The entry portal is excluded so the bot never deflects from its own spawn.
;
; STUCK DETECTION:
;   - Per-target: give up after $SV_FRONTIER_GIVE_UP_BOUNCES bounces without
;     closing the gap to the frontier target by one cell width.
;   - Global: 120-minute hard cap via CheckStuck().
;
; REQUIREMENTS:
;   - Be inside an explorable zone before pressing Start.
;   - Have a hero team capable of clearing Hard Mode content.
;   - Load your own skill bars - this bot does NOT set builds.
;   - Hard Mode is NOT switched on automatically; enable it before entering.
#CE ===========================================================================

#include-once
#RequireAdmin
#NoTrayIcon

#include '../../lib/GWA2.au3'
#include '../../lib/GWA2_ID.au3'
#include '../../lib/Utils.au3'
#include '../../lib/Utils-Agents.au3'
#include '../../lib/JSON.au3'

Opt('MustDeclareVars', True)

; ===========================================================================
; TUNING CONSTANTS
; ===========================================================================

; How far each bounce step travels (GW units)
Global Const $SV_BOUNCE_STEP           = $RANGE_EARSHOT             ; ~1000

; Aggro scan range - stop moving and fight if foes within this distance
Global Const $SV_AGGRO_RANGE           = $RANGE_EARSHOT * 2         ; ~2000

; Cell size for visited-area tracking.
; Smaller = finer coverage resolution, fewer enemies fall through gaps.
; At 500 units a step covers ~2 cells so the visited set grows faster -
; MAX_VISITED and GIVE_UP_BOUNCES are scaled accordingly.
Global Const $SV_BOUNCE_CELL_SIZE      = 500                         ; ~500 units

; Radius used to confirm a cell is clear of enemies.
; 1.5x cell size catches foes near the edge of an adjacent cell.
Global Const $SV_CLEAR_CHECK_RADIUS    = $SV_BOUNCE_CELL_SIZE * 1.5 ; ~750 units

; Portal exclusion radius - don't step toward a portal within this range
Global Const $SV_PORTAL_SAFE_DIST      = $RANGE_EARSHOT * 0.8       ; ~800

; Exclusion radius around a learned danger zone (portal entry point)
; Must be < distance from spawn to nearest portal to avoid blocking all directions at startup
Global Const $SV_DANGER_ZONE_RADIUS    = 650                         ; ~650 units

; Minimum distance between two danger zones - prevents duplicate entries
Global Const $SV_DANGER_ZONE_MERGE_DIST = 500

; Maximum bounces toward a frontier target before declaring it unreachable.
; Scaled up from 12 to 20 because at 500-unit cells a step covers ~2 cells,
; so more bounces are needed to close the same world-space gap.
Global Const $SV_FRONTIER_GIVE_UP_BOUNCES = 20

; How far ahead we look when picking a frontier target (GW units).
; Targets beyond this range are ignored - keeps the target reachable.
Global Const $SV_FRONTIER_MAX_RANGE = $RANGE_EARSHOT * 10   ; ~10000

; Maximum total run time (ms)
Global Const $SV_FARM_DURATION         = 120 * 60 * 1000            ; 120 min

; Pause after each combat encounter (ms)
Global Const $SV_POST_COMBAT_WAIT      = 800

; Set to True to enable verbose navigation/combat logging, False for clean runs
Global Const $SV_DEBUG                 = True

; Momentum weight for frontier target selection.
; Scales the angular penalty applied to frontier candidates that require
; turning away from the current heading. Higher = more directional commitment.
;   0.0 = pure BFS hop distance (no momentum, identical cells tie on distance)
;   0.5 = a 180deg reversal costs the equivalent of ~1.6 extra BFS hops
;   1.0 = a 180deg reversal costs the equivalent of ~3.1 extra BFS hops
Global Const $SV_MOMENTUM_WEIGHT       = 0.5

; Maximum death penalty (as negative morale, e.g. -60 = 60% DP) before we
; abandon the run instead of re-entering after a wipe. 0 = never retry.
Global Const $SV_MAX_DP_TO_CONTINUE    = -60



; Info string displayed in the BotsHub GUI
Global Const $SV_FARM_INFORMATIONS = _
    'Smart Vanquisher - zero-config, map-agnostic vanquisher.' & @CRLF & _
    '' & @CRLF & _
    'HOW TO USE:' & @CRLF & _
    '  1. Enter any explorable zone manually.' & @CRLF & _
    '  2. Select Smart Vanquisher and press Start.' & @CRLF & _
    '  The bot reads your zone, outpost and position automatically.' & @CRLF & _
    '' & @CRLF & _
    'Algorithm: Frontier-directed Roomba - picks the nearest unvisited' & @CRLF & _
    'area as a target, steers toward it using bounce locomotion, and' & @CRLF & _
    'abandons unreachable targets after too many failed bounces.' & @CRLF & _
    '' & @CRLF & _
    'Requirements: hero team that can clear HM, your own skill bars loaded.'

; ===========================================================================
; RUNTIME STATE  (populated dynamically on each run)
; ===========================================================================

Global $sv_map_id       = -1    ; detected zone map ID
Global $sv_outpost_id   = -1    ; detected return outpost ID
Global $sv_entry_x      = 0.0   ; entry position X
Global $sv_entry_y      = 0.0   ; entry position Y

; The entry portal (nearest portal to spawn) is stored so we can ignore it
; during wall-following - we don't want to avoid the portal we just came through.
Global $sv_entry_portal_x = 0.0
Global $sv_entry_portal_y = 0.0
Global $sv_entry_portal_found = False

; Learned danger zones for this map - loaded from file on zone entry, appended
; when we accidentally walk into a portal. Each entry is a 2-element array [x, y].
; The exclusion radius $SV_DANGER_ZONE_RADIUS is applied at check time.
Global $sv_danger_zones[64][2]   ; [index][0=x, 1=y]
Global $sv_danger_zone_count = 0
Global $sv_max_foes_seen = 0   ; highest GetFoesToKill() reading this run - must be >0 to trust a zero

; ===========================================================================
; ENTRY POINT
; ===========================================================================

Func SmartVanquisherFarm()

    ; ---- Handle being in outpost (second+ runs after ResignAndReturnToOutpost) ----
    If GetMapType() = $ID_OUTPOST Then
        If $sv_map_id = -1 Then
            Error('[SmartVanquisher] First run must be started from inside an explorable zone.')
            Return $PAUSE
        EndIf
        Info('[SmartVanquisher] In outpost - entering zone ' & $sv_map_id)
        If SV_EnterZoneFromOutpost() == $FAIL Then
            Warn('[SmartVanquisher] Could not enter zone - pausing. Return to your starting outpost and press Start.')
            SV_ClearState()
            Return $PAUSE
        EndIf
    EndIf

    ; ---- Guard: must now be in an explorable ---------------------------
    If GetMapType() <> $ID_EXPLORABLE Then
        Error('[SmartVanquisher] Not in an explorable zone after entry attempt.')
        Return $PAUSE
    EndIf

    ; ---- Guard: Hard Mode must be active ----------------------------------
    If Not GetIsHardMode() Then
        Error('[SmartVanquisher] Not in Hard Mode - enable Hard Mode before entering the zone and press Start.')
        SV_ClearState()
        Return $PAUSE
    EndIf

    ; Capture the zone we are currently in
    $sv_map_id = GetMapID()

    ; Derive the controlling outpost from the area info struct.
    ; controlled_outpost_ID is the map ID of the outpost that "owns" this zone.
    Local $areaInfo = GetAreaInfoByID($sv_map_id)
    $sv_outpost_id  = DllStructGetData($areaInfo, 'controlled_outpost_ID')

    If $sv_outpost_id = 0 Then
        Warn('[SmartVanquisher] controlled_outpost_ID is 0 - will use generic return.')
    EndIf

    ; Capture entry position from the current player agent
    Local $me = GetMyAgent()
    $sv_entry_x = DllStructGetData($me, 'X')
    $sv_entry_y = DllStructGetData($me, 'Y')

    ; Find and record the entry portal (the one we just walked through).
    ; This portal is always the nearest static portal to the spawn point.
    ; We'll ignore it during wall-following so the bot doesn't deflect away from it.
    $sv_entry_portal_found = False
    Local $statics = GetAgentArray($ID_AGENT_TYPE_STATIC)
    Local $nearestDist = 1000000000
    For $a In $statics
        If Not SV_IsPortalAgent($a) Then ContinueLoop
        Local $px = DllStructGetData($a, 'X')
        Local $py = DllStructGetData($a, 'Y')
        Local $d  = SV_Dist($sv_entry_x, $sv_entry_y, $px, $py)
        If $d < $nearestDist Then
            $nearestDist           = $d
            $sv_entry_portal_x     = $px
            $sv_entry_portal_y     = $py
            $sv_entry_portal_found = True
        EndIf
    Next

    If $sv_entry_portal_found Then
        Info('[SmartVanquisher] Entry portal at (' & Round($sv_entry_portal_x) & ',' & Round($sv_entry_portal_y) & ') - will be ignored during navigation')
    EndIf

    Info('[SmartVanquisher] mapID=' & $sv_map_id & _
         '  outpostID=' & $sv_outpost_id & _
         '  entry=(' & Round($sv_entry_x) & ',' & Round($sv_entry_y) & ')')

    ; Load any previously learned danger zones (portal entry points) for this map
    SV_LoadDangerZones()

    ; NOTE: Entry portal is intentionally NOT added to danger zones.
    ; SV_GetPortalAgents() already strips it from the signpost portal list,
    ; so it is fully ignored during navigation. Adding it as a danger zone
    ; causes the exclusion bubble to cover the spawn area itself.

    ; ---- Reset per-run mutable state ------------------------------------
    SV_ResetState()

    ; ---- Run -----------------------------------------------------------
    AdlibRegister('TrackPartyStatus', 10000)
    Local $result = SV_Run()
    AdlibUnRegister('TrackPartyStatus')

    ; ---- Return to outpost ---------------------------------------------
    If GetMapType() = $ID_EXPLORABLE Then
        If $sv_outpost_id > 0 Then
            ResignAndReturnToOutpost($sv_outpost_id)
        Else
            ; Fallback: resign and wait for the game to drop us to any outpost
            Resign()
            Sleep(3500)
            ReturnToOutpost()
            WaitMapLoading(-1, 10000, 1000)
        EndIf
    EndIf

    SV_ClearState()

    If $result = $SUCCESS Then
        Info('[SmartVanquisher] Zone vanquished - run complete! Press Start to vanquish another zone.')
    Else
        Warn('[SmartVanquisher] Run ended without vanquish - pausing. Return to your starting zone and press Start.')
    EndIf

    Return $PAUSE
EndFunc


; Reset all per-run mutable state (timers, failure counters)
Func SV_ResetState()
    IsPlayerStuck(Default, Default, True)
    ResetFailuresCounter()
EndFunc


; Full state clear - called on pause/failure so the next Start is always fresh.
; Resets map ID so the bot re-captures zone context on next run rather than
; assuming it is still in the same zone.
Func SV_ClearState()
    SV_ResetState()
    $sv_map_id              = -1
    $sv_outpost_id          = -1
    $sv_entry_x             = 0.0
    $sv_entry_y             = 0.0
    $sv_entry_portal_found  = False
    $sv_danger_zone_count   = 0
    $sv_max_foes_seen = 0
EndFunc


; Walk to and activate the zone portal in the outpost that leads to $sv_map_id.
; Tries all static portal agents sorted by proximity, walking to each one until
; the game zones us into $sv_map_id. This handles outposts with multiple portals
; where the nearest one doesn't lead to the target zone.
; If no portal works, uses TravelToOutpost as a last resort.
Func SV_EnterZoneFromOutpost()
    Local $me  = GetMyAgent()
    Local $myX = DllStructGetData($me, 'X')
    Local $myY = DllStructGetData($me, 'Y')

    ; Collect all static portal agents with their distances
    Local $statics  = GetAgentArray($ID_AGENT_TYPE_STATIC)
    Local $portals[32]
    Local $dists[32]
    Local $n = 0
    For $a In $statics
        If Not SV_IsPortalAgent($a) Then ContinueLoop
        If $n >= 32 Then ExitLoop
        $portals[$n] = $a
        $dists[$n]   = SV_Dist($myX, $myY, DllStructGetData($a,'X'), DllStructGetData($a,'Y'))
        $n += 1
    Next

    ; Bubble sort by distance ascending (n is small, this is fine)
    For $i = 0 To $n - 2
        For $j = 0 To $n - $i - 2
            If $dists[$j] > $dists[$j + 1] Then
                Local $tmpD = $dists[$j]   : $dists[$j]   = $dists[$j+1] : $dists[$j+1] = $tmpD
                Local $tmpP = $portals[$j] : $portals[$j] = $portals[$j+1] : $portals[$j+1] = $tmpP
            EndIf
        Next
    Next

    ; Try each portal closest-first
    For $i = 0 To $n - 1
        Local $px = DllStructGetData($portals[$i], 'X')
        Local $py = DllStructGetData($portals[$i], 'Y')
        Info('[SmartVanquisher] Trying portal ' & ($i+1) & '/' & $n & ' at (' & Round($px) & ',' & Round($py) & ')')
        GoToSignpost($portals[$i])
        WaitMapLoading($sv_map_id, 12000, 1000)
        If GetMapID() = $sv_map_id Then Return $SUCCESS

        ; Wrong zone - resign back to wherever we ended up, then travel to the
        ; correct outpost if we know it, otherwise just return to any outpost
        Warn('[SmartVanquisher] Wrong zone (mapID=' & GetMapID() & ') - returning to outpost')
        If GetMapType() = $ID_EXPLORABLE Then
            Resign()
            Sleep(3000)
        EndIf
        If $sv_outpost_id > 0 Then
            TravelToOutpost($sv_outpost_id)
            WaitMapLoading($sv_outpost_id, 15000, 1000)
        Else
            ReturnToOutpost()
            WaitMapLoading(-1, 10000, 1000)
        EndIf
    Next

    ; Last resort: use TravelToOutpost if we have a valid outpost ID
    If $sv_outpost_id > 0 Then
        Warn('[SmartVanquisher] All portals failed - trying TravelToOutpost(' & $sv_outpost_id & ')')
        TravelToOutpost($sv_outpost_id)
        WaitMapLoading($sv_outpost_id, 15000, 1000)
        Return $FAIL   ; Propagates up to SmartVanquisherFarm which converts to $PAUSE
    EndIf

    Warn('[SmartVanquisher] Could not enter zone ' & $sv_map_id)
    Return $FAIL
EndFunc


; ===========================================================================
; TOP-LEVEL RUN LOGIC
; ===========================================================================

; ===========================================================================
; VANQUISH CONFIRMATION
; ===========================================================================

; GetFoesToKill() returns 0 on memory read failure (null pointer, freed agent
; struct during heavy combat), which makes SV_ConfirmVanquished() fire a false
; positive.  This wrapper confirms the zone is actually clear by:
;   1. Checking there are no foes currently in earshot
;   2. Reading GetFoesToKill() twice 1.5s apart - both must be 0
Func SV_ConfirmVanquished()
    ; Never trust a zero if we never saw a non-zero count this run.
    ; GetFoesToKill() returns 0 on memory read failure (process crash,
    ; freed struct) - requiring a prior positive reading rules out both
    ; startup false positives and client-crash false positives.
    If $sv_max_foes_seen = 0 Then Return False
    ; Must still be in the correct explorable - if the bot accidentally
    ; walked through a portal into town, GetAreaVanquished() returns True
    ; trivially from the outpost side. This guard prevents that false positive.
    If GetMapID() <> $sv_map_id Then Return False
    If GetMapType() <> $ID_EXPLORABLE Then Return False
    Local $me = GetMyAgent()
    If CountFoesInRangeOfAgent($me, $RANGE_EARSHOT) > 0 Then Return False
    If Not GetAreaVanquished() Then Return False
    Sleep(1500)
    If Not GetAreaVanquished() Then Return False
    Return True
EndFunc


Func SV_Run()
    If GetMapID() <> $sv_map_id Then Return $FAIL
    If SV_ConfirmVanquished() Then
        Warn('[SmartVanquisher] Zone is already vanquished - pausing.')
        Return $FAIL
    EndIf
    Info('[SmartVanquisher] Starting frontier-directed roomba')
    Local $result = SV_BounceRoomba()
    If SV_ConfirmVanquished() Then
        Info('[SmartVanquisher] Zone vanquished!')
        Return $SUCCESS
    EndIf
    Return $result
EndFunc


; ===========================================================================
; LOGGING HELPER
; ===========================================================================

; Verbose log - only prints when $SV_DEBUG = True
Func SV_DBG($msg)
    If $SV_DEBUG Then Info($msg)
EndFunc


; ===========================================================================
; FRONTIER-DIRECTED ROOMBA
;
; The visited-cell grid defines a frontier: boundary between visited and
; unvisited cells. The bot picks the nearest frontier cell as a target and
; steers toward it using bounce locomotion. If a target proves unreachable
; after too many bounces without closing the gap, it is abandoned and the
; next nearest frontier cell is chosen instead.
; ===========================================================================

Func SV_BounceRoomba()
    Local Const $PI      = 3.14159265358979
    Local Const $CELL    = $SV_BOUNCE_CELL_SIZE
    Local Const $MAX_VISITED = 40000  ; raised from 10000 - 500-unit cells grow set ~4x faster
    Local Const $MAX_SWEEP   = 12000  ; max sweep plan waypoints (dynamic bbox, not full map)

    ; Visited cell registry - sorted for O(log n) binary search
    Local $visitedKeys[$MAX_VISITED]
    Local $visitedCount = 0

    ; Confirmed-clear registry - cells where foes=0 was verified while inside.
    ; Sorted for O(log n) binary search. Sweep advance skips only cleared cells;
    ; uncleared visited cells are re-targeted for enemy confirmation.
    Local $clearedKeys[$MAX_VISITED]
    Local $clearedCount = 0

    ; Incremental frontier set - used by BFS fallback mode when sweep is exhausted
    ; but GetFoesToKill() > 0 (enemies remain outside the sweep bounding box)
    Local $frontierKeys[$MAX_VISITED]
    Local $frontierCount = 0

    ; Explicitly abandoned frontier cells - skipped by SV_FindFrontierTarget in fallback
    Local $abandonedKeys[$MAX_VISITED]
    Local $abandonedCount = 0

    ; ---- Boustrophedon sweep plan ----------------------------------------
    ; Flat ordered array of cell-grid coords (not world coords).
    ; Built from the visited-cell bounding box and rebuilt when it expands.
    Local $sweepPlanCX[$MAX_SWEEP]   ; cell column index (X / CELL)
    Local $sweepPlanCY[$MAX_SWEEP]   ; cell row index    (Y / CELL)
    Local $sweepPlanCount = 0
    Local $sweepIdx       = 0        ; next waypoint to target in sweep plan
    Local $sweepMinCX     = 0        ; current bounding box in cell coords
    Local $sweepMaxCX     = 0
    Local $sweepMinCY     = 0
    Local $sweepMaxCY     = 0
    Local $sweepBoxInited = False    ; True once first cell sets the bbox
    Local $sweepMode      = True     ; True = sweep active, False = BFS fallback

    Local $wallOnStep1Count  = 0   ; consecutive wall-on-sub-step-1 hits - detects physical corner
    Local $portalBlockedCount = 0  ; consecutive all-directions-portal-blocked - detects portal cage

    ; Saved waypoint - resume here after combat interrupts a step
    Local $resumeX = 0
    Local $resumeY = 0
    Local $hasResume = False

    ; Recent heading history for ping-pong prevention.
    Local Const $HEADING_HISTORY_SIZE = 6
    Local $headingHistory[$HEADING_HISTORY_SIZE]
    Local $headingHistoryIdx = 0
    Local $headingHistoryFull = False
    For $hhi = 0 To $HEADING_HISTORY_SIZE - 1
        $headingHistory[$hhi] = 9999.0
    Next

    ; --- Current target state (used by bounce locomotion and PickBounceHeading) ---
    Local $frontierX      = 0.0   ; world X of current target (sweep or fallback)
    Local $frontierY      = 0.0   ; world Y of current target
    Local $hasFrontier    = False  ; True when a valid target is set
    Local $bouncesSinceTarget = 0  ; bounces since last target pick
    Local $distAtTargetSet = 0.0  ; Euclidean dist to target when set (for give-up check)

    ; Initial heading: away from entry portal
    Local $heading
    If $sv_entry_portal_found Then
        $heading = SV_ATan2($sv_entry_y - $sv_entry_portal_y, $sv_entry_x - $sv_entry_portal_x)
    Else
        $heading = $PI / 2.0
    EndIf

    ; --- Loop-scope variables (hoisted to function scope - AutoIt requires this with MustDeclareVars) ---
    Local $foesToKill     = 0
    Local $me             = 0
    Local $myX            = 0.0
    Local $myY            = 0.0
    Local $cellKey        = ''
    Local $curCX          = 0
    Local $curCY          = 0
    Local $boxChanged     = False
    Local $isClear        = False
    Local $distToFrontier = 0.0
    Local $fKey           = ''
    Local $fx             = 0.0
    Local $fy             = 0.0
    Local $portals        = 0
    Local $targetX        = 0.0
    Local $targetY        = 0.0
    Local $newHeading     = 0.0
    Local $escX           = 0.0
    Local $escY           = 0.0
    Local $combatInterrupted = False
    Local $wallHit        = False
    Local $subSteps       = 4
    Local $dirX           = 0.0
    Local $dirY           = 0.0
    Local $lastSafeX      = 0.0
    Local $lastSafeY      = 0.0
    Local $fracX          = 0.0
    Local $fracY          = 0.0
    Local $escAngle       = 0.0
    Local $escX2          = 0.0
    Local $escY2          = 0.0
    Local $escPortals     = 0
    Local $escFound       = False
    Local $escTry         = 0
    Local $tryAngle       = 0.0
    Local $s              = 0
    Local $portalCorneredCount = 0   ; consecutive cornered-while-portal-blocked events

    While IsPlayerAlive() And Not SV_ConfirmVanquished()

        ; Track the highest foes-to-kill count seen so we can trust a zero later
        $foesToKill = GetFoesToKill()
        If $foesToKill > $sv_max_foes_seen Then $sv_max_foes_seen = $foesToKill

        If CheckStuck('Roomba', $SV_FARM_DURATION) == $FAIL Then Return $FAIL

        ; Death / wipe handling
        If IsPlayerDead() Or IsPlayerAndPartyWiped() Then
            If Not SV_WaitUntilAlive() Then Return $FAIL
            $hasResume   = False
            $hasFrontier = False   ; recompute target from new position (shrine may be far away)
            ContinueLoop
        EndIf

        If SV_CombatCheck() == $FAIL Then Return $FAIL

        $me  = GetMyAgent()
        $myX = DllStructGetData($me, 'X')
        $myY = DllStructGetData($me, 'Y')

        ; Mark current cell visited and update the incremental frontier set
        $cellKey = SV_CellKey($myX, $myY, $CELL)
        SV_MarkVisitedFrontier($cellKey, $visitedKeys, $visitedCount, $frontierKeys, $frontierCount, $MAX_VISITED, $CELL)

        ; Confirmed-clear check: if no foes within clear radius, mark this cell cleared
        If Not SV_IsVisitedBSearch($cellKey, $clearedKeys, $clearedCount) Then
            $isClear = (CountFoesInRangeOfAgent($me, $SV_CLEAR_CHECK_RADIUS) = 0)
            If $isClear Then
                SV_MarkVisitedSorted($cellKey, $clearedKeys, $clearedCount, $MAX_VISITED)
                SV_DBG('[SmartVanquisher] Cell (' & Round($myX) & ',' & Round($myY) & ') confirmed clear')
            EndIf
        EndIf

        ; ---- Bounding box expansion + sweep plan rebuild --------------------
        $curCX = Int($myX / $CELL)
        $curCY = Int($myY / $CELL)
        $boxChanged = False
        If Not $sweepBoxInited Then
            $sweepMinCX   = $curCX
            $sweepMaxCX   = $curCX
            $sweepMinCY   = $curCY
            $sweepMaxCY   = $curCY
            $sweepBoxInited = True
            $boxChanged   = True
        Else
            If $curCX < $sweepMinCX Then
                $sweepMinCX = $curCX - 1   ; expand one cell ahead of edge
                $boxChanged = True
            EndIf
            If $curCX > $sweepMaxCX Then
                $sweepMaxCX = $curCX + 1
                $boxChanged = True
            EndIf
            If $curCY < $sweepMinCY Then
                $sweepMinCY = $curCY - 1
                $boxChanged = True
            EndIf
            If $curCY > $sweepMaxCY Then
                $sweepMaxCY = $curCY + 1
                $boxChanged = True
            EndIf
        EndIf

        If $boxChanged Then
            SV_BuildSweepPlan($sweepMinCX, $sweepMaxCX, $sweepMinCY, $sweepMaxCY, $sweepPlanCX, $sweepPlanCY, $sweepPlanCount, $MAX_SWEEP)
            ; Fast-forward $sweepIdx to the waypoint nearest current position
            $sweepIdx = SV_SweepFastForward($sweepPlanCX, $sweepPlanCY, $sweepPlanCount, $curCX, $curCY, $clearedKeys, $clearedCount, $CELL)
            $hasFrontier = False   ; target will be recomputed below
            ; If plan has uncleared work remaining, restore sweep mode
            ; (bbox expansion after BFS fallback should resume the sweep)
            If $sweepIdx < $sweepPlanCount Then $sweepMode = True
            Info('[SmartVanquisher] Sweep plan rebuilt: ' & $sweepPlanCount & ' waypoints, bbox=[' & $sweepMinCX & '..' & $sweepMaxCX & ', ' & $sweepMinCY & '..' & $sweepMaxCY & '] sweepIdx=' & $sweepIdx)
        EndIf

        ; ---- Target management ----------------------------------------------
        If $hasFrontier Then
            $distToFrontier = SV_Dist($myX, $myY, $frontierX, $frontierY)

            ; Reach threshold: must be physically inside the cell ($CELL/2 = 250).
            ; Using 1.5x was too large - targets ~500 units away were considered
            ; "reached" after every bounce without the bot actually arriving.
            If $distToFrontier < $CELL / 2 Then
                ; Reached current waypoint - advance sweep index
                If $sweepMode Then $sweepIdx += 1
                $hasFrontier = False
                $bouncesSinceTarget = 0
                SV_DBG('[SmartVanquisher] Waypoint reached')
            ElseIf $bouncesSinceTarget >= $SV_FRONTIER_GIVE_UP_BOUNCES And _
                   $distToFrontier > $distAtTargetSet - $CELL Then
                If $sweepMode Then
                    Warn('[SmartVanquisher] Sweep waypoint (' & Round($frontierX) & ',' & Round($frontierY) & ') unreachable after ' & $bouncesSinceTarget & ' bounces - skipping')
                    $sweepIdx += 1
                Else
                    Warn('[SmartVanquisher] Fallback target (' & Round($frontierX) & ',' & Round($frontierY) & ') unreachable after ' & $bouncesSinceTarget & ' bounces - abandoning')
                    $fKey = SV_CellKey($frontierX, $frontierY, $CELL)
                    SV_MarkVisited($fKey, $abandonedKeys, $abandonedCount, $MAX_VISITED)
                    SV_RemoveFromFrontier($fKey, $frontierKeys, $frontierCount)
                    SV_MarkVisited($fKey, $visitedKeys, $visitedCount, $MAX_VISITED)
                EndIf
                $hasFrontier = False
                $bouncesSinceTarget = 0
            EndIf
        EndIf

        ; ---- Pick next target -----------------------------------------------
        If Not $hasFrontier Then
            If $sweepMode Then
                ; Advance past already-cleared waypoints.
                ; Skip the spawn cell on the first pass - it is marked cleared at
                ; startup before any enemies are engaged, so skipping it would
                ; cause the sweep to exhaust immediately on a 1-waypoint plan.
                ; We only skip a cleared cell if the plan has more than 1 waypoint
                ; (i.e. the bbox has expanded beyond the spawn cell).
                While $sweepIdx < $sweepPlanCount
                    $fKey = $sweepPlanCX[$sweepIdx] & ',' & $sweepPlanCY[$sweepIdx]
                    If SV_IsVisitedBSearch($fKey, $clearedKeys, $clearedCount) Then
                        $sweepIdx += 1
                    Else
                        ExitLoop
                    EndIf
                WEnd

                If $sweepIdx < $sweepPlanCount Then
                    ; Target the next sweep waypoint (world centre of cell)
                    $frontierX = ($sweepPlanCX[$sweepIdx] * $CELL) + ($CELL / 2.0)
                    $frontierY = ($sweepPlanCY[$sweepIdx] * $CELL) + ($CELL / 2.0)
                    $hasFrontier = True
                    $distAtTargetSet = SV_Dist($myX, $myY, $frontierX, $frontierY)
                    $bouncesSinceTarget = 0
                    $heading = SV_ATan2($frontierY - $myY, $frontierX - $myX)
                    $hasResume = False
                    Info('[SmartVanquisher] Sweep waypoint ' & $sweepIdx & '/' & $sweepPlanCount & ': (' & Round($frontierX) & ',' & Round($frontierY) & ') dist=' & Round($distAtTargetSet))
                Else
                    ; Sweep exhausted
                    If GetFoesToKill() > 0 And $sv_max_foes_seen > 0 Then
                        Warn('[SmartVanquisher] Sweep complete but ' & GetFoesToKill() & ' foes remain - switching to BFS fallback')
                        $sweepMode = False
                    Else
                        SV_DBG('[SmartVanquisher] Sweep complete - checking vanquish')
                        ContinueLoop
                    EndIf
                EndIf
            EndIf

            ; BFS fallback mode (sweep exhausted, enemies remain)
            If Not $sweepMode Then
                If SV_FindFrontierTarget($myX, $myY, $heading, $frontierKeys, $frontierCount, $visitedKeys, $visitedCount, $clearedKeys, $clearedCount, $abandonedKeys, $abandonedCount, $CELL, $fx, $fy) Then
                    $frontierX = $fx
                    $frontierY = $fy
                    $hasFrontier = True
                    $distAtTargetSet = SV_Dist($myX, $myY, $frontierX, $frontierY)
                    $bouncesSinceTarget = 0
                    $heading = SV_ATan2($frontierY - $myY, $frontierX - $myX)
                    $hasResume = False
                    Info('[SmartVanquisher] BFS fallback target: (' & Round($frontierX) & ',' & Round($frontierY) & ') dist=' & Round($distAtTargetSet))
                Else
                    SV_DBG('[SmartVanquisher] No fallback frontier cells - zone should be covered')
                    ContinueLoop
                EndIf
            EndIf
        EndIf

        ; Determine next waypoint
        $portals = SV_GetPortalAgents()
        If $hasResume Then
            $targetX   = $resumeX
            $targetY   = $resumeY
            $hasResume = False
            SV_DBG('[SmartVanquisher] Resuming to saved waypoint (' & Round($targetX) & ',' & Round($targetY) & ')')
        Else
            If Not SV_DirectionOpen($myX, $myY, $heading, $portals) Then
                SV_DBG('[SmartVanquisher] Portal ahead - bouncing')
                $newHeading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull, $frontierX, $frontierY, $hasFrontier)
                If $newHeading = $heading Then
                    $portalBlockedCount += 1
                    If $portalBlockedCount >= 4 Then
                        Warn('[SmartVanquisher] Portal-caged (' & $portalBlockedCount & ' consecutive) - retreating')
                        TryToGetUnstuck($myX, $myY, 8000)
                        $hasFrontier        = False
                        $portalBlockedCount = 0
                        $wallOnStep1Count   = 0
                        $hasResume          = False
                        ContinueLoop
                    EndIf
                    $escX = $myX + 300 * Cos($newHeading)
                    $escY = $myY + 300 * Sin($newHeading)
                    SV_MoveTo($escX, $escY, 3)
                Else
                    $portalBlockedCount = 0
                EndIf
                $heading = $newHeading
                ; Fall through to movement with the new heading - do NOT ContinueLoop here
                ; or the bot will spin forever rechecking portals without ever moving
            Else
                $portalBlockedCount = 0   ; clean direction - reset cage counter
            EndIf
            $targetX = $myX + $SV_BOUNCE_STEP * Cos($heading)
            $targetY = $myY + $SV_BOUNCE_STEP * Sin($heading)
        EndIf

        ; Record heading into history buffer
        $headingHistory[$headingHistoryIdx] = $heading
        $headingHistoryIdx = Mod($headingHistoryIdx + 1, $HEADING_HISTORY_SIZE)
        If $headingHistoryIdx = 0 Then $headingHistoryFull = True

        ; Walk toward waypoint in sub-steps
        $combatInterrupted = False
        $wallHit           = False
        $subSteps          = 4
        $dirX  = ($targetX - $myX)
        $dirY  = ($targetY - $myY)
        $lastSafeX = $myX
        $lastSafeY = $myY

        For $s = 1 To $subSteps
            If Not IsPlayerAlive() Then ExitLoop
            If IsPlayerAndPartyWiped() Then ExitLoop

            If CountFoesInRangeOfAgent(GetMyAgent(), $SV_AGGRO_RANGE) > 0 Then
                $resumeX   = $targetX
                $resumeY   = $targetY
                $hasResume = True
                $combatInterrupted = True
                SV_DBG('[SmartVanquisher] Foes detected mid-step - stopping to fight')
                ExitLoop
            EndIf

            $fracX = $myX + ($dirX * $s / $subSteps)
            $fracY = $myY + ($dirY * $s / $subSteps)

            If Not SV_MoveTo($fracX, $fracY) Then
                If GetMapID() <> $sv_map_id Then
                    Warn('[SmartVanquisher] Accidentally entered portal - learning location (' & Round($lastSafeX) & ',' & Round($lastSafeY) & ')')
                    SV_LearnDangerZone($lastSafeX, $lastSafeY)
                    Resign()
                    Sleep(3500)
                    ReturnToOutpost()
                    WaitMapLoading(-1, 10000, 1000)
                    Return $FAIL
                EndIf
                SV_DBG('[SmartVanquisher] Wall hit at sub-step ' & $s & ' - bouncing')
                If $s = 1 Then
                    $wallOnStep1Count += 1
                Else
                    $wallOnStep1Count = 0
                EndIf
                $wallHit = True
                ExitLoop
            EndIf

            If GetMapID() <> $sv_map_id Then
                Warn('[SmartVanquisher] Zoned unexpectedly mid-step - learning location (' & Round($lastSafeX) & ',' & Round($lastSafeY) & ')')
                SV_LearnDangerZone($lastSafeX, $lastSafeY)
                Resign()
                Sleep(3500)
                ReturnToOutpost()
                WaitMapLoading(-1, 10000, 1000)
                Return $FAIL
            EndIf

            $me  = GetMyAgent()
            $myX = DllStructGetData($me, 'X')
            $myY = DllStructGetData($me, 'Y')
            $lastSafeX = $myX
            $lastSafeY = $myY

            If SV_NearAnyPortal($myX, $myY, $portals) Then
                Warn('[SmartVanquisher] Too close to portal after sub-step - bouncing away')
                ; Learn this location as a danger zone so future runs avoid approaching here
                SV_LearnDangerZoneNearPortal($myX, $myY, $portals)
                $wallHit = True
                ExitLoop
            EndIf
        Next

        If $combatInterrupted Then
            If SV_CombatCheck() == $FAIL Then Return $FAIL
            $wallOnStep1Count   = 0
            $portalBlockedCount = 0
            $hasFrontier        = False
            ContinueLoop
        EndIf

        If $wallHit Then
            $bouncesSinceTarget += 1
            If $wallOnStep1Count >= 6 Then
                Warn('[SmartVanquisher] Cornered (' & $wallOnStep1Count & ' consecutive step-1 walls) - calling TryToGetUnstuck')
                ; Pick a portal-safe escape angle - try all 8 compass directions
                ; and use the first one that SV_DirectionOpen approves
                $escAngle = (Random(0, 7, 1) * $PI / 4.0)   ; random start to avoid always trying same order
                Local $escPortals = SV_GetPortalAgents()
                Local $escFound = False
                Local $escTry = 0
                For $escTry = 0 To 7
                    Local $tryAngle = $escAngle + ($escTry * $PI / 4.0)
                    If SV_DirectionOpen($myX, $myY, $tryAngle, $escPortals) Then
                        $escAngle = $tryAngle
                        $escFound = True
                        ExitLoop
                    EndIf
                Next
                If Not $escFound Then
                    ; All directions portal-blocked while cornered - count consecutive events
                    $portalCorneredCount += 1
                    Warn('[SmartVanquisher] No portal-safe escape angle found - using random (portal risk) [' & $portalCorneredCount & ']')
                    ; Learn this position so future runs don't approach here
                    SV_LearnDangerZoneNearPortal($myX, $myY, $escPortals)
                    If $portalCorneredCount >= 3 Then
                        ; Completely stuck in a portal cage - abandon current waypoint and
                        ; pick a fresh target far away to break out of the area
                        Warn('[SmartVanquisher] Portal-caged ' & $portalCorneredCount & ' times - abandoning current waypoint')
                        If $sweepMode Then
                            $sweepIdx += 1   ; skip this waypoint in the sweep
                        Else
                            $fKey = SV_CellKey($frontierX, $frontierY, $CELL)
                            SV_MarkVisited($fKey, $abandonedKeys, $abandonedCount, $MAX_VISITED)
                            SV_RemoveFromFrontier($fKey, $frontierKeys, $frontierCount)
                        EndIf
                        $hasFrontier        = False
                        $portalCorneredCount = 0
                        $wallOnStep1Count   = 0
                        $hasResume          = False
                        ContinueLoop
                    EndIf
                Else
                    $portalCorneredCount = 0
                EndIf
                $escX2 = $myX + $RANGE_EARSHOT * 3 * Cos($escAngle)
                $escY2 = $myY + $RANGE_EARSHOT * 3 * Sin($escAngle)
                TryToGetUnstuck($escX2, $escY2, 8000)
                $heading            = $escAngle
                $wallOnStep1Count   = 0
                $hasFrontier        = False
                $hasResume          = False
                ContinueLoop
            EndIf
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL, $frontierKeys, $frontierCount)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull, $frontierX, $frontierY, $hasFrontier)
            $hasResume = False
            ContinueLoop
        EndIf

        If SV_Dist($myX, $myY, $targetX, $targetY) > $SV_BOUNCE_STEP * 1.5 Then
            SV_DBG('[SmartVanquisher] Did not reach waypoint - bouncing')
            $bouncesSinceTarget += 1
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL, $frontierKeys, $frontierCount)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull, $frontierX, $frontierY, $hasFrontier)
            $hasResume = False
            ContinueLoop
        EndIf

        $wallOnStep1Count   = 0
        $portalBlockedCount = 0
        $portalCorneredCount = 0
        RandomSleep(80)
    WEnd

    Return $SUCCESS
EndFunc


; ===========================================================================
; BOUSTROPHEDON SWEEP PLAN
;
; Generates a row-by-row lawnmower waypoint sequence from a cell-grid
; bounding box. Rows advance northward (increasing CY). Even rows sweep
; west→east (increasing CX), odd rows east→west (decreasing CX).
;
; Outputs cell-grid coordinates (not world coords) into parallel arrays.
; The caller converts to world coords by: worldX = (CX * CELL) + CELL/2
; ===========================================================================

Func SV_BuildSweepPlan($minCX, $maxCX, $minCY, $maxCY, ByRef $planCX, ByRef $planCY, ByRef $planCount, $maxPlan)
    $planCount = 0
    Local $row = 0
    Local $cy  = 0
    Local $cx  = 0
    For $cy = $minCY To $maxCY
        $row = $cy - $minCY   ; 0-based row index - determines direction
        If Mod($row, 2) = 0 Then
            ; Even row: west → east
            For $cx = $minCX To $maxCX
                If $planCount >= $maxPlan Then ExitLoop
                $planCX[$planCount] = $cx
                $planCY[$planCount] = $cy
                $planCount += 1
            Next
        Else
            ; Odd row: east → west
            For $cx = $maxCX To $minCX Step -1
                If $planCount >= $maxPlan Then ExitLoop
                $planCX[$planCount] = $cx
                $planCY[$planCount] = $cy
                $planCount += 1
            Next
        EndIf
        If $planCount >= $maxPlan Then ExitLoop
    Next
EndFunc


; Find the best index to resume the sweep from after a plan rebuild.
; Skips all waypoints already confirmed clear, then returns the index of
; the waypoint nearest to the bot's current cell (curCX, curCY).
; Falls back to 0 if everything is cleared (sweep effectively done).
Func SV_SweepFastForward(ByRef $planCX, ByRef $planCY, $planCount, $curCX, $curCY, ByRef $clearedKeys, $clearedCount, $cellSize)
    ; Find the nearest uncleared waypoint to start from.
    ; Never return $planCount on a 1-waypoint plan - the spawn cell is marked
    ; cleared before the first plan is built, and fast-forwarding past it would
    ; exhaust the plan immediately, dropping straight to BFS fallback.
    ; Minimum return value is 0 when the plan has only one waypoint.
    Local $bestIdx  = $planCount   ; default: plan exhausted
    Local $bestDist = 1000000000
    Local $i = 0
    For $i = 0 To $planCount - 1
        Local $fKey = $planCX[$i] & ',' & $planCY[$i]
        If SV_IsVisitedBSearch($fKey, $clearedKeys, $clearedCount) And $planCount > 1 Then ContinueLoop
        Local $dx = $planCX[$i] - $curCX
        Local $dy = $planCY[$i] - $curCY
        Local $d  = $dx * $dx + $dy * $dy   ; squared cell distance - no sqrt needed
        If $d < $bestDist Then
            $bestDist = $d
            $bestIdx  = $i
        EndIf
    Next
    Return $bestIdx
EndFunc


; ===========================================================================
; FRONTIER SET HELPERS
;
; The frontier set is maintained incrementally alongside the visited set.
; A cell is in the frontier if it is visited and has at least one unvisited
; 8-directional neighbour.  Instead of deriving this on every call to
; SV_FindFrontierTarget (O(n^2)), we maintain it as cells are marked visited.
; ===========================================================================

; Mark a cell visited and update the frontier set:
;   - Add the cell to visitedKeys
;   - Remove it from frontierKeys (it's no longer a boundary)
;   - For each of its 8 neighbours: if the neighbour is visited and now has
;     this cell as its only unvisited neighbour removed, re-check and remove
;     if fully surrounded.  If the neighbour is unvisited, add the current
;     cell to the frontier (it borders unexplored space).
Func SV_MarkVisitedFrontier(ByRef $key, ByRef $visitedKeys, ByRef $visitedCount, ByRef $frontierKeys, ByRef $frontierCount, $maxCount, $cellSize)
    If SV_IsVisitedBSearch($key, $visitedKeys, $visitedCount) Then Return

    ; Add to visited (sorted insert for O(log n) lookup)
    SV_MarkVisitedSorted($key, $visitedKeys, $visitedCount, $maxCount)

    ; Remove from frontier (it's now fully interior if all neighbours visited)
    SV_RemoveFromFrontier($key, $frontierKeys, $frontierCount)

    ; Parse cell coords from key
    Local $parts = StringSplit($key, ',')
    If $parts[0] <> 2 Then Return
    Local $cx = Int($parts[1])
    Local $cy = Int($parts[2])

    ; Hoisted out of loop (MustDeclareVars requirement)
    Local $DX[8] = [1,-1,0,0,1,1,-1,-1]
    Local $DY[8] = [0,0,1,-1,1,-1,1,-1]
    Local $hasUnvisitedNeighbour = False
    Local $nKey = ''
    Local $d = 0

    For $d = 0 To 7
        $nKey = ($cx + $DX[$d]) & ',' & ($cy + $DY[$d])
        If Not SV_IsVisitedBSearch($nKey, $visitedKeys, $visitedCount) Then
            $hasUnvisitedNeighbour = True
        Else
            SV_UpdateFrontierCell($nKey, $cx + $DX[$d], $cy + $DY[$d], $visitedKeys, $visitedCount, $frontierKeys, $frontierCount, $maxCount)
        EndIf
    Next

    If $hasUnvisitedNeighbour Then
        SV_AddToFrontier($key, $frontierKeys, $frontierCount, $maxCount)
    EndIf
EndFunc


; Re-evaluate whether a visited cell should be in the frontier.
; Called when one of its neighbours just became visited.
Func SV_UpdateFrontierCell(ByRef $key, $cx, $cy, ByRef $visitedKeys, $visitedCount, ByRef $frontierKeys, ByRef $frontierCount, $maxCount)
    Local $DX2[8] = [1,-1,0,0,1,1,-1,-1]
    Local $DY2[8] = [0,0,1,-1,1,-1,1,-1]
    Local $stillFrontier = False
    Local $nKey = ''
    Local $d = 0

    For $d = 0 To 7
        $nKey = ($cx + $DX2[$d]) & ',' & ($cy + $DY2[$d])
        If Not SV_IsVisitedBSearch($nKey, $visitedKeys, $visitedCount) Then
            $stillFrontier = True
            ExitLoop
        EndIf
    Next
    If $stillFrontier Then
        SV_AddToFrontier($key, $frontierKeys, $frontierCount, $maxCount)
    Else
        SV_RemoveFromFrontier($key, $frontierKeys, $frontierCount)
    EndIf
EndFunc


; Add a key to the frontier set if not already present
Func SV_AddToFrontier(ByRef $key, ByRef $frontierKeys, ByRef $frontierCount, $maxCount)
    For $i = 0 To $frontierCount - 1
        If $frontierKeys[$i] = $key Then Return
    Next
    If $frontierCount < $maxCount Then
        $frontierKeys[$frontierCount] = $key
        $frontierCount += 1
    EndIf
EndFunc


; Remove a key from the frontier set (swap-with-last for O(1) removal)
Func SV_RemoveFromFrontier(ByRef $key, ByRef $frontierKeys, ByRef $frontierCount)
    For $i = 0 To $frontierCount - 1
        If $frontierKeys[$i] = $key Then
            $frontierCount -= 1
            $frontierKeys[$i] = $frontierKeys[$frontierCount]
            $frontierKeys[$frontierCount] = ''
            Return
        EndIf
    Next
EndFunc


; ===========================================================================
; BFS THROUGH VISITED CELLS
;
; Computes the navigable hop-distance from the bot's current cell to every
; frontier cell by doing a breadth-first search through the visited cell
; graph. Two visited cells are adjacent if their grid coordinates differ by
; at most 1 in each axis (8-connectivity), matching the frontier definition.
;
; Returns two parallel arrays:
;   $outDists[$frontierCount]  - hop distance to each frontier cell
;                                ($SV_BFS_UNREACHABLE if not reachable)
;   $outAngles[$frontierCount] - angle from bot to that frontier cell (radians)
;
; The BFS visits at most $visitedCount cells so cost is O(V log V) due to
; binary search lookups.  Called only when a new frontier target is needed.
; ===========================================================================
Global Const $SV_BFS_UNREACHABLE = 999999

Func SV_BFSFrontierDistances($myX, $myY, ByRef $frontierKeys, $frontierCount, ByRef $visitedKeys, $visitedCount, $cellSize, ByRef $outDists, ByRef $outAngles)
    ; Start cell
    Local $startKey = SV_CellKey($myX, $myY, $cellSize)

    ; Distance map: index = position in visitedKeys (binary search gives index)
    ; We use a flat array sized to MAX_VISITED; unvisited slots = -1
    Local $distMap[$visitedCount]
    Local $di = 0
    For $di = 0 To $visitedCount - 1
        $distMap[$di] = -1
    Next

    ; BFS queue: store (key_index_in_visitedKeys) as integers
    Local $queue[$visitedCount]
    Local $qHead = 0
    Local $qTail = 0

    ; Seed the queue with the start cell
    Local $startIdx = SV_BSearchIndex($startKey, $visitedKeys, $visitedCount)
    If $startIdx < 0 Then
        ; Bot is in an unvisited cell (e.g. just after death/respawn) - fall back
        ; to straight-line distance for all frontier cells
        Local $fi = 0
        For $fi = 0 To $frontierCount - 1
            Local $fparts = StringSplit($frontierKeys[$fi], ',')
            If $fparts[0] = 2 Then
                Local $fwx = (Int($fparts[1]) * $cellSize) + ($cellSize / 2.0)
                Local $fwy = (Int($fparts[2]) * $cellSize) + ($cellSize / 2.0)
                Local $hops = Int(SV_Dist($myX, $myY, $fwx, $fwy) / $cellSize) + 1
                $outDists[$fi]  = $hops
                $outAngles[$fi] = SV_ATan2($fwy - $myY, $fwx - $myX)
            Else
                $outDists[$fi]  = $SV_BFS_UNREACHABLE
                $outAngles[$fi] = 0.0
            EndIf
        Next
        Return
    EndIf

    $distMap[$startIdx] = 0
    $queue[$qTail] = $startIdx
    $qTail += 1

    ; Build a lookup: frontierKey -> index in frontierKeys array
    ; We'll mark off found frontier cells to know when to stop early
    Local $frontierFound = 0

    ; Pre-compute frontier key index map: for each frontier cell store its
    ; index in visitedKeys (or -1 if not in visited - means it's unvisited border)
    Local $frontierVisitedIdx[$frontierCount]
    Local $fvi = 0
    For $fvi = 0 To $frontierCount - 1
        $frontierVisitedIdx[$fvi] = SV_BSearchIndex($frontierKeys[$fvi], $visitedKeys, $visitedCount)
        $outDists[$fvi]  = $SV_BFS_UNREACHABLE
        $outAngles[$fvi] = 0.0
    Next

    Local $DX[8] = [1,-1,0,0,1,1,-1,-1]
    Local $DY[8] = [0,0,1,-1,1,-1,1,-1]

    ; BFS main loop
    Local $bfi = 0
    While $qHead < $qTail
        Local $curIdx  = $queue[$qHead]
        $qHead += 1
        Local $curDist = $distMap[$curIdx]

        ; Parse current cell coords from key
        Local $curParts = StringSplit($visitedKeys[$curIdx], ',')
        If $curParts[0] <> 2 Then ContinueLoop
        Local $cx = Int($curParts[1])
        Local $cy = Int($curParts[2])

        ; Check if this cell is a frontier cell and record its distance
        For $bfi = 0 To $frontierCount - 1
            If $frontierVisitedIdx[$bfi] = $curIdx Then
                $outDists[$bfi] = $curDist
                Local $fwx2 = ($cx * $cellSize) + ($cellSize / 2.0)
                Local $fwy2 = ($cy * $cellSize) + ($cellSize / 2.0)
                $outAngles[$bfi] = SV_ATan2($fwy2 - $myY, $fwx2 - $myX)
                $frontierFound += 1
                ExitLoop
            EndIf
        Next

        ; Early exit if all frontier cells reached
        If $frontierFound >= $frontierCount Then ExitLoop

        ; Expand neighbours
        Local $nd = 0
        For $nd = 0 To 7
            Local $nKey2 = ($cx + $DX[$nd]) & ',' & ($cy + $DY[$nd])
            Local $nIdx  = SV_BSearchIndex($nKey2, $visitedKeys, $visitedCount)
            If $nIdx < 0 Then ContinueLoop        ; unvisited = wall, skip
            If $distMap[$nIdx] >= 0 Then ContinueLoop  ; already visited in BFS
            $distMap[$nIdx] = $curDist + 1
            If $qTail < $visitedCount Then
                $queue[$qTail] = $nIdx
                $qTail += 1
            EndIf
        Next
    WEnd
EndFunc


; Binary search returning the array INDEX of $key in sorted $keys, or -1 if absent
Func SV_BSearchIndex(ByRef $key, ByRef $keys, $count)
    If $count = 0 Then Return -1
    Local $lo = 0, $hi = $count - 1
    While $lo <= $hi
        Local $mid = Int(($lo + $hi) / 2)
        If $keys[$mid] = $key Then Return $mid
        If $keys[$mid] < $key Then
            $lo = $mid + 1
        Else
            $hi = $mid - 1
        EndIf
    WEnd
    Return -1
EndFunc


; ===========================================================================
; FRONTIER TARGET SELECTION
;
; Uses BFS through the visited cell graph to get true navigable hop-distances
; to all frontier cells, combined with a momentum term that penalises large
; heading changes. This avoids targeting cells that are geometrically close
; but separated by walls, and keeps the bot sweeping in coherent arcs.
;
; Scoring (lower = better):
;   score = hopDist + momentum_penalty
;   momentum_penalty = (angularDiff / PI) * $SV_MOMENTUM_WEIGHT * hopDist
;
; Priority order (same as before):
;   1. Visited but NOT yet confirmed clear (enemies may be present)
;   2. Unvisited frontier cells
;
; Abandoned cells are skipped in both passes.
; ===========================================================================

Func SV_FindFrontierTarget($myX, $myY, $currentHeading, ByRef $frontierKeys, $frontierCount, ByRef $visitedKeys, $visitedCount, ByRef $clearedKeys, $clearedCount, ByRef $abandonedKeys, $abandonedCount, $cellSize, ByRef $outX, ByRef $outY)
    Local Const $PI = 3.14159265358979

    If $frontierCount = 0 Then Return False

    ; Run BFS to get navigable hop-distances to all frontier cells
    Local $bfsDists[$frontierCount]
    Local $bfsAngles[$frontierCount]
    SV_BFSFrontierDistances($myX, $myY, $frontierKeys, $frontierCount, $visitedKeys, $visitedCount, $cellSize, $bfsDists, $bfsAngles)

    Local $bestScore      = 1000000000
    Local $bestScoreClear = 1000000000
    Local $found          = False
    Local $foundClear     = False
    Local $clearX         = 0.0
    Local $clearY         = 0.0

    Local $i = 0
    For $i = 0 To $frontierCount - 1
        Local $key = $frontierKeys[$i]
        If $key = '' Then ContinueLoop

        ; Skip abandoned cells
        If SV_IsVisited($key, $abandonedKeys, $abandonedCount) Then ContinueLoop

        ; Skip unreachable cells (BFS could not connect)
        If $bfsDists[$i] = $SV_BFS_UNREACHABLE Then ContinueLoop

        ; Parse cell coords for world position
        Local $parts = StringSplit($key, ',')
        If $parts[0] <> 2 Then ContinueLoop
        Local $wx = (Int($parts[1]) * $cellSize) + ($cellSize / 2.0)
        Local $wy = (Int($parts[2]) * $cellSize) + ($cellSize / 2.0)

        ; Momentum penalty: angular difference from current heading, normalised [0,1]
        Local $angleDiff = $bfsAngles[$i] - $currentHeading
        ; Normalise to [-PI, PI]
        While $angleDiff > $PI
            $angleDiff -= 2.0 * $PI
        WEnd
        While $angleDiff < -$PI
            $angleDiff += 2.0 * $PI
        WEnd
        If $angleDiff < 0 Then $angleDiff = -$angleDiff  ; abs
        Local $momentumPenalty = ($angleDiff / $PI) * $SV_MOMENTUM_WEIGHT * $bfsDists[$i]

        Local $score = $bfsDists[$i] + $momentumPenalty

        ; Priority 1: visited but not yet confirmed clear
        If SV_IsVisitedBSearch($key, $visitedKeys, $visitedCount) And _
           Not SV_IsVisitedBSearch($key, $clearedKeys, $clearedCount) Then
            If $score < $bestScoreClear Then
                $bestScoreClear = $score
                $clearX         = $wx
                $clearY         = $wy
                $foundClear     = True
            EndIf
            ContinueLoop
        EndIf

        ; Priority 2: unvisited frontier cell
        If $score < $bestScore Then
            $bestScore = $score
            $outX      = $wx
            $outY      = $wy
            $found     = True
        EndIf
    Next

    ; Uncleared visited cells take priority over unvisited ones
    If $foundClear Then
        $outX = $clearX
        $outY = $clearY
        Return True
    EndIf

    Return $found
EndFunc



; Pick a new heading after a bounce.
;
; Scoring has three components (all combined into a single float score):
;
;   1. UNVISITED CELL LOOKAHEAD (0-5)
;      Count unvisited cells along 5 steps in the candidate direction.
;      Core coverage bias - prefer heading into unexplored areas.
;
;   2. REFLECTION BONUS (+0.0 to +2.0)
;      A real ball bounces at angle of incidence = angle of reflection.
;      The ideal reflection off a wall is ~90deg from the blocked heading.
;      Candidates closer to 90deg get a bonus, further away get less.
;      This keeps forward momentum rather than reversing.
;        +-45deg  -> +0.5 bonus  (nearly forward, slight deflection)
;        +-90deg  -> +2.0 bonus  (ideal reflection, most ball-like)
;        +-135deg -> +0.5 bonus  (steep deflection, less preferred)
;        180deg   -> +0.0 bonus  (reverse, no bonus - last resort only)
;
;   3. HEADING HISTORY PENALTY (-0.0 to -3.0)
;      Candidates within 30deg of any recently used heading get a penalty.
;      Breaks ping-pong: if we just went 90deg and bounce back to 90deg,
;      that candidate is penalised and a fresh direction scores better.
;
Func SV_PickBounceHeading($myX, $myY, $blockedHeading, ByRef $visitedKeys, $visitedCount, $cellSize, ByRef $headingHistory, $headingHistoryFull, $frontierX = 0, $frontierY = 0, $hasFrontier = False)
    Local Const $PI         = 3.14159265358979
    Local Const $DEG30      = $PI / 6.0       ; 30deg in radians - history penalty threshold
    Local Const $HISTORY_PENALTY = 3.0        ; score penalty for recently used headings
    Local Const $PINGPONG_PENALTY = 4.0       ; extra penalty for near-exact reversal of recent heading
    Local Const $FRONTIER_BONUS  = 3.0        ; bonus for heading that closes distance to frontier target
    Local $portals = SV_GetPortalAgents()

    ; Candidates: +-45, +-90, +-135 relative to blocked heading.
    ; Ordered by reflection quality: 90deg first (most ball-like), then 45, then 135.
    ; 180 (reverse) is the fallback only - never a scored candidate.
    Local $offsets[6]
    $offsets[0] =  $PI / 2.0         ;  90 left  - ideal reflection
    $offsets[1] = -$PI / 2.0         ;  90 right - ideal reflection
    $offsets[2] =  $PI / 4.0         ;  45 left  - slight deflection
    $offsets[3] = -$PI / 4.0         ;  45 right - slight deflection
    $offsets[4] =  $PI * 3.0 / 4.0   ; 135 left  - steep deflection
    $offsets[5] = -$PI * 3.0 / 4.0   ; 135 right - steep deflection

    ; Reflection bonus by offset magnitude (how ball-like is this bounce?)
    Local $reflectionBonus[6]
    $reflectionBonus[0] = 2.0   ;  90 left
    $reflectionBonus[1] = 2.0   ;  90 right
    $reflectionBonus[2] = 0.5   ;  45 left
    $reflectionBonus[3] = 0.5   ;  45 right
    $reflectionBonus[4] = 0.5   ; 135 left
    $reflectionBonus[5] = 0.5   ; 135 right

    ; Fallback: reverse direction, with no bonus and will only be used if
    ; all candidates are blocked by portals or danger zones
    Local $bestHeading = SV_WrapAngle($blockedHeading + $PI)
    Local $bestScore   = -9999.0
    Local $bestFallbackHeading = $bestHeading   ; least-bad option if all blocked
    Local $bestFallbackClearance = -1.0         ; min portal clearance for least-bad option

    For $i = 0 To 5
        Local $candidate = SV_WrapAngle($blockedHeading + $offsets[$i])

        If Not SV_DirectionOpen($myX, $myY, $candidate, $portals) Then
            ; Track the least-blocked direction as an emergency fallback
            ; Score by minimum clearance along the path (higher = less overlap)
            Local $minClear = 1000000.0
            For $frac = 1 To 4
                Local $fdx = $myX + ($SV_BOUNCE_STEP * $frac / 4.0) * Cos($candidate)
                Local $fdy = $myY + ($SV_BOUNCE_STEP * $frac / 4.0) * Sin($candidate)
                For $j = 0 To $sv_danger_zone_count - 1
                    Local $dz = SV_Dist($fdx, $fdy, $sv_danger_zones[$j][0], $sv_danger_zones[$j][1])
                    If $dz < $minClear Then $minClear = $dz
                Next
                For $pa In $portals
                    Local $pd = SV_Dist($fdx, $fdy, DllStructGetData($pa,'X'), DllStructGetData($pa,'Y'))
                    If $pd < $minClear Then $minClear = $pd
                Next
            Next
            If $minClear > $bestFallbackClearance Then
                $bestFallbackClearance = $minClear
                $bestFallbackHeading   = $candidate
            EndIf
            ContinueLoop
        EndIf

        ; Component 1: unvisited cell lookahead
        Local $cellScore = 0
        For $step = 1 To 5
            Local $lx = $myX + ($step * $cellSize) * Cos($candidate)
            Local $ly = $myY + ($step * $cellSize) * Sin($candidate)
            If Not SV_IsVisitedBSearch(SV_CellKey($lx, $ly, $cellSize), $visitedKeys, $visitedCount) Then $cellScore += 1
        Next

        ; Component 2: reflection bonus - prefer staying close to 90deg bounce
        Local $bonus = $reflectionBonus[$i]

        ; Component 3: heading history penalty - penalise recently used headings
        Local $histPenalty = 0.0
        Local $histSize = UBound($headingHistory)
        For $h = 0 To $histSize - 1
            If $headingHistory[$h] = 9999.0 Then ContinueLoop   ; empty slot
            Local $angDiff = Abs(SV_WrapAngle($candidate - $headingHistory[$h]))
            If $angDiff < $DEG30 Then
                ; Very close to a recent heading - full penalty
                $histPenalty = $HISTORY_PENALTY
            ElseIf $angDiff > ($PI - $DEG30) Then
                ; Near-exact reversal of a recent heading - ping-pong penalty
                $histPenalty += $PINGPONG_PENALTY
            EndIf
        Next

        ; Component 4: frontier bias - bonus if this heading closes distance to frontier target
        Local $frontierBias = 0.0
        If $hasFrontier Then
            Local $stepX = $myX + $cellSize * Cos($candidate)
            Local $stepY = $myY + $cellSize * Sin($candidate)
            Local $distNow  = SV_Dist($myX,  $myY,  $frontierX, $frontierY)
            Local $distStep = SV_Dist($stepX, $stepY, $frontierX, $frontierY)
            If $distStep < $distNow Then $frontierBias = $FRONTIER_BONUS
        EndIf

        Local $totalScore = $cellScore + $bonus - $histPenalty + $frontierBias

        If $totalScore > $bestScore Then
            $bestScore   = $totalScore
            $bestHeading = $candidate
        EndIf
    Next

    ; If all scored candidates were portal-blocked, use least-bad emergency heading
    If $bestScore = -9999.0 Then
        $bestHeading = $bestFallbackHeading
        Warn('[SmartVanquisher] All directions portal-blocked - using least-bad heading ' & Round($bestHeading*180/$PI) & 'deg')
    EndIf

    SV_DBG('[SmartVanquisher] Bounce: ' & Round($blockedHeading*180/$PI) & 'deg blocked -> new=' & Round($bestHeading*180/$PI) & 'deg (score=' & Round($bestScore, 1) & ')')
    Return $bestHeading
EndFunc


; Mark all cells along a heading as visited so it scores 0 in future bounces.
Func SV_PoisonDirection($myX, $myY, $heading, ByRef $visitedKeys, ByRef $visitedCount, $maxCount, $cellSize, ByRef $frontierKeys, ByRef $frontierCount)
    For $step = 1 To 5
        Local $lx  = $myX + ($step * $cellSize) * Cos($heading)
        Local $ly  = $myY + ($step * $cellSize) * Sin($heading)
        Local $key = SV_CellKey($lx, $ly, $cellSize)
        SV_MarkVisitedFrontier($key, $visitedKeys, $visitedCount, $frontierKeys, $frontierCount, $maxCount, $cellSize)
    Next
EndFunc


; ===========================================================================
; VISITED CELL TRACKING
; ===========================================================================

Func SV_CellKey($x, $y, $cellSize)
    ; Encode grid cell as a string key
    Return Int($x / $cellSize) & ',' & Int($y / $cellSize)
EndFunc


; Insert $key into a sorted array (insertion sort - maintains sort order for binary search)
Func SV_MarkVisitedSorted(ByRef $key, ByRef $keys, ByRef $count, $maxCount)
    If SV_IsVisitedBSearch($key, $keys, $count) Then Return
    If $count >= $maxCount Then Return
    ; Find insertion position via binary search
    Local $lo = 0, $hi = $count
    While $lo < $hi
        Local $mid = Int(($lo + $hi) / 2)
        If $keys[$mid] < $key Then
            $lo = $mid + 1
        Else
            $hi = $mid
        EndIf
    WEnd
    ; Shift right to make room
    Local $i = 0
    For $i = $count To $lo + 1 Step -1
        $keys[$i] = $keys[$i - 1]
    Next
    $keys[$lo] = $key
    $count += 1
EndFunc


; O(log n) existence check via binary search on sorted array
Func SV_IsVisitedBSearch(ByRef $key, ByRef $keys, $count)
    If $count = 0 Then Return False
    Local $lo = 0, $hi = $count - 1
    While $lo <= $hi
        Local $mid = Int(($lo + $hi) / 2)
        If $keys[$mid] = $key Then Return True
        If $keys[$mid] < $key Then
            $lo = $mid + 1
        Else
            $hi = $mid - 1
        EndIf
    WEnd
    Return False
EndFunc


; Legacy linear wrapper - kept for abandoned/frontier sets which are small
; and use swap-with-last removal (can't maintain sort order)
Func SV_MarkVisited(ByRef $key, ByRef $keys, ByRef $count, $maxCount)
    If SV_IsVisited($key, $keys, $count) Then Return
    If $count < $maxCount Then
        $keys[$count] = $key
        $count += 1
    EndIf
EndFunc


Func SV_IsVisited(ByRef $key, ByRef $keys, $count)
    For $i = 0 To $count - 1
        If $keys[$i] = $key Then Return True
    Next
    Return False
EndFunc


; Fetch all zone-exit portal agents as a filtered array.
; Called once per wall-follow step and shared between SV_ChooseHeading and SV_DeflectFromPortals.
; The entry portal (the one we just came through) is excluded so the bot does not
; deflect away from its own spawn point.
Func SV_GetPortalAgents()
    Local $all  = GetAgentArray($ID_AGENT_TYPE_STATIC)
    Local $out[32]
    Local $n    = 0
    For $a In $all
        If Not SV_IsPortalAgent($a) Then ContinueLoop
        If $sv_entry_portal_found Then
            Local $px = DllStructGetData($a, 'X')
            Local $py = DllStructGetData($a, 'Y')
            If SV_Dist($px, $py, $sv_entry_portal_x, $sv_entry_portal_y) < 50 Then ContinueLoop
        EndIf
        If $n < 32 Then
            $out[$n] = $a
            $n += 1
        EndIf
    Next
    Local $result[$n]
    For $i = 0 To $n - 1
        $result[$i] = $out[$i]
    Next
    Return $result
EndFunc


; True if the entire path $SV_BOUNCE_STEP in $dir stays clear of all portals.
; Checks 4 intermediate points so a portal can't be straddled by a long step.
Func SV_DirectionOpen($myX, $myY, $dir, $portals)
    For $frac = 1 To 4
        Local $dx = $myX + ($SV_BOUNCE_STEP * $frac / 4.0) * Cos($dir)
        Local $dy = $myY + ($SV_BOUNCE_STEP * $frac / 4.0) * Sin($dir)
        For $a In $portals
            If SV_Dist($dx, $dy, DllStructGetData($a,'X'), DllStructGetData($a,'Y')) < $SV_PORTAL_SAFE_DIST Then
                Return False
            EndIf
        Next
        ; Also check against learned danger zones
        For $i = 0 To $sv_danger_zone_count - 1
            If SV_Dist($dx, $dy, $sv_danger_zones[$i][0], $sv_danger_zones[$i][1]) < $SV_DANGER_ZONE_RADIUS Then
                Return False
            EndIf
        Next
    Next
    Return True
EndFunc


; True if the player's current position is within portal safe distance of any portal
; or within danger zone radius of any learned danger zone.
Func SV_NearAnyPortal($myX, $myY, $portals)
    For $a In $portals
        If SV_Dist($myX, $myY, DllStructGetData($a,'X'), DllStructGetData($a,'Y')) < $SV_PORTAL_SAFE_DIST Then
            Return True
        EndIf
    Next
    For $i = 0 To $sv_danger_zone_count - 1
        If SV_Dist($myX, $myY, $sv_danger_zones[$i][0], $sv_danger_zones[$i][1]) < $SV_DANGER_ZONE_RADIUS Then
            Return True
        EndIf
    Next
    Return False
EndFunc


; Nudge $heading away from any portal within avoid radius that is roughly ahead.
; Accepts pre-fetched portal list - do not call SV_GetPortalAgents() again here.
Func SV_DeflectFromPortals($myX, $myY, $heading, $portals)
    Local Const $PI = 3.14159265358979
    For $a In $portals
        Local $ax = DllStructGetData($a, 'X')
        Local $ay = DllStructGetData($a, 'Y')
        If SV_Dist($myX, $myY, $ax, $ay) >= $SV_BOUNCE_STEP Then ContinueLoop
        Local $diff = SV_WrapAngle($heading - SV_ATan2($ay - $myY, $ax - $myX))
        If Abs($diff) < ($PI / 2.0) Then
            $heading = SV_WrapAngle($heading + (($diff > 0) ? ($PI / 3.0) : -($PI / 3.0)))
            Warn('[SmartVanquisher] Portal deflect @ (' & Round($ax) & ',' & Round($ay) & ')')
        EndIf
    Next
    Return $heading
EndFunc



; ===========================================================================
; DEATH HANDLING
; ===========================================================================

; Wait up to $timeoutMs for a hero to resurrect the player.
; Returns True if rezzed, False if timed out (full wipe or no rez hero).
; Wait until the player is alive again, then check if DP is safe to continue.
; Two paths:
;   - Hero with rez alive: wait up to 30s for in-place resurrection
;   - Full wipe / no rez:  wait up to 60s for GW automatic shrine respawn
; Returns True if alive and DP < $SV_MAX_DP_TO_CONTINUE (run should continue).
; Returns False if DP is too high (only option is return to town).
Func SV_WaitUntilAlive()
    If IsPlayerAndPartyWiped() Or Not HasRezMemberAlive() Then
        ; Full wipe - GW will auto-respawn at nearest shrine, just wait
        Warn('[SmartVanquisher] Party wiped - waiting for shrine respawn...')
        Local $timer = TimerInit()
        While IsPlayerDead() Or IsPlayerAndPartyWiped()
            If TimerDiff($timer) > 60000 Then
                Warn('[SmartVanquisher] Shrine respawn timeout - assuming stuck, pausing')
                Return False
            EndIf
            Sleep(500)
        WEnd
        Info('[SmartVanquisher] Respawned at shrine - checking DP...')
    Else
        ; Hero with rez available - wait for in-place resurrection
        Warn('[SmartVanquisher] Player dead - waiting for hero resurrection (up to 30s)...')
        Local $timer = TimerInit()
        While IsPlayerDead()
            If IsPlayerAndPartyWiped() Or Not HasRezMemberAlive() Then
                ; Heroes all died too - fall through to shrine wait
                Warn('[SmartVanquisher] Heroes wiped while waiting for rez - waiting for shrine respawn...')
                Local $timer2 = TimerInit()
                While IsPlayerDead() Or IsPlayerAndPartyWiped()
                    If TimerDiff($timer2) > 60000 Then
                        Warn('[SmartVanquisher] Shrine respawn timeout - pausing')
                        Return False
                    EndIf
                    Sleep(500)
                WEnd
                ExitLoop
            EndIf
            If TimerDiff($timer) > 30000 Then
                Warn('[SmartVanquisher] Rez timeout after 30s - waiting for shrine respawn...')
                Local $timer3 = TimerInit()
                While IsPlayerDead() Or IsPlayerAndPartyWiped()
                    If TimerDiff($timer3) > 60000 Then
                        Warn('[SmartVanquisher] Shrine respawn timeout - pausing')
                        Return False
                    EndIf
                    Sleep(500)
                WEnd
                ExitLoop
            EndIf
            Sleep(500)
        WEnd
        Info('[SmartVanquisher] Resurrected')
    EndIf

    ; Check DP - if too high the only option is return to outpost
    Local $dp = GetMorale()   ; 0 = no DP/morale, negative = DP
    If $dp <= $SV_MAX_DP_TO_CONTINUE Then
        Warn('[SmartVanquisher] ' & Abs($dp) & '% DP - too risky to continue, returning to outpost')
        Return False
    EndIf

    If $dp < 0 Then
        Warn('[SmartVanquisher] ' & Abs($dp) & '% DP - continuing run')
    Else
        Info('[SmartVanquisher] Alive and ready - resuming')
    EndIf
    Return True
EndFunc


; ===========================================================================
; COMBAT LOOP
; ===========================================================================

Func SV_CombatCheck()
    Local $me = GetMyAgent()
    Local $foeCount = CountFoesInRangeOfAgent($me, $SV_AGGRO_RANGE)
    If $foeCount = 0 Then Return $SUCCESS
    Info('[SmartVanquisher] Engaging ' & $foeCount & ' foes')
    If SV_CombatLoop() == $FAIL Then Return $FAIL
    RandomSleep($SV_POST_COMBAT_WAIT)
    If IsPlayerAlive() Then PickUpItems(Null, DefaultShouldPickItem, $SV_AGGRO_RANGE)
    Return $SUCCESS
EndFunc


; Sequential 1-8 skill loop.
; Each recharged skill is fired via UseSkillEx() which blocks until the cast
; completes before returning - so we never advance to the next slot mid-cast.
; Cooldown slots are skipped immediately with no delay.
; Outer While repeats until no foes remain in earshot.
Func SV_CombatLoop()
    Local $lastTargetID = 0
    While True
        Local $me = GetMyAgent()
        ; Don't return $FAIL on death - break out so the main loop's
        ; SV_WaitUntilAlive handler runs (shrine respawn / rez logic)
        If IsPlayerDead() Then ExitLoop
        If IsPlayerAndPartyWiped() Then ExitLoop
        If CountFoesInRangeOfAgent($me, $SV_AGGRO_RANGE) = 0 Then ExitLoop

        Local $target = GetNearestEnemyToAgent($me)
        If $target = Null Or DllStructGetData($target, 'ID') = 0 Then ExitLoop
        If GetIsDead($target) Then
            $target = GetNearestEnemyToAgent($me)
            If $target = Null Or DllStructGetData($target, 'ID') = 0 Or GetIsDead($target) Then ExitLoop
        EndIf

        Local $targetID = DllStructGetData($target, 'ID')

        ; Walk into attack range if target is far
        If GetDistance($me, $target) > $RANGE_EARSHOT Then GetAlmostInRangeOfAgent($target)

        ; Only call target + Attack when target actually changes - prevents spamming
        ; the party call every loop iteration when skills are on cooldown
        If $targetID <> $lastTargetID Then
            $lastTargetID = $targetID
            ChangeTarget($target)
            Attack($target, True)   ; True = call target, signals heroes to focus this enemy
            Info('[SmartVanquisher] Targeting agent ID=' & $targetID)
        EndIf

        For $slot = 1 To 8
            If IsPlayerDead() Then ExitLoop
            $me     = GetMyAgent()
            $target = GetCurrentTarget()
            If $target = Null Or DllStructGetData($target, 'ID') = 0 Then ExitLoop
            If GetIsDead($target) Then ExitLoop
            If IsRecharged($slot) Then
                UseSkillEx($slot, $target)
                RandomSleep(100)
            EndIf
        Next
    WEnd

    Return $SUCCESS
EndFunc


; ===========================================================================
; PORTAL IDENTIFICATION
; ===========================================================================

; True if this static agent is a zone-exit portal (not a chest, not decorative)
Func SV_IsPortalAgent($agent)
    Local $gid = DllStructGetData($agent, 'GadgetID')
    If $gid = 0 Then Return False
    If $MAP_CHESTS_IDS[$gid] <> Null Then Return False   ; it's a chest
    Return True
EndFunc




; ===========================================================================
; DANGER ZONE LEARNING  (persistent portal avoidance)
;
; When the bot accidentally walks into a portal, it records the last known
; safe position in conf/portals/<mapID>.json.  On the next run in the same
; zone, those positions are loaded and treated as hard exclusion zones with
; radius $SV_DANGER_ZONE_RADIUS.  This builds up over time so each map only
; needs to be learned once.
; ===========================================================================

; Returns the path to the danger zone file for the current map
Func SV_DangerZoneFile()
    Return @ScriptDir & '\conf\portals\' & $sv_map_id & '.json'
EndFunc


; Load danger zones from file into $sv_danger_zones / $sv_danger_zone_count.
; File format is one "x,y" coordinate pair per line - simple, no JSON UDF needed.
; Called once per run, right after zone entry.
Func SV_LoadDangerZones()
    $sv_danger_zone_count = 0
    Local $file = SV_DangerZoneFile()
    If Not FileExists($file) Then Return

    Local $fh = FileOpen($file, 0)
    If $fh = -1 Then
        Warn('[SmartVanquisher] Could not open danger zone file: ' & $file)
        Return
    EndIf

    While Not @error
        Local $line = FileReadLine($fh)
        If @error Then ExitLoop
        $line = StringStripWS($line, 3)
        If $line = '' Then ContinueLoop
        Local $parts = StringSplit($line, ',')
        If $parts[0] <> 2 Then ContinueLoop   ; expect exactly x,y
        If $sv_danger_zone_count >= 64 Then ExitLoop
        $sv_danger_zones[$sv_danger_zone_count][0] = Number($parts[1])
        $sv_danger_zones[$sv_danger_zone_count][1] = Number($parts[2])
        $sv_danger_zone_count += 1
    WEnd
    FileClose($fh)

    If $sv_danger_zone_count > 0 Then
        Info('[SmartVanquisher] Loaded ' & $sv_danger_zone_count & ' danger zone(s) for map ' & $sv_map_id)
    EndIf
EndFunc


; Record a new danger zone at ($x, $y) and save to file.
; Skips if a zone already exists within $SV_DANGER_ZONE_MERGE_DIST.
; File format: one "x,y" pair per line.
Func SV_LearnDangerZone($x, $y)
    ; Check for duplicate
    For $i = 0 To $sv_danger_zone_count - 1
        If SV_Dist($x, $y, $sv_danger_zones[$i][0], $sv_danger_zones[$i][1]) < $SV_DANGER_ZONE_MERGE_DIST Then
            SV_DBG('[SmartVanquisher] Danger zone near (' & Round($x) & ',' & Round($y) & ') already known - skipping')
            Return
        EndIf
    Next

    ; Add to runtime array
    If $sv_danger_zone_count < 64 Then
        $sv_danger_zones[$sv_danger_zone_count][0] = $x
        $sv_danger_zones[$sv_danger_zone_count][1] = $y
        $sv_danger_zone_count += 1
    EndIf

    Warn('[SmartVanquisher] New danger zone learned at (' & Round($x) & ',' & Round($y) & ') - saving')

    ; Ensure conf/portals/ directory exists
    Local $dir = @ScriptDir & '\conf\portals'
    If Not FileExists($dir) Then DirCreate($dir)

    ; Write all zones to file (overwrite) - one x,y per line
    Local $fh = FileOpen(SV_DangerZoneFile(), 2)   ; 2 = overwrite
    If $fh = -1 Then
        Warn('[SmartVanquisher] Could not write danger zone file')
        Return
    EndIf
    For $i = 0 To $sv_danger_zone_count - 1
        FileWriteLine($fh, $sv_danger_zones[$i][0] & ',' & $sv_danger_zones[$i][1])
    Next
    FileClose($fh)
EndFunc


; Learn a danger zone based on proximity to a known portal agent.
; Prefers the portal's own coordinates over the bot's current position,
; since the portal is the actual hazard and its coords are more stable.
; Falls back to ($x, $y) (bot position) if no portal is within 2x safe dist.
Func SV_LearnDangerZoneNearPortal($x, $y, $portals)
    Local $bestDist = $SV_PORTAL_SAFE_DIST * 2
    Local $bestX    = $x
    Local $bestY    = $y
    For $a In $portals
        Local $ax = DllStructGetData($a, 'X')
        Local $ay = DllStructGetData($a, 'Y')
        Local $d  = SV_Dist($x, $y, $ax, $ay)
        If $d < $bestDist Then
            $bestDist = $d
            $bestX    = $ax
            $bestY    = $ay
        EndIf
    Next
    SV_LearnDangerZone($bestX, $bestY)
EndFunc

; Like MoveTo() but gives up after $maxBlocked *consecutive* not-moving ticks.
; Includes a startup grace period so false positives don't fire on the very
; first check before the player has started walking.
Func SV_MoveTo($x, $y, $maxBlocked = 4)
    Local $mapID   = GetMapID()
    Local $blocked = 0
    Move($x, $y, 0)
    Sleep(300 + GetPing() * 2)   ; wait for server to ack and player to start moving
    Local $me = GetMyAgent()
    While GetDistanceToPoint($me, $x, $y) > 25
        Sleep(100)
        $me = GetMyAgent()
        If GetMapID() <> $mapID Then Return False
        If DllStructGetData($me, 'HealthPercent') <= 0 Then Return False
        If IsPlayerMoving() Then
            $blocked = 0         ; moving fine - reset counter
        Else
            $blocked += 1
            If $blocked > $maxBlocked Then Return False
            Move($x, $y, 0)      ; nudge again before next check
        EndIf
    WEnd
    Return True
EndFunc

Func SV_Dist($x1, $y1, $x2, $y2)
    Return Sqrt(($x2 - $x1) ^ 2 + ($y2 - $y1) ^ 2)
EndFunc


Func SV_WrapAngle($a)
    Local Const $TWO_PI = 6.28318530717959
    Local Const $PI     = 3.14159265358979
    While $a >  $PI
        $a -= $TWO_PI
    WEnd
    While $a <= -$PI
        $a += $TWO_PI
    WEnd
    Return $a
EndFunc


Func SV_ATan2($y, $x)
    Local Const $PI = 3.14159265358979
    If $x > 0 Then Return ATan($y / $x)
    If $x < 0 And $y >= 0 Then Return ATan($y / $x) + $PI
    If $x < 0 And $y <  0 Then Return ATan($y / $x) - $PI
    If $x = 0 And $y >  0 Then Return  $PI / 2.0
    If $x = 0 And $y <  0 Then Return -$PI / 2.0
    Return 0.0
EndFunc