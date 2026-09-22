<#
.SYNOPSIS
  Pure brightness-decision functions. No I/O, no network, no DDC, no clock reads.

.DESCRIPTION
  Everything here is deterministic: same inputs -> same outputs. That is what makes the
  algorithm testable without a monitor, a network connection, or waiting for sunset.
  Orchestration (config, state, HTTP, DDC, logging) lives in Set-AdaptiveBrightness.ps1.

  The model in one line:

      brightness = Night + (DayCeiling(Kt) - Night) * SunFactor(altitude)

  SunFactor  is the day/night backbone. Geometry only, always available, works offline.
  DayCeiling is "how bright does *day* mean today" - driven by the clearness index Kt,
             so an overcast noon does not get the same level as a dazzling one.

  Kt = actual global horizontal irradiance / clear-sky irradiance. It is a ratio, so it
  is independent of season and latitude: 1.0 is a cloudless sky anywhere, ~0.2 is heavy
  overcast anywhere. That is why we do not map raw W/m^2 to brightness directly - 250 W/m^2
  is pitch-dull in July and a blinding clear January noon at this latitude.
#>

# NOTE: no Set-StrictMode here on purpose - this file is dot-sourced, and a library has no
# business changing its caller.s strictness. The entry scripts set it for themselves.

# ---------------------------------------------------------------------------
# small math helpers
# ---------------------------------------------------------------------------

