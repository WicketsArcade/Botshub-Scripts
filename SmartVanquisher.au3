#CS ===========================================================================
#################################
#                               #
#   Smart Vanquisher Bot        #
#                               #
#################################
; Version: 1.2.2
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
;   BOUNCE ROOMBA
;     Picks a heading (initially away from the entry portal) and walks straight
;     in 1000-unit steps.  On hitting a wall or obstacle, SV_MoveTo returns False
;     after just a few blocked ticks (~400ms) and the bot picks a new heading.
;     New headings are chosen by scoring 6 relative candidates (+-45/90/135 deg)
;     by counting unvisited cells ahead - so the bot naturally drifts toward
;     unexplored areas.  Blocked directions are "poisoned" (cells marked visited)
;     so the same wall is never re-attempted.
;
;   COMBAT
;     Foes within ~1500 units interrupt movement.  The bot stands still, fights,
;     loots, then resumes toward the saved waypoint.  Skills 1-8 fired in order.
;
;   PORTAL SAFETY
;     All non-entry portals are detected as static agents with GadgetID != 0.
;     SV_DirectionOpen checks 4 intermediate points along every proposed step -
;     if any point is within ~1000 units of a portal the heading is rejected.
;     The entry portal is excluded so the bot never deflects from its own spawn.
;
; STUCK DETECTION:
;   CheckStuck() - global 120-minute hard cap
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

; Cell size for visited-area tracking
Global Const $SV_BOUNCE_CELL_SIZE      = $RANGE_EARSHOT             ; ~1000

; Portal exclusion radius - don't step toward a portal within this range
Global Const $SV_PORTAL_SAFE_DIST      = $RANGE_EARSHOT * 1.5       ; ~1500

; Exclusion radius around a learned danger zone (portal entry point)
; Must be < distance from spawn to nearest portal to avoid blocking all directions at startup
Global Const $SV_DANGER_ZONE_RADIUS    = 650                         ; ~650 units

; Minimum distance between two danger zones - prevents duplicate entries
Global Const $SV_DANGER_ZONE_MERGE_DIST = 500

; Maximum total run time (ms)
Global Const $SV_FARM_DURATION         = 120 * 60 * 1000            ; 120 min

; Pause after each combat encounter (ms)
Global Const $SV_POST_COMBAT_WAIT      = 800

; Set to True to enable verbose navigation/combat logging, False for clean runs
Global Const $SV_DEBUG                 = False

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
    'Algorithm: Bounce Roomba - walks straight, bounces off obstacles,' & @CRLF & _
    'biasing toward unvisited areas until the zone is fully covered.' & @CRLF & _
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

    ; Always pause after a failed run - don't retry automatically.
    ; A vanquish run requires a clean start from the correct outpost and position.
    If $result <> $SUCCESS Then
        Warn('[SmartVanquisher] Run ended - pausing. Return to your starting outpost and press Start to try again.')
        SV_ClearState()
        Return $PAUSE
    EndIf

    Info('[SmartVanquisher] Zone vanquished - run complete!')
    SV_ClearState()
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

Func SV_Run()
    If GetMapID() <> $sv_map_id Then Return $FAIL
    If GetAreaVanquished() Then
        Warn('[SmartVanquisher] Zone is already vanquished - pausing.')
        Return $FAIL
    EndIf
    Info('[SmartVanquisher] Starting bounce roomba')
    Local $result = SV_BounceRoomba()
    If GetAreaVanquished() Then
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
; BOUNCE ROOMBA
;
; Inspired by a Roomba vacuum: pick a heading and walk straight.
; When we stop making progress (arrival far from target = obstacle/wall),
; pick a new deflected heading and keep going.
; A visited-cell grid tracks coverage and biases new headings toward
; unvisited areas so the whole zone gets covered over time.
; ===========================================================================

