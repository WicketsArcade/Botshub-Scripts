#CS ===========================================================================
#################################
#                               #
#   Smart Vanquisher Bot        #
#                               #
#################################
; Version: 1.0.2
; Author: (your name here)
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

Opt('MustDeclareVars', True)

; ===========================================================================
; TUNING CONSTANTS
; ===========================================================================

; How far each bounce step travels (GW units)
Global Const $SV_BOUNCE_STEP           = $RANGE_EARSHOT             ; ~1000

; Aggro scan range - stop moving and fight if foes within this distance
Global Const $SV_AGGRO_RANGE           = $RANGE_EARSHOT * 1.5       ; ~1500

; Cell size for visited-area tracking
Global Const $SV_BOUNCE_CELL_SIZE      = $RANGE_EARSHOT             ; ~1000

; Portal exclusion radius - don't step toward a portal within this range
Global Const $SV_PORTAL_SAFE_DIST      = $RANGE_EARSHOT             ; ~1000

; Maximum total run time (ms)
Global Const $SV_FARM_DURATION         = 120 * 60 * 1000            ; 120 min

; Pause after each combat encounter (ms)
Global Const $SV_POST_COMBAT_WAIT      = 800

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

; (visited cell tracking is managed locally inside SV_BounceRoomba)

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
        If SV_EnterZoneFromOutpost() == $FAIL Then Return $FAIL
    EndIf

    ; ---- Guard: must now be in an explorable ---------------------------
    If GetMapType() <> $ID_EXPLORABLE Then
        Error('[SmartVanquisher] Not in an explorable zone after entry attempt.')
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

    ; ---- Reset per-run mutable state ------------------------------------
    SV_ResetState()

    ; ---- Run -----------------------------------------------------------
    AdlibRegister('TrackPartyStatus', 10000)
    Local $result = SV_Run()
    AdlibUnRegister('TrackPartyStatus')

    ; ---- Return to outpost ---------------------------------------------
    If $sv_outpost_id > 0 Then
        ResignAndReturnToOutpost($sv_outpost_id)
    Else
        ; Fallback: resign and wait for the game to drop us to any outpost
        Resign()
        Sleep(3500)
        ReturnToOutpost()
        WaitMapLoading(-1, 10000, 1000)
    EndIf

    Return $result
EndFunc


; Reset all per-run state variables
Func SV_ResetState()
    IsPlayerStuck(Default, Default, True)
    ResetFailuresCounter()
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
        ; Wrong zone - we may have zoned somewhere else, travel back to try next portal
        If GetMapType() = $ID_EXPLORABLE Then
            Warn('[SmartVanquisher] Wrong zone (mapID=' & GetMapID() & ') - returning to outpost')
            Resign()
            Sleep(3000)
            ReturnToOutpost()
            WaitMapLoading(-1, 10000, 1000)
        EndIf
    Next

    ; Last resort: use TravelToOutpost if we have a valid outpost ID
    If $sv_outpost_id > 0 Then
        Warn('[SmartVanquisher] All portals failed - trying TravelToOutpost(' & $sv_outpost_id & ')')
        TravelToOutpost($sv_outpost_id)
        WaitMapLoading($sv_outpost_id, 15000, 1000)
        Return $FAIL   ; Return FAIL so BotsHub retries the run fresh next loop
    EndIf

    Warn('[SmartVanquisher] Could not enter zone ' & $sv_map_id)
    Return $FAIL
EndFunc


; ===========================================================================
; TOP-LEVEL RUN LOGIC
; ===========================================================================

Func SV_Run()
    If GetMapID() <> $sv_map_id Then Return $FAIL
    Info('[SmartVanquisher] Starting bounce roomba')
    Local $result = SV_BounceRoomba()
    If GetAreaVanquished() Then
        Info('[SmartVanquisher] Zone vanquished!')
        Return $SUCCESS
    EndIf
    Return $result
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
    Info('[SmartVanquisher] Initial heading=' & Round($heading * 180 / $PI) & 'deg')

    Local $stepsSinceNewCell = 0
    Local $lastCellCount     = 0

    ; Saved waypoint - resume here after combat interrupts a step
    Local $resumeX = 0
    Local $resumeY = 0
    Local $hasResume = False

    While IsPlayerAlive() And Not GetAreaVanquished()

        If CheckStuck('Roomba', $SV_FARM_DURATION) == $FAIL Then Return $FAIL
        If IsPlayerAndPartyWiped() Then Return $FAIL

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
                Info('[SmartVanquisher] No new cells in 15 steps - bouncing')
                $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL)
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
            Info('[SmartVanquisher] Resuming to saved waypoint (' & Round($targetX) & ',' & Round($targetY) & ')')
        Else
            If Not SV_DirectionOpen($myX, $myY, $heading, $portals) Then
                Info('[SmartVanquisher] Portal ahead - bouncing')
                $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL)
                ContinueLoop
            EndIf
            $targetX = $myX + $SV_BOUNCE_STEP * Cos($heading)
            $targetY = $myY + $SV_BOUNCE_STEP * Sin($heading)
        EndIf

        ; Walk toward waypoint in sub-steps using SV_MoveTo (fast wall detection).
        ; SV_MoveTo gives up after 2 blocked checks (~200ms) vs MoveTo's 14 (~45s).
        Local $combatInterrupted = False
        Local $wallHit           = False
        Local $subSteps          = 4
        Local $dirX  = ($targetX - $myX)
        Local $dirY  = ($targetY - $myY)

        For $s = 1 To $subSteps
            If Not IsPlayerAlive() Then ExitLoop
            If IsPlayerAndPartyWiped() Then ExitLoop

            If CountFoesInRangeOfAgent(GetMyAgent(), $SV_AGGRO_RANGE) > 0 Then
                $resumeX   = $targetX
                $resumeY   = $targetY
                $hasResume = True
                $combatInterrupted = True
                Info('[SmartVanquisher] Foes detected mid-step - stopping to fight')
                ExitLoop
            EndIf

            Local $fracX = $myX + ($dirX * $s / $subSteps)
            Local $fracY = $myY + ($dirY * $s / $subSteps)

            If Not SV_MoveTo($fracX, $fracY) Then
                Info('[SmartVanquisher] Wall hit at sub-step ' & $s & ' - bouncing')
                $wallHit = True
                ExitLoop
            EndIf

            $me  = GetMyAgent()
            $myX = DllStructGetData($me, 'X')
            $myY = DllStructGetData($me, 'Y')

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
            ContinueLoop
        EndIf

        If $wallHit Then
            ; Poison the blocked direction's cells so it never scores well again
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL)
            $stepsSinceNewCell = 0
            $hasResume = False
            ContinueLoop
        EndIf

        ; Check overall arrival - if still far from target after all sub-steps, bounce
        If SV_Dist($myX, $myY, $targetX, $targetY) > $SV_BOUNCE_STEP * 1.5 Then
            Info('[SmartVanquisher] Did not reach waypoint - bouncing')
            SV_PoisonDirection($myX, $myY, $heading, $visitedKeys, $visitedCount, $MAX_VISITED, $CELL)
            $heading = SV_PickBounceHeading($myX, $myY, $heading, $visitedKeys, $visitedCount, $CELL)
            $stepsSinceNewCell = 0
            $hasResume = False
        EndIf

        RandomSleep(80)
    WEnd

    Return $SUCCESS