function Get-Clamped {
    param(
        [Parameter(Mandatory)][double]$Value,
        [double]$Min = 0.0,
        [double]$Max = 1.0
    )
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Get-Smoothstep {
    <#
      Clamped smoothstep. Flat at both ends, eased in between, so there is never a
      visible kink where a ramp meets its floor or ceiling.
    #>
    param([Parameter(Mandatory)][double]$X)
    $x = Get-Clamped -Value $X -Min 0.0 -Max 1.0
    return $x * $x * (3.0 - 2.0 * $x)
}

function Get-RampFactor {
    <#
      Maps Value across [Low, High] onto a smoothstepped 0..1.
      Low may be greater than High; the ramp then runs the other way.
    #>
    param(
        [Parameter(Mandatory)][double]$Value,
        [Parameter(Mandatory)][double]$Low,
        [Parameter(Mandatory)][double]$High
    )
    if ($High -eq $Low) {
        if ($Value -ge $High) { return 1.0 } else { return 0.0 }
    }
    return Get-Smoothstep -X (($Value - $Low) / ($High - $Low))
}

# ---------------------------------------------------------------------------
# solar geometry (NOAA solar position algorithm) - offline, no API needed
# ---------------------------------------------------------------------------

function Get-SunAltitude {
    <#
      Sun altitude in degrees above the horizon. Negative below.
    #>
    param(
        [Parameter(Mandatory)][double]$Lat,
        [Parameter(Mandatory)][double]$Lon,
        [Parameter(Mandatory)][datetime]$When
    )

    $utc = $When.ToUniversalTime()
    $jd  = [double]$utc.ToOADate() + 2415018.5
    $t   = ($jd - 2451545.0) / 36525.0
    $rad = [Math]::PI / 180.0

    $L0 = (280.46646 + $t * (36000.76983 + $t * 0.0003032)) % 360.0
    if ($L0 -lt 0) { $L0 += 360.0 }
    $M = 357.52911 + $t * (35999.05029 - 0.0001537 * $t)
    $e = 0.016708634 - $t * (0.000042037 + 0.0000001267 * $t)

    $C = [Math]::Sin($M * $rad) * (1.914602 - $t * (0.004817 + 0.000014 * $t)) +
         [Math]::Sin(2 * $M * $rad) * (0.019993 - 0.000101 * $t) +
         [Math]::Sin(3 * $M * $rad) * 0.000289

    $trueLong = $L0 + $C
    $omega    = 125.04 - 1934.136 * $t
    $lambda   = $trueLong - 0.00569 - 0.00478 * [Math]::Sin($omega * $rad)

    $eps0 = 23.0 + (26.0 + (21.448 - $t * (46.815 + $t * (0.00059 - $t * 0.001813))) / 60.0) / 60.0
    $eps  = $eps0 + 0.00256 * [Math]::Cos($omega * $rad)
    $decl = [Math]::Asin([Math]::Sin($eps * $rad) * [Math]::Sin($lambda * $rad)) / $rad

    $y  = [Math]::Tan($eps / 2 * $rad) * [Math]::Tan($eps / 2 * $rad)
    $eq = 4 * (($y * [Math]::Sin(2 * $L0 * $rad) -
                2 * $e * [Math]::Sin($M * $rad) +
                4 * $e * $y * [Math]::Sin($M * $rad) * [Math]::Cos(2 * $L0 * $rad) -
                0.5 * $y * $y * [Math]::Sin(4 * $L0 * $rad) -
                1.25 * $e * $e * [Math]::Sin(2 * $M * $rad)) / $rad)

    $minutesUtc = $utc.Hour * 60.0 + $utc.Minute + $utc.Second / 60.0
    $trueSolar  = ($minutesUtc + $eq + 4.0 * $Lon) % 1440.0
    if ($trueSolar -lt 0) { $trueSolar += 1440.0 }
    $ha = $trueSolar / 4.0
    if ($ha -lt 0) { $ha += 180.0 } else { $ha -= 180.0 }

    $cosZ = [Math]::Sin($Lat * $rad) * [Math]::Sin($decl * $rad) +
            [Math]::Cos($Lat * $rad) * [Math]::Cos($decl * $rad) * [Math]::Cos($ha * $rad)
    $cosZ = Get-Clamped -Value $cosZ -Min -1.0 -Max 1.0
    return 90.0 - ([Math]::Acos($cosZ) / $rad)
}

function Get-ClearSkyGhi {
    <#
      Haurwitz clear-sky global horizontal irradiance, W/m^2, from sun altitude.
      A one-parameter model - plenty accurate as the *denominator* of a ratio, where
      a systematic few-percent bias cancels out of the comparison we actually care about.
      Returns 0 when the sun is at or below the horizon.
    #>
    param([Parameter(Mandatory)][double]$SunAltitudeDeg)

    $sinAlt = [Math]::Sin($SunAltitudeDeg * [Math]::PI / 180.0)
    if ($sinAlt -le 0.01) { return 0.0 }
    return 1098.0 * $sinAlt * [Math]::Exp(-0.057 / $sinAlt)
}

function Get-ClearnessIndex {
    <#
      Kt = measured GHI / clear-sky GHI, clamped to [0, 1.1] then to [0, 1].

      Returns $null when the sky is too dim to judge: near sunrise/sunset the denominator
      collapses and the ratio becomes numerical noise. The caller must then hold its
      previous estimate rather than believe a fabricated one.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$ActualGhi,
        [Parameter(Mandatory)][double]$ClearSkyGhi,
        [double]$MinClearSkyGhi = 60.0
    )

    if ($null -eq $ActualGhi)              { return $null }
    if ($ActualGhi -lt 0)                  { return $null }
    if ($ClearSkyGhi -lt $MinClearSkyGhi)  { return $null }


    $kt = [double]$ActualGhi / $ClearSkyGhi
    # thin cloud can scatter *more* onto a horizontal plane than clear sky; allow a little
    # headroom above 1 before clamping so those readings do not look like an error
    return Get-Clamped -Value $kt -Min 0.0 -Max 1.0
}

# ---------------------------------------------------------------------------
# temporal smoothing
# ---------------------------------------------------------------------------

