<#
.SYNOPSIS
  Test suite for BrightnessCore.ps1. No Pester, no monitor, no network required.

.DESCRIPTION
  Everything the algorithm decides is a pure function, so a whole simulated day - or a
  three-hour network outage, or a cloud bank arriving at noon - runs in milliseconds.

.EXAMPLE
  pwsh -File .\Tests\Run-Tests.ps1
#>
[CmdletBinding()]
param([switch]$Verbose_)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'BrightnessCore.ps1')

# ---------------------------------------------------------------------------
# tiny assertion harness
# ---------------------------------------------------------------------------
$script:Passed = 0
$script:Failed = 0
$script:Section = ''

function Section { param([string]$Name); $script:Section = $Name; Write-Host "`n$Name" -ForegroundColor Cyan }

function Ok { param([string]$Name)
    $script:Passed++; Write-Host "  [pass] $Name" -ForegroundColor DarkGreen }

function Fail { param([string]$Name, [string]$Detail)
    $script:Failed++; Write-Host "  [FAIL] $Name" -ForegroundColor Red
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkYellow } }

function Assert-True { param([bool]$Condition, [string]$Name, [string]$Detail)
    if ($Condition) { Ok $Name } else { Fail $Name $Detail } }

function Assert-Near { param([double]$Actual, [double]$Expected, [double]$Tolerance, [string]$Name)
    $d = [Math]::Abs($Actual - $Expected)
    Assert-True ($d -le $Tolerance) $Name ("expected {0} +/- {1}, got {2}" -f $Expected, $Tolerance, $Actual) }

function Assert-Null { param($Value, [string]$Name)
    Assert-True ($null -eq $Value) $Name ("expected `$null, got '{0}'" -f $Value) }