EndFunc


; Pick a new heading after a bounce.
; Sweeps 6 candidates relative to the blocked heading (every 45deg, skipping
; forward and back), scores each by unvisited cell lookahead, picks best.
Func SV_PickBounceHeading($myX, $myY, $blockedHeading, ByRef $visitedKeys, $visitedCount, $cellSize)
    Local Const $PI = 3.14159265358979
    Local $portals  = SV_GetPortalAgents()

    ; Candidates: every 45deg relative to blocked heading, skipping 0 (blocked) and 180 (back)
    Local $offsets[6]
    $offsets[0] =  $PI / 2.0        ;  90 left
    $offsets[1] = -$PI / 2.0        ;  90 right
    $offsets[2] =  $PI / 4.0 * 3.0  ; 135 left
    $offsets[3] = -$PI / 4.0 * 3.0  ; 135 right
    $offsets[4] =  $PI / 4.0        ;  45 left
    $offsets[5] = -$PI / 4.0        ;  45 right

    Local $bestHeading = SV_WrapAngle($blockedHeading + $PI)  ; fallback: reverse
    Local $bestScore   = -1

    For $i = 0 To 5
        Local $candidate = SV_WrapAngle($blockedHeading + $offsets[$i])

        If Not SV_DirectionOpen($myX, $myY, $candidate, $portals) Then ContinueLoop

        Local $score = 0
        For $step = 1 To 5
            Local $lx  = $myX + ($step * $cellSize) * Cos($candidate)
            Local $ly  = $myY + ($step * $cellSize) * Sin($candidate)
            If Not SV_IsVisited(SV_CellKey($lx, $ly, $cellSize), $visitedKeys, $visitedCount) Then $score += 1
        Next

        If $score > $bestScore Then
            $bestScore   = $score
            $bestHeading = $candidate
        EndIf
    Next

    Info('[SmartVanquisher] Bounce: ' & Round($blockedHeading*180/$PI) & 'deg blocked -> new=' & Round($bestHeading*180/$PI) & 'deg (score=' & $bestScore & ')')
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
    Next
    Return True
EndFunc


; True if the player's current position is within portal safe distance of any portal.
; Used as a real-time tripwire during movement to catch cases where the pathfinder
; routes us closer to a portal than the planned waypoint check anticipated.
Func SV_NearAnyPortal($myX, $myY, $portals)
    For $a In $portals
        If SV_Dist($myX, $myY, DllStructGetData($a,'X'), DllStructGetData($a,'Y')) < $SV_PORTAL_SAFE_DIST Then
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
    While True
        Local $me = GetMyAgent()
        If IsPlayerDead() Then Return $FAIL
        If IsPlayerAndPartyWiped() Then Return $FAIL
        If CountFoesInRangeOfAgent($me, $SV_AGGRO_RANGE) = 0 Then ExitLoop

        Local $target = GetNearestEnemyToAgent($me)
        If $target = Null Or DllStructGetData($target, 'ID') = 0 Then ExitLoop
        If GetIsDead($target) Then
            $target = GetNearestEnemyToAgent($me)
            If $target = Null Or DllStructGetData($target, 'ID') = 0 Or GetIsDead($target) Then ExitLoop
        EndIf

        ; Walk into attack range if target is far
        If GetDistance($me, $target) > $RANGE_EARSHOT Then GetAlmostInRangeOfAgent($target)
        ChangeTarget($target)
        Attack($target, True)   ; True = call target, signals heroes to focus this enemy

        For $slot = 1 To 8
            If IsPlayerDead() Then Return $FAIL
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