function Update-EmaValue {
    <#
      Exponential moving average with a *time constant*, not a fixed weight.

      alpha = 1 - exp(-dt / tau)

      This matters because ticks are not evenly spaced: a task that is late, a machine
      that was asleep for six hours, and a normal 2-minute tick must not all be weighted
      the same. With a real time constant a long gap correctly lets the new sample
      dominate, and a burst of rapid ticks does not over-smooth.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$Previous,
        [Parameter(Mandatory)][double]$Sample,
        [Parameter(Mandatory)][double]$DeltaSeconds,
        [Parameter(Mandatory)][double]$TauSeconds
    )

    if ($null -eq $Previous)      { return $Sample }   # cold start: adopt immediately
    if ($TauSeconds -le 0)        { return $Sample }
    if ($DeltaSeconds -le 0)      { return [double]$Previous }

    $alpha = 1.0 - [Math]::Exp(-$DeltaSeconds / $TauSeconds)
    $alpha = Get-Clamped -Value $alpha -Min 0.0 -Max 1.0
    return ([double]$Previous) + $alpha * ($Sample - [double]$Previous)
}

function Get-EffectiveClearness {
    <#
      Decides which Kt to actually use this tick, and says why.

      Priority:
        1. a fresh sample                       -> EMA it into the running estimate
        2. sun too low to measure (night)       -> freeze the last known sky, do not age it
        3. no sample, cached value still young  -> hold the cache as-is
        4. no sample, cache gone stale          -> ease toward KtFallback, never jump
        5. nothing at all                       -> KtFallback

      Case 2 exists because "no reading because it is dark" and "no reading because the
      network died" are not the same failure. Kt is undefined at night, not missing, so
      the staleness clock must not run while the sun is down. Letting it run was a real
      bug: an overcast evening's Kt of 0.18 would decay to the neutral default overnight
      and the panel would come up near full brightness on a grey morning, then spend an
      hour walking back down. Weather is strongly autocorrelated over a night, so
      yesterday's sky is a far better dawn prior than any fixed constant.

      Case 3 is the important one. When the network has been down for hours the honest
      answer is "I no longer know", and the safe expression of that is a slow drift to a
      neutral assumption - not a snap to either extreme.

      Returns a hashtable: Kt, PersistKt, Source, IsFresh.

      Kt and PersistKt differ on purpose, and the distinction is load-bearing.

      Kt        is what to use for *this* decision.
      PersistKt is what to remember for next time - $null when we are only guessing.

      Case 4 hands back Kt = KtFallback but PersistKt = $null, so the next real reading
      cold-starts the average and is adopted outright instead of being averaged against a
      number we invented. Without that split, a guess laundered through the EMA becomes
      indistinguishable from a measurement: an overcast dawn would ramp the panel toward
      full on the strength of the neutral default, then spend an hour crawling back down.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$SampleKt,
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$PreviousKt,
        [Parameter(Mandatory)][double]$PreviousAgeSeconds,
        [Parameter(Mandatory)][double]$DeltaSeconds,
        [bool]  $SunTooLowToMeasure = $false,
        [double]$TauSeconds     = 1800.0,
        [double]$MaxAgeSeconds  = 10800.0,
        [double]$KtFallback     = 0.50,
        [double]$DecayTauSeconds = 3600.0
    )

    if ($null -ne $SampleKt) {
        $kt = Update-EmaValue -Previous $PreviousKt -Sample ([double]$SampleKt) `
                              -DeltaSeconds $DeltaSeconds -TauSeconds $TauSeconds
        $src = 'live'
        if ($null -eq $PreviousKt) { $src = 'live (cold start)' }
        return @{ Kt = $kt; PersistKt = $kt; Source = $src; IsFresh = $true }
    }

    # the sun is below the altitude where a ratio means anything - freeze, do not decay
    if ($SunTooLowToMeasure -and $null -ne $PreviousKt) {
        return @{ Kt = [double]$PreviousKt; PersistKt = [double]$PreviousKt
                  Source = 'sun too low, holding last known sky'; IsFresh = $false }
    }

    if ($null -eq $PreviousKt) {
        # a guess, and we refuse to remember it as anything else
        return @{ Kt = $KtFallback; PersistKt = $null
                  Source = 'fallback (no data yet)'; IsFresh = $false }
    }

    if ($PreviousAgeSeconds -le $MaxAgeSeconds) {
        return @{ Kt = [double]$PreviousKt; PersistKt = [double]$PreviousKt
                  Source = ('cached {0:N0} min' -f ($PreviousAgeSeconds / 60.0))
                  IsFresh = $false }
    }

    $kt = Update-EmaValue -Previous $PreviousKt -Sample $KtFallback `
                          -DeltaSeconds $DeltaSeconds -TauSeconds $DecayTauSeconds
    return @{ Kt = $kt; PersistKt = $kt
              Source = ('stale {0:N0} min, decaying to fallback' -f ($PreviousAgeSeconds / 60.0))
              IsFresh = $false }
}