function Assert-InRange { param([double]$Value, [double]$Min, [double]$Max, [string]$Name)
    Assert-True (($Value -ge $Min) -and ($Value -le $Max)) $Name `
        ("expected {0}..{1}, got {2}" -f $Min, $Max, $Value) }

# location used throughout (Prague, matches the shipped config)
$LAT = 50.0471
$LON = 14.4523

# ===========================================================================
Section 'math helpers'
# ===========================================================================

Assert-Near (Get-Smoothstep -X 0.0)  0.0  1e-9 'smoothstep(0) = 0'
Assert-Near (Get-Smoothstep -X 1.0)  1.0  1e-9 'smoothstep(1) = 1'
Assert-Near (Get-Smoothstep -X 0.5)  0.5  1e-9 'smoothstep(0.5) = 0.5'
Assert-Near (Get-Smoothstep -X -5.0) 0.0  1e-9 'smoothstep clamps below 0'
Assert-Near (Get-Smoothstep -X 9.0)  1.0  1e-9 'smoothstep clamps above 1'

# derivative is zero at both ends - this is what removes the kink
$dLow  = (Get-Smoothstep -X 0.02) - (Get-Smoothstep -X 0.00)
$dMid  = (Get-Smoothstep -X 0.51) - (Get-Smoothstep -X 0.49)
Assert-True ($dLow -lt $dMid) 'smoothstep is flatter at the ends than the middle' `
    ("end slope $dLow vs mid slope $dMid")

Assert-Near (Get-RampFactor -Value 5 -Low 0 -High 10) 0.5 1e-9 'ramp midpoint'
Assert-Near (Get-RampFactor -Value -3 -Low 0 -High 10) 0.0 1e-9 'ramp below low'
Assert-Near (Get-RampFactor -Value 30 -Low 0 -High 10) 1.0 1e-9 'ramp above high'
Assert-Near (Get-RampFactor -Value 7 -Low 7 -High 7) 1.0 1e-9 'degenerate ramp does not divide by zero'

# ===========================================================================
Section 'solar geometry'
# ===========================================================================

# equinox-ish local noon at lat 50 -> altitude near (90 - 50) = ~40 deg
$noon = [datetime]::new(2026, 9, 22, 13, 0, 0, [DateTimeKind]::Local)
$altNoon = Get-SunAltitude -Lat $LAT -Lon $LON -When $noon
Assert-InRange $altNoon 30 45 'equinox local noon altitude is ~40 deg at lat 50'

$midnight = [datetime]::new(2026, 9, 22, 1, 0, 0, [DateTimeKind]::Local)
$altNight = Get-SunAltitude -Lat $LAT -Lon $LON -When $midnight
Assert-True ($altNight -lt -20) 'sun is well below the horizon at 01:00' "got $altNight"

# June must be higher than December at a northern latitude
$altJun = Get-SunAltitude -Lat $LAT -Lon $LON -When ([datetime]::new(2026, 6, 21, 13, 0, 0, [DateTimeKind]::Local))
$altDec = Get-SunAltitude -Lat $LAT -Lon $LON -When ([datetime]::new(2026,12, 21, 13, 0, 0, [DateTimeKind]::Local))
Assert-True ($altJun -gt $altDec + 30) 'June noon is far higher than December noon' `
    ("Jun $altJun vs Dec $altDec")

Assert-Near (Get-ClearSkyGhi -SunAltitudeDeg -5)  0.0 1e-9 'no clear-sky irradiance below the horizon'
Assert-Near (Get-ClearSkyGhi -SunAltitudeDeg 0)   0.0 1e-9 'no clear-sky irradiance at the horizon'
Assert-InRange (Get-ClearSkyGhi -SunAltitudeDeg 90) 900 1100 'clear-sky GHI at zenith is ~1000 W/m2'
Assert-InRange (Get-ClearSkyGhi -SunAltitudeDeg 38) 500 700 'clear-sky GHI at 38 deg is ~600 W/m2'

# monotonic in altitude
$prev = -1.0
$monoOk = $true
foreach ($a in 1..89) {
    $g = Get-ClearSkyGhi -SunAltitudeDeg $a
    if ($g -lt $prev) { $monoOk = $false; break }
    $prev = $g
}
Assert-True $monoOk 'clear-sky GHI rises monotonically with altitude'

# ===========================================================================
Section 'clearness index'
# ===========================================================================

Assert-Near (Get-ClearnessIndex -ActualGhi 600 -ClearSkyGhi 600) 1.0  1e-9 'full clear sky -> Kt 1.0'
Assert-Near (Get-ClearnessIndex -ActualGhi 150 -ClearSkyGhi 600) 0.25 1e-9 'heavy overcast -> Kt 0.25'
Assert-Near (Get-ClearnessIndex -ActualGhi 900 -ClearSkyGhi 600) 1.0  1e-9 'over-unity readings clamp to 1'
Assert-Null  (Get-ClearnessIndex -ActualGhi $null -ClearSkyGhi 600) 'missing irradiance -> $null, not a guess'
Assert-Null  (Get-ClearnessIndex -ActualGhi 10 -ClearSkyGhi 40) 'twilight (clear-sky below floor) -> $null'
Assert-Null  (Get-ClearnessIndex -ActualGhi -5 -ClearSkyGhi 600) 'negative irradiance is rejected'

# the real reading taken from this machine while building it: 429 W/m2, sun at 37.8 deg
$ktLive = Get-ClearnessIndex -ActualGhi 429 -ClearSkyGhi (Get-ClearSkyGhi -SunAltitudeDeg 37.8)
Assert-InRange $ktLive 0.6 0.8 'observed 429 W/m2 at 37.8 deg reads as partly cloudy (Kt ~0.7)'

# ===========================================================================
Section 'EMA smoothing'
# ===========================================================================

Assert-Near (Update-EmaValue -Previous $null -Sample 0.4 -DeltaSeconds 120 -TauSeconds 1200) 0.4 1e-9 `
    'cold start adopts the first sample outright'

# one tau of elapsed time should close ~63% of the gap
$e = Update-EmaValue -Previous 0.0 -Sample 1.0 -DeltaSeconds 1200 -TauSeconds 1200
Assert-Near $e 0.632 0.005 'one time constant closes ~63% of the gap'

# a short tick barely moves
$e = Update-EmaValue -Previous 0.0 -Sample 1.0 -DeltaSeconds 120 -TauSeconds 1200
Assert-InRange $e 0.05 0.15 'a 2-minute tick moves ~10% of the way (tau 20 min)'

# a very long gap (machine asleep overnight) lets the new sample dominate
$e = Update-EmaValue -Previous 0.0 -Sample 1.0 -DeltaSeconds 36000 -TauSeconds 1200
Assert-True ($e -gt 0.99) 'a 10-hour gap lets the fresh sample dominate' "got $e"

Assert-Near (Update-EmaValue -Previous 0.5 -Sample 0.9 -DeltaSeconds 0 -TauSeconds 1200) 0.5 1e-9 `
    'zero elapsed time changes nothing'

# EMA never overshoots the sample
$v = 0.2
foreach ($i in 1..500) { $v = Update-EmaValue -Previous $v -Sample 0.8 -DeltaSeconds 120 -TauSeconds 1200 }
Assert-InRange $v 0.2 0.8 'EMA converges without overshooting'
Assert-Near $v 0.8 0.01 'EMA converges to the sample'

# ===========================================================================
Section 'day ceiling (the actual fix for overcast noon)'
# ===========================================================================

$clear    = Get-DayCeiling -Kt 1.00
$partly   = Get-DayCeiling -Kt 0.50
$overcast = Get-DayCeiling -Kt 0.10

Assert-Near $clear    100 0.001 'clear sky -> full 100%'
Assert-Near $overcast  55 0.001 'heavy overcast -> overcast level 55%'
Assert-InRange $partly 60 80 'partly cloudy lands between the two'
Assert-True ($clear -gt $partly -and $partly -gt $overcast) 'day ceiling is monotonic in Kt'

# monotonic across the whole Kt domain
$prev = -1.0
$monoOk = $true
foreach ($i in 0..100) {
    $c = Get-DayCeiling -Kt ($i / 100.0)
    if ($c -lt $prev - 1e-9) { $monoOk = $false; break }
    $prev = $c
}
Assert-True $monoOk 'day ceiling never dips as the sky clears'

# ===========================================================================
Section 'target model'
# ===========================================================================

# THE headline case: same sun, different sky
$sunHigh = 38.0
$tClear    = (Get-TargetBrightness -SunAltitudeDeg $sunHigh -Kt 1.00).Target
$tOvercast = (Get-TargetBrightness -SunAltitudeDeg $sunHigh -Kt 0.15).Target
Assert-Near $tClear 100 0.001 'clear noon still reaches 100%'
Assert-InRange $tOvercast 50 60 'overcast noon settles near 55%, not 100%'
Assert-True (($tClear - $tOvercast) -gt 35) 'a dull sky is worth >35 points less than a bright one' `
    ("clear $tClear vs overcast $tOvercast")

# at night clouds must be irrelevant
$nClear    = (Get-TargetBrightness -SunAltitudeDeg -30 -Kt 1.00).Target
$nOvercast = (Get-TargetBrightness -SunAltitudeDeg -30 -Kt 0.05).Target
Assert-Near $nClear 9 0.001 'night level reached regardless of sky'
Assert-Near $nOvercast $nClear 1e-9 'cloud cover does not change the night level'

# floors and ceilings are hard
$t = (Get-TargetBrightness -SunAltitudeDeg -40 -Kt 0.0 -NightBrightness 1 -MinBrightness 5).Target
Assert-Near $t 5 1e-9 'MinBrightness floors a too-low night setting'
$t = (Get-TargetBrightness -SunAltitudeDeg 60 -Kt 1.0 -DayBrightness 140 -MaxBrightness 100).Target
Assert-Near $t 100 1e-9 'MaxBrightness caps a too-high day setting'

# every combination stays inside the configured envelope
$envOk = $true
foreach ($alt in -40..80) {
    foreach ($ktI in 0..10) {
        $t = (Get-TargetBrightness -SunAltitudeDeg $alt -Kt ($ktI / 10.0)).Target
        if ($t -lt 5 -or $t -gt 100) { $envOk = $false; break }
    }
}
Assert-True $envOk 'target stays within [Min, Max] for every altitude/Kt combination'

# ===========================================================================
Section 'rate limiting and deadband'
# ===========================================================================

$r = Resolve-AppliedBrightness -LastApplied $null -Target 72 -DeltaSeconds 120
Assert-Near $r.Applied 72 1e-9 'first run adopts the target immediately'
Assert-True $r.Changed 'first run counts as a change'

# a 50-point jump in one 2-minute tick must be limited to 12 pts/min * 2 min = 24
$r = Resolve-AppliedBrightness -LastApplied 50 -Target 100 -DeltaSeconds 120 -MaxRatePerMinute 12
Assert-Near $r.Applied 74 1e-9 'a big jump is rate limited to 24 pts in a 2-minute tick'
Assert-True $r.RateLimited 'the rate limiter reports that it engaged'

# small jitter is swallowed
$r = Resolve-AppliedBrightness -LastApplied 60 -Target 62 -DeltaSeconds 120 -DeadbandPct 4
Assert-Near $r.Applied 60 1e-9 'a 2-point move is inside the deadband'
Assert-True (-not $r.Changed) 'deadband suppresses the write'

# a move past the deadband goes through
$r = Resolve-AppliedBrightness -LastApplied 60 -Target 66 -DeltaSeconds 120 -DeadbandPct 4
Assert-Near $r.Applied 66 1e-9 'a 6-point move clears the deadband'
Assert-True $r.Changed 'a real move is applied'

# the deadband must not strand us off a hard limit
$r = Resolve-AppliedBrightness -LastApplied 7 -Target 5 -DeltaSeconds 120 -DeadbandPct 4 -MinBrightness 5
Assert-Near $r.Applied 5 1e-9 'small move onto the floor is allowed through the deadband'
Assert-True $r.Changed 'landing on a limit always applies'

$r = Resolve-AppliedBrightness -LastApplied 80 -Target 80 -DeltaSeconds 120
Assert-True (-not $r.Changed) 'already at target -> no write'

# rate limit scales with elapsed time
$r = Resolve-AppliedBrightness -LastApplied 0 -Target 100 -DeltaSeconds 600 -MaxRatePerMinute 12
Assert-Near $r.Applied 100 1e-9 'a 10-minute gap allows the full 120-point budget'

# ===========================================================================
Section 'SIMULATION: cloud bank arrives at noon (no jolt)'
# ===========================================================================
# Sun stays at 38 deg. Kt drops 0.95 -> 0.15 instantly and stays there.
# The display must walk down, never jump, and must settle near the overcast level.

$applied = 100.0
$ktEma   = 0.95
$series  = @()
$maxStep = 0.0
$tick    = 120.0

foreach ($i in 1..90) {
    $sampleKt = 0.15                                   # cloud bank, hard step
    $ktEma = Update-EmaValue -Previous $ktEma -Sample $sampleKt -DeltaSeconds $tick -TauSeconds 1200
    $t = (Get-TargetBrightness -SunAltitudeDeg 38 -Kt $ktEma).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied -Target $t -DeltaSeconds $tick
    $step = [Math]::Abs($r.Applied - $applied)
    if ($step -gt $maxStep) { $maxStep = $step }
    $applied = $r.Applied
    $series += $applied
}

Assert-True ($maxStep -le 24.0) 'no single step exceeds the rate limit during a cloud burst' "max step $maxStep"
Assert-True ($maxStep -le 12.0) 'in practice the EMA keeps steps well under the rate cap' "max step $maxStep"
Assert-InRange $applied 50 60 'settles at the overcast level after the cloud bank'
# strictly non-increasing: a falling input must never produce a rise
$risesOk = $true
for ($i = 1; $i -lt $series.Count; $i++) { if ($series[$i] -gt $series[$i-1] + 1e-9) { $risesOk = $false } }
Assert-True $risesOk 'a monotonically falling sky never produces a brightness rise'

# ===========================================================================
Section 'SIMULATION: broken cloud / noisy sky (oscillation guard)'
# ===========================================================================
# Sun fixed at 40 deg. Kt is 0.6 with heavy +/-0.3 noise - sun darting in and out.
# Without smoothing this is the scenario that makes a panel visibly flicker.

$rng = [System.Random]::new(20260922)
$applied = 78.0
$ktEma   = 0.6
$writes  = 0
$reversals = 0
$lastDir = 0
$maxStep = 0.0
$vals = @()

foreach ($i in 1..240) {                                # 8 hours of 2-minute ticks
    $sampleKt = Get-Clamped -Value (0.6 + ($rng.NextDouble() - 0.5) * 0.6) -Min 0 -Max 1
    $ktEma = Update-EmaValue -Previous $ktEma -Sample $sampleKt -DeltaSeconds $tick -TauSeconds 1800
    $t = (Get-TargetBrightness -SunAltitudeDeg 40 -Kt $ktEma).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied -Target $t -DeltaSeconds $tick
    if ($r.Changed) {
        $writes++
        $dir = 0
        if ($r.Applied -gt $applied) { $dir = 1 } else { $dir = -1 }
        if ($lastDir -ne 0 -and $dir -ne $lastDir) { $reversals++ }
        $lastDir = $dir
        $step = [Math]::Abs($r.Applied - $applied)
        if ($step -gt $maxStep) { $maxStep = $step }
        $applied = $r.Applied
    }
    $vals += $applied
}

$span = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
Write-Host ("         noisy sky: $writes writes, $reversals reversals, span {0:N1} pts, max step {1:N1}" -f $span, $maxStep) -ForegroundColor DarkGray

Assert-True ($writes -le 40) 'a noisy sky produces few writes, not one per tick' "$writes writes in 240 ticks"
Assert-True ($reversals -le 12) 'direction reversals stay rare (no flicker)' "$reversals reversals"
Assert-True ($maxStep -le 12.0) 'no large step under noise' "max step $maxStep"
Assert-True ($span -le 25.0) 'total excursion stays modest under +/-0.3 Kt noise' "span $span"

# ===========================================================================
Section 'SIMULATION: full clear day, sunrise to midnight'
# ===========================================================================

$applied = $null
$ktEma   = $null
$maxStep = 0.0
$stepsOver8 = 0
$day = [datetime]::new(2026, 6, 21, 0, 0, 0, [DateTimeKind]::Local)
$trace = @()

foreach ($i in 0..719) {                                  # 24 h at 2-minute ticks
    $when = $day.AddMinutes($i * 2)
    $alt  = Get-SunAltitude -Lat $LAT -Lon $LON -When $when
    $csky = Get-ClearSkyGhi -SunAltitudeDeg $alt
    $ghi  = $csky * 0.95                                  # a clear day
    $kt   = Get-ClearnessIndex -ActualGhi $ghi -ClearSkyGhi $csky

    $eff = Get-EffectiveClearness -SampleKt $kt -PreviousKt $ktEma `
              -PreviousAgeSeconds 0 -DeltaSeconds $tick -SunTooLowToMeasure ($null -eq $kt)
    $ktEma = $eff.PersistKt

    $t = (Get-TargetBrightness -SunAltitudeDeg $alt -Kt $eff.Kt).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied -Target $t -DeltaSeconds $tick
    if ($null -ne $applied) {
        $step = [Math]::Abs($r.Applied - $applied)
        if ($step -gt $maxStep) { $maxStep = $step }
        if ($step -gt 8) { $stepsOver8++ }
    }
    $applied = $r.Applied
    $trace += [pscustomobject]@{ Time = $when; Alt = $alt; Kt = $ktEma; Applied = $applied }
}

$noonRow  = $trace | Where-Object { $_.Time.Hour -eq 13 } | Select-Object -First 1
$nightRow = $trace | Where-Object { $_.Time.Hour -eq 1 }  | Select-Object -First 1

Assert-InRange $noonRow.Applied 90 100 'clear midsummer noon reaches near-full brightness'
Assert-InRange $nightRow.Applied 5 12 'deep night sits at the night level'
Assert-True ($maxStep -le 12.0) 'no step over a full clear day exceeds 12 points' "max step $maxStep"
Assert-True ($stepsOver8 -eq 0) 'no step over a full clear day even exceeds 8 points' "$stepsOver8 such steps"

# and the same day, overcast throughout, must peak much lower
$applied2 = $null; $ktEma2 = $null; $peak2 = 0.0
foreach ($i in 0..719) {
    $when = $day.AddMinutes($i * 2)
    $alt  = Get-SunAltitude -Lat $LAT -Lon $LON -When $when
    $csky = Get-ClearSkyGhi -SunAltitudeDeg $alt
    $kt   = Get-ClearnessIndex -ActualGhi ($csky * 0.18) -ClearSkyGhi $csky
    $eff  = Get-EffectiveClearness -SampleKt $kt -PreviousKt $ktEma2 -PreviousAgeSeconds 0 -DeltaSeconds $tick -SunTooLowToMeasure ($null -eq $kt)
    $ktEma2 = $eff.PersistKt
    $t = (Get-TargetBrightness -SunAltitudeDeg $alt -Kt $eff.Kt).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied2 -Target $t -DeltaSeconds $tick
    $applied2 = $r.Applied
    if ($applied2 -gt $peak2) { $peak2 = $applied2 }
}
Assert-InRange $peak2 50 62 'an overcast midsummer day peaks near the overcast level'
Assert-True (($noonRow.Applied - $peak2) -gt 30) 'clear vs overcast day differ by >30 points at peak' `
    ("clear $($noonRow.Applied) vs overcast peak $peak2")

# ===========================================================================
Section 'unavailable data'
# ===========================================================================

# no sample, no history -> neutral fallback
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt $null -PreviousAgeSeconds 0 -DeltaSeconds 120
Assert-Near $eff.Kt 0.50 1e-9 'no data at all -> neutral fallback Kt'
Assert-True (-not $eff.IsFresh) 'fallback is not reported as fresh'
Assert-Null $eff.PersistKt 'a fallback guess is NOT persisted, so the next real reading cold-starts'

# regression guard for the overcast-dawn spike: a guess must not survive into the average
$eff2 = Get-EffectiveClearness -SampleKt 0.18 -PreviousKt $eff.PersistKt -PreviousAgeSeconds 0 -DeltaSeconds 120
Assert-Near $eff2.Kt 0.18 1e-9 'the first real reading after a fallback is adopted outright, not blended with the default'

# --- night hold: Kt is undefined after dark, not missing ---
# an overcast evening's Kt must survive the whole night without decaying, so a grey
# morning starts grey instead of blasting to full and crawling back down
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt 0.18 -PreviousAgeSeconds 40000 `
                              -DeltaSeconds 120 -SunTooLowToMeasure $true
Assert-Near $eff.Kt 0.18 1e-9 'an overcast sky is held through the night, however long'
Assert-Near $eff.PersistKt 0.18 1e-9 'and it is persisted unchanged'
Assert-True ($eff.Source -like '*sun too low*') 'the night hold is reported in the source'

# the staleness clock must genuinely be ignored, not merely slowed
$k = 0.18
foreach ($i in 1..360) {                                 # 12 hours of darkness
    $eff = Get-EffectiveClearness -SampleKt $null -PreviousKt $k -PreviousAgeSeconds ($i * 120.0) `
                                  -DeltaSeconds 120 -SunTooLowToMeasure $true
    $k = $eff.PersistKt
}
Assert-Near $k 0.18 1e-9 'twelve hours of darkness does not move the held sky estimate'

# but a *daytime* outage still decays - the two cases must not be conflated
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt 0.18 -PreviousAgeSeconds 40000 `
                              -DeltaSeconds 120 -SunTooLowToMeasure $false
Assert-True ($eff.Kt -gt 0.18) 'a daytime outage of the same age still decays' "got $($eff.Kt)"

# first-ever run at night, with no history at all, must not throw
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt $null -PreviousAgeSeconds 0 `
                              -DeltaSeconds 120 -SunTooLowToMeasure $true
Assert-Near $eff.Kt 0.50 1e-9 'a first-ever run after dark falls back safely'
Assert-Null $eff.PersistKt 'and still refuses to persist the guess'

# no sample, young cache -> hold it exactly
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt 0.30 -PreviousAgeSeconds 1800 -DeltaSeconds 120
Assert-Near $eff.Kt 0.30 1e-9 'a 30-minute-old cache is held as-is'
Assert-True ($eff.Source -like 'cached*') 'cache use is reported in the source'

# no sample, stale cache -> drift toward fallback, do not jump
$eff = Get-EffectiveClearness -SampleKt $null -PreviousKt 0.20 -PreviousAgeSeconds 20000 -DeltaSeconds 120
Assert-True ($eff.Kt -gt 0.20) 'a stale cache drifts toward the fallback' "got $($eff.Kt)"
Assert-True ($eff.Kt -lt 0.25) 'the drift is gradual, not a jump to 0.85' "got $($eff.Kt)"
Assert-True ($eff.Source -like 'stale*') 'staleness is reported in the source'

# a long outage must eventually converge on the fallback, monotonically
$k = 0.20; $age = 20000.0; $prevK = $k; $monoOk = $true
foreach ($i in 1..600) {
    $eff = Get-EffectiveClearness -SampleKt $null -PreviousKt $k -PreviousAgeSeconds $age -DeltaSeconds 120
    $k = $eff.PersistKt; $age += 120
    if ($k -lt $prevK - 1e-9) { $monoOk = $false }
    $prevK = $k
}
Assert-True $monoOk 'the stale drift never reverses direction'
Assert-Near $k 0.50 0.02 'a 20-hour outage converges on the fallback Kt'

# recovery: a fresh sample after an outage is eased in, not snapped
$eff = Get-EffectiveClearness -SampleKt 0.10 -PreviousKt 0.50 -PreviousAgeSeconds 20000 -DeltaSeconds 120
Assert-True ($eff.IsFresh) 'recovery is reported as fresh'
# nudged toward the new reading, nowhere near snapped onto it
Assert-InRange $eff.Kt 0.44 0.50 'the first sample after recovery only nudges the estimate'
Assert-True ($eff.Kt -gt 0.10 + 0.3) 'recovery does not snap straight to the new reading' "got $($eff.Kt)"

# an outage in the middle of a day must not move the panel far
$applied = 96.0; $ktEma = 0.95; $age = 0.0; $maxStep = 0.0
foreach ($i in 1..60) {                                  # 2 hours with the API down
    $age += $tick
    $eff = Get-EffectiveClearness -SampleKt $null -PreviousKt $ktEma -PreviousAgeSeconds $age -DeltaSeconds $tick
    $ktEma = $eff.PersistKt
    $t = (Get-TargetBrightness -SunAltitudeDeg 40 -Kt $eff.Kt).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied -Target $t -DeltaSeconds $tick
    $step = [Math]::Abs($r.Applied - $applied)
    if ($step -gt $maxStep) { $maxStep = $step }
    $applied = $r.Applied
}
Assert-True ($maxStep -le 12.0) 'a 2-hour outage causes no large step' "max step $maxStep"
Assert-InRange $applied 88 100 'a 2-hour outage on a clear day holds brightness roughly steady'

# ===========================================================================
Section 'manual override detection'
# ===========================================================================

$o = Test-ManualOverride -LastApplied 70 -ObservedBrightness 70
Assert-True (-not $o.IsOverridden) 'panel matching the commanded level is not an override'

$o = Test-ManualOverride -LastApplied 70 -ObservedBrightness 72 -TolerancePct 3
Assert-True (-not $o.IsOverridden) 'a 2-point DDC rounding gap is not an override'

$o = Test-ManualOverride -LastApplied 70 -ObservedBrightness 30 -TolerancePct 3
Assert-True $o.IsOverridden 'a 40-point gap is a manual override'
Assert-True ($o.Reason -like '*30*') 'the override reason names the observed level'

$o = Test-ManualOverride -LastApplied 70 -ObservedBrightness 95 -TolerancePct 3
Assert-True $o.IsOverridden 'an override upward is detected too'

$o = Test-ManualOverride -LastApplied $null -ObservedBrightness 50
Assert-True (-not $o.IsOverridden) 'with nothing commanded yet there is nothing to override'

$o = Test-ManualOverride -LastApplied 70 -ObservedBrightness $null
Assert-True (-not $o.IsOverridden) 'an unreadable panel is not treated as an override'

# our own rate-limited walk must never look like an override
$applied = 100.0; $ktEma = 0.95; $falsePositives = 0
foreach ($i in 1..60) {
    $ktEma = Update-EmaValue -Previous $ktEma -Sample 0.15 -DeltaSeconds $tick -TauSeconds 1200
    $t = (Get-TargetBrightness -SunAltitudeDeg 38 -Kt $ktEma).Target
    $r = Resolve-AppliedBrightness -LastApplied $applied -Target $t -DeltaSeconds $tick
    # the panel faithfully reports what we last commanded
    $o = Test-ManualOverride -LastApplied $applied -ObservedBrightness $applied
    if ($o.IsOverridden) { $falsePositives++ }
    $applied = $r.Applied
}
Assert-True ($falsePositives -eq 0) 'our own adjustments never self-trigger override detection' `
    ("$falsePositives false positives")

# ===========================================================================
Write-Host ''
Write-Host ('=' * 60)
$total = $script:Passed + $script:Failed
if ($script:Failed -eq 0) {
    Write-Host ("ALL {0} TESTS PASSED" -f $total) -ForegroundColor Green
    Write-Host ('=' * 60)
    exit 0
} else {
    Write-Host ("{0} of {1} TESTS FAILED" -f $script:Failed, $total) -ForegroundColor Red
    Write-Host ('=' * 60)
    exit 1
}