Func SV_BounceRoomba()
    Local Const $PI      = 3.14159265358979
    Local Const $CELL    = $SV_BOUNCE_CELL_SIZE
    Local Const $MAX_VISITED = 10000  ; cap on visited cell tracking

    ; Visited cell registry - parallel key/value arrays
    Local $visitedKeys[$MAX_VISITED]
    Local $visitedCount = 0

    ; Initial heading: away from the entry portal, into the zone
    Local $heading
    If $sv_entry_portal_found Then
        $heading = SV_ATan2($sv_entry_y - $sv_entry_portal_y, $sv_entry_x - $sv_entry_portal_x)
    Else
        $heading = $PI / 2.0
    EndIf
    SV_DBG('[SmartVanquisher] Initial heading=' & Round($heading * 180 / $PI) & 'deg')

    Local $stepsSinceNewCell = 0
    Local $lastCellCount     = 0
    Local $wallOnStep1Count  = 0   ; consecutive wall-on-sub-step-1 hits - detects physical corner

    ; Saved waypoint - resume here after combat interrupts a step
    Local $resumeX = 0
    Local $resumeY = 0
    Local $hasResume = False

    ; Recent heading history for ping-pong prevention.
    ; Circular buffer of the last $HEADING_HISTORY_SIZE headings used.
    Local Const $HEADING_HISTORY_SIZE = 6
    Local $headingHistory[$HEADING_HISTORY_SIZE]
    Local $headingHistoryIdx = 0
    Local $headingHistoryFull = False
    ; Initialise buffer to an impossible value so empty slots are ignored
    For $hhi = 0 To $HEADING_HISTORY_SIZE - 1
        $headingHistory[$hhi] = 9999.0
    Next

    While IsPlayerAlive() And Not GetAreaVanquished()

        If CheckStuck('Roomba', $SV_FARM_DURATION) == $FAIL Then Return $FAIL
        ; Death / wipe handling
        If IsPlayerDead() Or IsPlayerAndPartyWiped() Then
            ; Wait to be back on our feet - either in-place rez by a hero,
            ; or the automatic shrine respawn after a full party wipe.
            If Not SV_WaitUntilAlive() Then
                Return $FAIL   ; DP >= 60% - only option is return to town
            EndIf
            ; Back alive - clear resume waypoint so we pathfind fresh from shrine
            $hasResume = False
            ContinueLoop
        EndIf

        ; --- Combat check at wide range so we aggro before walking into a group ---
        If SV_CombatCheck() == $FAIL Then Return $FAIL

        Local $me  = GetMyAgent()
        Local $myX = DllStructGetData($me, 'X')
        Local $myY = DllStructGetData($me, 'Y')

        ; Mark current cell visited
        Local $cellKey = SV_CellKey($myX, $myY, $CELL)
        SV_MarkVisited($cellKey, $visitedKeys, $visitedCount, $MAX_VISITED)

        ; Progress check
        If $visitedCount > $lastCellCount Then
            $lastCellCount     = $visitedCount
            $stepsSinceNewCell = 0
        Else
            $stepsSinceNewCell += 1
            If $stepsSinceNewCell >= 15 Then
                SV_DBG('[SmartVanquisher] No new cells in 15 steps - bouncing')
                $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull)
                $stepsSinceNewCell = 0
                $hasResume = False
                ContinueLoop
            EndIf
        EndIf

        ; Determine next waypoint - resume interrupted step or pick new one
        Local $portals = SV_GetPortalAgents()   ; fetched here so sub-step loop can use it
        Local $targetX, $targetY
        If $hasResume Then
            $targetX   = $resumeX
            $targetY   = $resumeY
            $hasResume = False
            SV_DBG('[SmartVanquisher] Resuming to saved waypoint (' & Round($targetX) & ',' & Round($targetY) & ')')
        Else
            If Not SV_DirectionOpen($myX, $myY, $heading, $portals) Then
                SV_DBG('[SmartVanquisher] Portal ahead - bouncing')
                Local $newHeading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull)
                ; If we got a least-bad emergency heading, attempt to physically move in it
                ; so our position shifts and the direction opens up. Without moving, we just
                ; re-evaluate from the same spot forever.
                If $newHeading = $heading Then
                    ; Heading didn't change at all - force a small step to escape
                    Local $escX = $myX + 300 * Cos($newHeading)
                    Local $escY = $myY + 300 * Sin($newHeading)
                    SV_MoveTo($escX, $escY, 3)
                EndIf
                $heading = $newHeading
                ContinueLoop
            EndIf
            $targetX = $myX + $SV_BOUNCE_STEP * Cos($heading)
            $targetY = $myY + $SV_BOUNCE_STEP * Sin($heading)
        EndIf

        ; Record this heading into the circular history buffer
        $headingHistory[$headingHistoryIdx] = $heading
        $headingHistoryIdx = Mod($headingHistoryIdx + 1, $HEADING_HISTORY_SIZE)
        If $headingHistoryIdx = 0 Then $headingHistoryFull = True

        ; Walk toward waypoint in sub-steps using SV_MoveTo (fast wall detection).
        ; SV_MoveTo gives up after 2 blocked checks (~200ms) vs MoveTo's 14 (~45s).
        Local $combatInterrupted = False
        Local $wallHit           = False
        Local $subSteps          = 4
        Local $dirX  = ($targetX - $myX)
        Local $dirY  = ($targetY - $myY)

        ; Track position just before each move so if we zone we know where the
        ; portal boundary was (in our map's coordinate space, not the new zone's)
        Local $lastSafeX = $myX
        Local $lastSafeY = $myY

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

            Local $fracX = $myX + ($dirX * $s / $subSteps)
            Local $fracY = $myY + ($dirY * $s / $subSteps)

            If Not SV_MoveTo($fracX, $fracY) Then
                ; Check if SV_MoveTo bailed because we zoned (walked into a portal)
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

            ; Hard check: did we zone mid-step even though SV_MoveTo returned True?
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
            $lastSafeX = $myX   ; update safe position after confirmed arrival
            $lastSafeY = $myY

            ; Safety: if we somehow ended up near a portal, stop immediately
            If SV_NearAnyPortal($myX, $myY, $portals) Then
                Warn('[SmartVanquisher] Too close to portal after sub-step - bouncing away')
                $wallHit = True
                ExitLoop
            EndIf
        Next

        If $combatInterrupted Then
            If SV_CombatCheck() == $FAIL Then Return $FAIL
            $stepsSinceNewCell = 0   ; don't penalise standing still during combat
            $wallOnStep1Count  = 0   ; combat means we moved, not stuck
            ContinueLoop
        EndIf

        If $wallHit Then
            ; Cornered detection: if we hit a wall on sub-step 1 many times in a row
            ; we are physically wedged in a corner and scoring can't help us escape.
            If $wallOnStep1Count >= 6 Then
                Warn('[SmartVanquisher] Cornered (' & $wallOnStep1Count & ' consecutive step-1 walls) - calling TryToGetUnstuck')
                ; Pick a random escape target well away from current position
                Local $escAngle = (Random(0, 7, 1) * 3.14159265358979 / 4.0)   ; random 45deg increment
                Local $escX = $myX + $RANGE_EARSHOT * 3 * Cos($escAngle)
                Local $escY = $myY + $RANGE_EARSHOT * 3 * Sin($escAngle)
                TryToGetUnstuck($escX, $escY, 8000)
                ; Reset heading to the escape angle so we don't immediately re-corner
                $heading = $escAngle
                $wallOnStep1Count = 0
                $stepsSinceNewCell = 0
                $hasResume = False
                ContinueLoop
            EndIf
            ; Poison the blocked direction's cells so it never scores well again
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull)
            $stepsSinceNewCell = 0
            $hasResume = False
            ContinueLoop
        EndIf

        ; Check overall arrival - if still far from target after all sub-steps, bounce
        If SV_Dist($myX, $myY, $targetX, $targetY) > $SV_BOUNCE_STEP * 1.5 Then
            SV_DBG('[SmartVanquisher] Did not reach waypoint - bouncing')
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL, $headingHistory, $headingHistoryFull)
            $stepsSinceNewCell = 0
            $hasResume = False
        EndIf

        $wallOnStep1Count = 0   ; clean step - definitely not cornered
        RandomSleep(80)
    WEnd

    Return $SUCCESS
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
Func SV_PickBounceHeading($myX, $myY, $blockedHeading, ByRef $visitedKeys, $visitedCount, $cellSize, ByRef $headingHistory, $headingHistoryFull)
    Local Const $PI         = 3.14159265358979
    Local Const $DEG30      = $PI / 6.0       ; 30deg in radians - history penalty threshold
    Local Const $HISTORY_PENALTY = 3.0        ; score penalty for recently used headings
    Local Const $PINGPONG_PENALTY = 4.0       ; extra penalty for near-exact reversal of recent heading
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
            If Not SV_IsVisited(SV_CellKey($lx, $ly, $cellSize), $visitedKeys, $visitedCount) Then $cellScore += 1
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

        Local $totalScore = $cellScore + $bonus - $histPenalty

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
Func SV_PoisonDirection($myX, $myY, $heading, ByRef $visitedKeys, ByRef $visitedCount, $maxCount, $cellSize)
    For $step = 1 To 5
        Local $lx  = $myX + ($step * $cellSize) * Cos($heading)
        Local $ly  = $myY + ($step * $cellSize) * Sin($heading)
        Local $key = SV_CellKey($lx, $ly, $cellSize)
        SV_MarkVisited($key, $visitedKeys, $visitedCount, $maxCount)
    Next
EndFunc


; ===========================================================================
; VISITED CELL TRACKING
; ===========================================================================

Func SV_CellKey($x, $y, $cellSize)
    ; Encode grid cell as a string key
    Return Int($x / $cellSize) & ',' & Int($y / $cellSize)
EndFunc


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


; ===========================================================================
; MOVEMENT / MATH HELPERS
; ===========================================================================

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