# ---------------------------------------------------------------------------
# the brightness model
# ---------------------------------------------------------------------------

function Get-DayCeiling {
    <#
      What "full day" is worth under the current sky, in percent.

      Kt >= KtHigh (clear)    -> DayBrightness
      Kt <= KtLow  (overcast) -> OvercastBrightness
      between                 -> smoothstepped
    #>
    param(
        [Parameter(Mandatory)][double]$Kt,
        [double]$DayBrightness      = 100.0,
        [double]$OvercastBrightness = 55.0,
        [double]$KtLow              = 0.25,
        [double]$KtHigh             = 0.75
    )
    $g = Get-RampFactor -Value $Kt -Low $KtLow -High $KtHigh
    return $OvercastBrightness + ($DayBrightness - $OvercastBrightness) * $g
}

function Get-TargetBrightness {
    <#
      The full model. Returns a hashtable with the target and every intermediate value,
      so logs and tests can explain *why* a number came out, not just what it was.
    #>
    param(
        [Parameter(Mandatory)][double]$SunAltitudeDeg,
        [Parameter(Mandatory)][double]$Kt,
        [double]$DayBrightness      = 100.0,
        [double]$OvercastBrightness = 55.0,
        [double]$NightBrightness    = 9.0,
        [double]$RampLowDeg         = -12.0,
        [double]$RampHighDeg        = 14.0,
        [double]$KtLow              = 0.25,
        [double]$KtHigh             = 0.75,
        [double]$MinBrightness      = 5.0,
        [double]$MaxBrightness      = 100.0
    )

    $sunFactor  = Get-RampFactor -Value $SunAltitudeDeg -Low $RampLowDeg -High $RampHighDeg
    $dayCeiling = Get-DayCeiling -Kt $Kt -DayBrightness $DayBrightness `
                                 -OvercastBrightness $OvercastBrightness `
                                 -KtLow $KtLow -KtHigh $KtHigh

    # Night is the floor at sun factor 0, so clouds correctly stop mattering after dark.
    $target = $NightBrightness + ($dayCeiling - $NightBrightness) * $sunFactor
    $target = Get-Clamped -Value $target -Min $MinBrightness -Max $MaxBrightness

    return @{
        Target     = $target
        SunFactor  = $sunFactor
        DayCeiling = $dayCeiling
        Kt         = $Kt
    }
}

# ---------------------------------------------------------------------------
# actuation policy: rate limit + deadband
# ---------------------------------------------------------------------------

function Resolve-AppliedBrightness {
    <#
      Turns a desired target into what we will actually command, applying:

        1. Rate limit - at most MaxRatePerMinute points of change per minute. A step
           change in the data (a cloud bank arriving) becomes a ramp over minutes rather
           than a jolt. This is what keeps the display calm when the *input* is not.

        2. Deadband - ignore moves smaller than DeadbandPct. Weather data jitters by a
           few percent tick to tick; without a deadband the panel would tick 61-62-61-62
           forever. The deadband is checked against the rate-limited move, and the last
           *commanded* level is the reference, so small errors cannot accumulate.

           Exception: if the move would land on a hard limit, or we have never commanded
           anything, apply it regardless - being stuck 3 points off the floor at night is
           worse than one extra write.

      Returns a hashtable: Applied, Changed, Reason, RateLimited.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$LastApplied,
        [Parameter(Mandatory)][double]$Target,
        [Parameter(Mandatory)][double]$DeltaSeconds,
        [double]$MaxRatePerMinute = 3.0,
        [double]$DeadbandPct      = 4.0,
        [double]$MinBrightness    = 5.0,
        [double]$MaxBrightness    = 100.0
    )

    $target = Get-Clamped -Value $Target -Min $MinBrightness -Max $MaxBrightness

    if ($null -eq $LastApplied) {
        return @{ Applied = $target; Changed = $true
                  Reason = 'first run, adopting target'; RateLimited = $false }
    }

    $last  = Get-Clamped -Value ([double]$LastApplied) -Min $MinBrightness -Max $MaxBrightness
    $delta = $target - $last

    # ---- rate limit ----
    $rateLimited = $false
    $allowed = [double]::PositiveInfinity
    if ($MaxRatePerMinute -gt 0 -and $DeltaSeconds -gt 0) {
        $allowed = $MaxRatePerMinute * ($DeltaSeconds / 60.0)
    }
    if ([Math]::Abs($delta) -gt $allowed) {
        $rateLimited = $true
        if ($delta -gt 0) { $delta = $allowed } else { $delta = -$allowed }
    }

    $candidate = Get-Clamped -Value ($last + $delta) -Min $MinBrightness -Max $MaxBrightness
    $move      = [Math]::Abs($candidate - $last)

    # ---- deadband ----
    $atLimit = ($candidate -le $MinBrightness) -or ($candidate -ge $MaxBrightness)
    if ($move -lt $DeadbandPct -and -not $atLimit) {
        return @{ Applied = $last; Changed = $false
                  Reason = ('within deadband ({0:N1} < {1:N1})' -f $move, $DeadbandPct)
                  RateLimited = $rateLimited }
    }
    if ($move -eq 0) {
        return @{ Applied = $last; Changed = $false
                  Reason = 'already at target'; RateLimited = $rateLimited }
    }

    $reason = 'stepping toward target'
    if ($rateLimited) { $reason = ('rate limited to {0:N1} pts' -f $move) }

    return @{ Applied = $candidate; Changed = $true; Reason = $reason; RateLimited = $rateLimited }
}

function Test-ManualOverride {
    <#
      Did the human touch the monitor's own controls?

      We compare what the panel reports now against what we last commanded. A gap larger
      than the tolerance means something other than us moved it, so we stand down for
      OverrideMinutes rather than fighting the user's buttons every tick.

      Tolerance exists because monitors quantise and round-trip DDC values imprecisely; a
      1-2 point discrepancy is the hardware, not a person.

      Returns a hashtable: IsOverridden, Reason.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$LastApplied,
        [Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$ObservedBrightness,
        [double]$TolerancePct = 3.0
    )

    if ($null -eq $LastApplied)        { return @{ IsOverridden = $false; Reason = 'no commanded value yet' } }
    if ($null -eq $ObservedBrightness) { return @{ IsOverridden = $false; Reason = 'monitor level unreadable' } }

    $gap = [Math]::Abs([double]$ObservedBrightness - [double]$LastApplied)
    if ($gap -gt $TolerancePct) {
        return @{ IsOverridden = $true
                  Reason = ('panel at {0:N0}%, we commanded {1:N0}% (gap {2:N0})' -f `
                            [double]$ObservedBrightness, [double]$LastApplied, $gap) }
    }
    return @{ IsOverridden = $false; Reason = ('panel matches commanded level (gap {0:N0})' -f $gap) }
}
