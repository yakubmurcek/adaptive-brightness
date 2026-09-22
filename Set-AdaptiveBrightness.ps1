<#
.SYNOPSIS
  Sets external monitor brightness (DDC/CI) from the sun's altitude AND the current sky.

.DESCRIPTION
  Sun altitude decides day vs night. Measured solar irradiance decides how bright "day"
  is worth today, so an overcast noon no longer gets the same level as a dazzling one.

  All decision logic lives in BrightnessCore.ps1 and is pure; this script is the
  plumbing around it - config, persisted state, the weather call, DDC/CI, and logging.

.EXAMPLE
  .\Set-AdaptiveBrightness.ps1
  One normal tick. This is what the scheduled task runs.

.EXAMPLE
  .\Set-AdaptiveBrightness.ps1 -Status
  Show what it would do and why, touching nothing.

.EXAMPLE
  .\Set-AdaptiveBrightness.ps1 -SimulateKt 0.15 -WhatIfOnly
  Pretend the sky is heavily overcast and print the resulting target.

.EXAMPLE
  .\Set-AdaptiveBrightness.ps1 -Pause
  Stop adjusting until -Resume. Survives reboots.
#>
[CmdletBinding()]
param(
    [double]$Latitude,
    [double]$Longitude,

    # brightness envelope
    [int]   $DayBrightness,          # clear-sky daytime level
    [int]   $OvercastBrightness,     # heavy-overcast daytime level
    [int]   $NightBrightness,
    [int]   $MinBrightness,
    [int]   $MaxBrightness,

    # sun altitude ramp
    [double]$RampLowDeg,
    [double]$RampHighDeg,

    # sky ramp
    [double]$KtLow,
    [double]$KtHigh,
    [double]$KtFallback,
    [double]$KtTauMinutes,
    [double]$KtMaxAgeMinutes,

    # actuation
    [double]$MaxRatePerMinute,
    [double]$DeadbandPct,
    [int]   $GlideStepMs,
    [double]$OverrideTolerancePct,
    [int]   $OverrideMinutes,
    [double]$MaxCatchUpMinutes,

    [int]   $TimeoutSec,

    # modes
    [datetime]$TestTime,             # evaluate another moment (uses the current sky)
    [double]$SimulateKt,             # pretend the sky is this clear; skips the network
    [switch]$Offline,                # skip the network entirely
    [switch]$WhatIfOnly,             # decide and log, but never touch the monitor
    [switch]$Status,                 # print state and exit
    [switch]$Pause,
    [switch]$Resume,
    [switch]$ClearOverride,
    [switch]$Quiet                   # no console output (the scheduled task uses this)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'BrightnessCore.ps1')

$ConfigPath = Join-Path $PSScriptRoot 'config.json'
$StatePath  = Join-Path $PSScriptRoot 'state.json'
$LogPath    = Join-Path $PSScriptRoot 'brightness.log'

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------

$script:LogLines = New-Object System.Collections.ArrayList

function Write-Log {
    param([string]$Message, [string]$Level = 'info')

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    [void]$script:LogLines.Add($line)
    if (-not $Quiet) {
        $colour = 'Gray'
        switch ($Level) {
            'warn'  { $colour = 'Yellow' }
            'error' { $colour = 'Red' }
            'act'   { $colour = 'Green' }
        }
        Write-Host $line -ForegroundColor $colour
    }
}

function Save-Log {
    if ($script:LogLines.Count -eq 0) { return }
    try {
        # keep the log from growing without bound
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item $LogPath "$LogPath.1" -Force
        }
        # UTF8 explicitly: PowerShell's ">>" redirection writes UTF-16, which made the
        # old log unreadable in anything but a Windows editor
        Add-Content -Path $LogPath -Value $script:LogLines -Encoding UTF8
    } catch {
        if (-not $Quiet) { Write-Host "could not write log: $_" -ForegroundColor Red }
    }
}

# ---------------------------------------------------------------------------
# config
# ---------------------------------------------------------------------------

$Defaults = [ordered]@{
    Latitude             = $null
    Longitude            = $null
    DayBrightness        = 100
    OvercastBrightness   = 55
    NightBrightness      = 9
    MinBrightness        = 5
    MaxBrightness        = 100
    RampLowDeg           = -12.0
    RampHighDeg          = 14.0
    KtLow                = 0.25
    KtHigh               = 0.95
    KtFallback           = 0.50
    KtTauMinutes         = 30.0
    KtMaxAgeMinutes      = 180.0
    MaxRatePerMinute     = 3.0
    DeadbandPct          = 4.0
    GlideStepMs          = 25
    OverrideTolerancePct = 6.0
    OverrideMinutes      = 120
    MaxCatchUpMinutes    = 10.0
    TimeoutSec           = 10
}

$Cfg = [ordered]@{}
foreach ($k in $Defaults.Keys) { $Cfg[$k] = $Defaults[$k] }

if (Test-Path $ConfigPath) {
    try {
        $fileCfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($k in @($Cfg.Keys)) {
            if ($null -ne $fileCfg.PSObject.Properties[$k] -and $null -ne $fileCfg.$k) {
                $Cfg[$k] = $fileCfg.$k
            }
        }
    } catch {
        Write-Log "config.json is unreadable ($($_.Exception.Message)); using defaults" 'warn'
    }
}

# explicit parameters beat the file
foreach ($k in @($Cfg.Keys)) {
    if ($PSBoundParameters.ContainsKey($k)) { $Cfg[$k] = $PSBoundParameters[$k] }
}

if ($null -eq $Cfg.Latitude -or $null -eq $Cfg.Longitude) {
    Write-Log "No location configured. Run Install.ps1, or pass -Latitude and -Longitude." 'error'
    Save-Log
    exit 1
}

# guard against a config that would invert or collapse the model
if ($Cfg.MinBrightness -gt $Cfg.MaxBrightness) {
    Write-Log "MinBrightness > MaxBrightness; swapping them" 'warn'
    $t = $Cfg.MinBrightness; $Cfg.MinBrightness = $Cfg.MaxBrightness; $Cfg.MaxBrightness = $t
}
if ($Cfg.KtLow -ge $Cfg.KtHigh) {
    Write-Log "KtLow >= KtHigh; falling back to 0.25 / 0.95" 'warn'
    $Cfg.KtLow = 0.25; $Cfg.KtHigh = 0.95
}

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

function Read-State {
    $s = [ordered]@{
        Kt = $null; KtTimestamp = $null; LastApplied = $null
        LastRun = $null; OverrideUntil = $null; Paused = $false
    }
    if (-not (Test-Path $StatePath)) { return $s }
    try {
        $f = Get-Content $StatePath -Raw | ConvertFrom-Json
        foreach ($k in @($s.Keys)) {
            if ($null -ne $f.PSObject.Properties[$k] -and $null -ne $f.$k) { $s[$k] = $f.$k }
        }
    } catch {
        Write-Log "state.json is unreadable ($($_.Exception.Message)); starting fresh" 'warn'
    }
    return $s
}

function Save-State {
    param($State)
    try {
        ([pscustomobject]$State) | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    } catch {
        Write-Log "could not write state.json: $($_.Exception.Message)" 'warn'
    }
}

function ConvertTo-DateTimeOrNull {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

$State = Read-State

# ---------------------------------------------------------------------------
# DDC/CI
# ---------------------------------------------------------------------------

if (-not ('DDC' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DDC {
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr h, IntPtr c, MonitorEnumProc p, IntPtr d);
  public delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr data);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct PHYSICAL_MONITOR { public IntPtr hPhysicalMonitor; [MarshalAs(UnmanagedType.ByValArray, SizeConst=128)] public char[] szDescription; }
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, ref uint n);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] m);
  [DllImport("dxva2.dll")] public static extern bool GetMonitorBrightness(IntPtr h, ref uint min, ref uint cur, ref uint max);
  [DllImport("dxva2.dll")] public static extern bool SetMonitorBrightness(IntPtr h, uint b);
  [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitor(IntPtr h);
}
'@
}

function Get-PhysicalMonitorHandles {
    $handles = New-Object System.Collections.ArrayList
    $cb = [DDC+MonitorEnumProc]{ param($hMon, $hdc, $lprc, $data) [void]$handles.Add($hMon); return $true }
    [void][DDC]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)

    $result = New-Object System.Collections.ArrayList
    foreach ($hm in $handles) {
        $count = 0
        if (-not [DDC]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$count)) { continue }
        if ($count -le 0) { continue }
        $mons = New-Object DDC+PHYSICAL_MONITOR[] $count
        if (-not [DDC]::GetPhysicalMonitorsFromHMONITOR($hm, $count, $mons)) { continue }
        foreach ($m in $mons) { [void]$result.Add($m) }
    }
    return $result
}

function Get-MonitorReadings {
    <#
      Reads every DDC-capable monitor. Returns objects carrying the live handle, so the
      caller must dispose them with Close-MonitorReadings.
    #>
    $readings = New-Object System.Collections.ArrayList
    foreach ($m in (Get-PhysicalMonitorHandles)) {
        $name = ([String]::new($m.szDescription)).Trim([char]0)
        $min = 0; $cur = 0; $max = 0
        if ([DDC]::GetMonitorBrightness($m.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)) {
            $span = [double]($max - $min)
            $pct = $null
            if ($span -gt 0) { $pct = (([double]$cur - $min) / $span) * 100.0 }
            [void]$readings.Add([pscustomobject]@{
                Handle = $m.hPhysicalMonitor; Name = $name
                Min = [int]$min; Cur = [int]$cur; Max = [int]$max; Percent = $pct
                Supported = $true
            })
        } else {
            [void][DDC]::DestroyPhysicalMonitor($m.hPhysicalMonitor)
            Write-Log "  $name : no DDC/CI brightness support, skipped" 'warn'
        }
    }
    return $readings
}

function Close-MonitorReadings {
    param($Readings)
    foreach ($r in $Readings) { [void][DDC]::DestroyPhysicalMonitor($r.Handle) }
}

function Set-MonitorPercent {
    <#
      Fades one raw point at a time so even a large correction glides. The rate limiter
      upstream keeps corrections small; this is purely about the visual quality of the
      move itself.
    #>
    param($Reading, [double]$Percent, [int]$StepMs)

    $target = [int][Math]::Round($Reading.Min + ($Reading.Max - $Reading.Min) * ($Percent / 100.0))
    $target = [int](Get-Clamped -Value $target -Min $Reading.Min -Max $Reading.Max)
    if ($target -eq $Reading.Cur) { return $target }

    $step = 1
    if ($target -lt $Reading.Cur) { $step = -1 }
    for ($v = $Reading.Cur + $step; ; $v += $step) {
        [void][DDC]::SetMonitorBrightness($Reading.Handle, [uint32]$v)
        if ($v -eq $target) { break }
        if ($StepMs -gt 0) { Start-Sleep -Milliseconds $StepMs }
    }
    return $target
}

# ---------------------------------------------------------------------------
# irradiance
# ---------------------------------------------------------------------------

function Get-CurrentGhi {
    <#
      Current global horizontal irradiance in W/m^2 from Open-Meteo. No API key, no
      account. Returns $null on any failure - the caller is built to cope with that,
      and a brightness controller must never hard-fail because the weather is unreachable.
    #>
    param([double]$Lat, [double]$Lon, [int]$TimeoutSec)

    $uri = 'https://api.open-meteo.com/v1/forecast' +
           ('?latitude={0}&longitude={1}' -f $Lat.ToString([Globalization.CultureInfo]::InvariantCulture),
                                              $Lon.ToString([Globalization.CultureInfo]::InvariantCulture)) +
           '&current=shortwave_radiation,direct_radiation,cloud_cover&timezone=auto'
    try {
        $r = Invoke-RestMethod -Uri $uri -TimeoutSec $TimeoutSec -ErrorAction Stop
        $ghi = [double]$r.current.shortwave_radiation
        $cc  = $null
        if ($null -ne $r.current.PSObject.Properties['cloud_cover']) { $cc = [double]$r.current.cloud_cover }
        # logged for diagnosis only - it explains why a sky that *looks* cloudy can still
        # read as bright (broken cloud with the sun visible) and vice versa
        $direct = $null
        if ($null -ne $r.current.PSObject.Properties['direct_radiation']) { $direct = [double]$r.current.direct_radiation }
        return @{ Ghi = $ghi; CloudCover = $cc; Direct = $direct }
    } catch {
        Write-Log "irradiance fetch failed: $($_.Exception.Message)" 'warn'
        return $null
    }
}

# ---------------------------------------------------------------------------
# mode switches that exit early
# ---------------------------------------------------------------------------

$now = Get-Date
if ($PSBoundParameters.ContainsKey('TestTime')) { $now = $TestTime }

if ($Pause) {
    $State.Paused = $true
    Save-State $State
    Write-Log "paused - brightness will not be adjusted until -Resume" 'act'
    Save-Log; exit 0
}
if ($Resume) {
    $State.Paused = $false
    $State.OverrideUntil = $null
    Save-State $State
    Write-Log "resumed" 'act'
    Save-Log; exit 0
}
if ($ClearOverride) {
    $State.OverrideUntil = $null
    Save-State $State
    Write-Log "manual override cleared" 'act'
    Save-Log; exit 0
}

# ---------------------------------------------------------------------------
# the tick
# ---------------------------------------------------------------------------

$lastRun = ConvertTo-DateTimeOrNull $State.LastRun
$deltaSeconds = 120.0
if ($null -ne $lastRun) {
    $deltaSeconds = ($now - $lastRun).TotalSeconds
    if ($deltaSeconds -lt 0) { $deltaSeconds = 120.0 }   # clock moved backwards
}

# The rate limiter gets its own, capped, elapsed time.
#
# The EMA genuinely wants the true gap - after a long sleep the old sky estimate really
# is worthless and fresh data should dominate. The actuator wants the opposite: coming
# back from an eight-hour hibernation with an eight-hour change budget means the panel
# snaps, which is precisely what this whole design exists to avoid. Capping it keeps the
# first tick after a long gap a brisk correction rather than a jolt.
$actuationDelta = [Math]::Min($deltaSeconds, $Cfg.MaxCatchUpMinutes * 60.0)

# ---- where is the sun ----
$alt  = Get-SunAltitude -Lat $Cfg.Latitude -Lon $Cfg.Longitude -When $now
$csky = Get-ClearSkyGhi -SunAltitudeDeg $alt

# ---- what is the sky doing ----
$sampleKt = $null
$ghiText  = 'not fetched'
$sunTooLow = ($csky -lt 60.0)

if ($PSBoundParameters.ContainsKey('SimulateKt')) {
    $sampleKt = Get-Clamped -Value $SimulateKt -Min 0.0 -Max 1.0
    $ghiText  = "simulated Kt $([Math]::Round($sampleKt,2))"
    $sunTooLow = $false
} elseif ($Offline) {
    $ghiText = 'offline mode'
} elseif ($sunTooLow) {
    $ghiText = 'sun too low to measure'
} else {
    $obs = Get-CurrentGhi -Lat $Cfg.Latitude -Lon $Cfg.Longitude -TimeoutSec $Cfg.TimeoutSec
    if ($null -ne $obs) {
        $sampleKt = Get-ClearnessIndex -ActualGhi $obs.Ghi -ClearSkyGhi $csky
        $ccText = ''
        if ($null -ne $obs.CloudCover) { $ccText = ", cloud $([int]$obs.CloudCover)%" }
        if ($null -ne $obs.Direct -and $obs.Ghi -gt 0) {
            $ccText += ", direct $([int](100.0 * $obs.Direct / $obs.Ghi))%"
        }
        $ghiText = "GHI $([int]$obs.Ghi) of $([int]$csky) W/m2$ccText"
    }
}

$ktAgeSeconds = 1e9
$ktStamp = ConvertTo-DateTimeOrNull $State.KtTimestamp
if ($null -ne $ktStamp) { $ktAgeSeconds = [Math]::Max(0.0, ($now - $ktStamp).TotalSeconds) }

$prevKt = $null
if ($null -ne $State.Kt) { $prevKt = [double]$State.Kt }

$eff = Get-EffectiveClearness -SampleKt $sampleKt -PreviousKt $prevKt `
          -PreviousAgeSeconds $ktAgeSeconds -DeltaSeconds $deltaSeconds `
          -SunTooLowToMeasure $sunTooLow `
          -TauSeconds ($Cfg.KtTauMinutes * 60.0) `
          -MaxAgeSeconds ($Cfg.KtMaxAgeMinutes * 60.0) `
          -KtFallback $Cfg.KtFallback

# ---- what should the brightness be ----
$model = Get-TargetBrightness -SunAltitudeDeg $alt -Kt $eff.Kt `
            -DayBrightness $Cfg.DayBrightness -OvercastBrightness $Cfg.OvercastBrightness `
            -NightBrightness $Cfg.NightBrightness -RampLowDeg $Cfg.RampLowDeg `
            -RampHighDeg $Cfg.RampHighDeg -KtLow $Cfg.KtLow -KtHigh $Cfg.KtHigh `
            -MinBrightness $Cfg.MinBrightness -MaxBrightness $Cfg.MaxBrightness

Write-Log ("sun {0,6:N2} deg | {1} | Kt {2:N2} ({3}) | ceiling {4:N0}% | target {5:N0}%" -f `
           $alt, $ghiText, $eff.Kt, $eff.Source, $model.DayCeiling, $model.Target)

# ---- read the panel ----
$readings = @()
$observedPct = $null
if (-not $WhatIfOnly -or $Status) {
    $readings = Get-MonitorReadings
    if ($readings.Count -gt 0) { $observedPct = $readings[0].Percent }
}

try {
    $lastApplied = $null
    if ($null -ne $State.LastApplied) { $lastApplied = [double]$State.LastApplied }

    # ---- status mode ----
    if ($Status) {
        Write-Log ("state: lastApplied {0} | panel {1} | paused {2} | overrideUntil {3}" -f `
            $(if ($null -eq $lastApplied) { 'none' } else { '{0:N0}%' -f $lastApplied }),
            $(if ($null -eq $observedPct) { 'unreadable' } else { '{0:N0}%' -f $observedPct }),
            $State.Paused,
            $(if ($null -eq $State.OverrideUntil) { 'none' } else { $State.OverrideUntil }))
        foreach ($r in $readings) {
            Write-Log ("  {0} : {1} raw (range {2}-{3}) = {4:N0}%" -f $r.Name, $r.Cur, $r.Min, $r.Max, $r.Percent)
        }
        Save-Log; exit 0
    }

    # A tick that stands down still counts as a tick. If we skipped this, the rate
    # limiter's elapsed-time budget would keep accruing for the whole pause or override,
    # and the first tick that did act would be allowed to move the panel arbitrarily far
    # in one go - exactly the snap we are trying to prevent.
    function Save-StandDown {
        $State.LastRun = $now.ToString('o')
        if ($eff.IsFresh) { $State.Kt = $eff.PersistKt; $State.KtTimestamp = $now.ToString('o') }
        Save-State $State
    }

    # ---- paused ----
    if ($State.Paused) {
        Write-Log "paused; not adjusting (use -Resume)" 'warn'
        Save-StandDown
        Save-Log; exit 0
    }

    # ---- an override already in force ----
    $overrideUntil = ConvertTo-DateTimeOrNull $State.OverrideUntil
    if ($null -ne $overrideUntil -and $now -lt $overrideUntil) {
        $mins = [int]([Math]::Ceiling(($overrideUntil - $now).TotalMinutes))
        Write-Log "manual override active for another $mins min; not adjusting" 'warn'
        Save-StandDown
        Save-Log; exit 0
    }
    if ($null -ne $overrideUntil -and $now -ge $overrideUntil) {
        Write-Log "manual override expired; resuming automatic control"
        $State.OverrideUntil = $null
    }

    # ---- did the user touch the monitor ----
    if (-not $WhatIfOnly) {
        $ov = Test-ManualOverride -LastApplied $lastApplied -ObservedBrightness $observedPct `
                                  -TolerancePct $Cfg.OverrideTolerancePct
        if ($ov.IsOverridden) {
            $State.OverrideUntil = $now.AddMinutes($Cfg.OverrideMinutes).ToString('o')
            # adopt the panel's level so that when the override lapses we ease on from
            # where the user left it rather than snapping back to our stale idea
            $State.LastApplied = $observedPct
            $State.LastRun = $now.ToString('o')
            if ($eff.IsFresh) { $State.Kt = $eff.PersistKt; $State.KtTimestamp = $now.ToString('o') }
            Save-State $State
            Write-Log ("manual change detected ({0}); standing down for {1} min" -f `
                       $ov.Reason, $Cfg.OverrideMinutes) 'warn'
            Save-Log; exit 0
        }
    }

    # ---- decide the move ----
    $decision = Resolve-AppliedBrightness -LastApplied $lastApplied -Target $model.Target `
                    -DeltaSeconds $actuationDelta -MaxRatePerMinute $Cfg.MaxRatePerMinute `
                    -DeadbandPct $Cfg.DeadbandPct `
                    -MinBrightness $Cfg.MinBrightness -MaxBrightness $Cfg.MaxBrightness

    if (-not $decision.Changed) {
        Write-Log ("holding at {0:N0}% - {1}" -f $decision.Applied, $decision.Reason)
    } else {
        Write-Log ("{0:N0}% -> {1:N0}% ({2})" -f `
                   $(if ($null -eq $lastApplied) { $decision.Applied } else { $lastApplied }),
                   $decision.Applied, $decision.Reason) 'act'
    }

    if ($WhatIfOnly) {
        Write-Log "-WhatIfOnly: monitor not touched"
        Save-Log; exit 0
    }

    if ($readings.Count -eq 0) {
        Write-Log "no DDC/CI capable monitor found; nothing to set" 'warn'
        Save-Log; exit 0
    }

    # ---- apply ----
    if ($decision.Changed) {
        foreach ($r in $readings) {
            $raw = Set-MonitorPercent -Reading $r -Percent $decision.Applied -StepMs $Cfg.GlideStepMs
            Write-Log ("  {0} : {1} -> {2} raw (range {3}-{4})" -f $r.Name, $r.Cur, $raw, $r.Min, $r.Max)
        }
    }

    # ---- persist ----
    $State.LastApplied = $decision.Applied
    $State.LastRun     = $now.ToString('o')
    if ($eff.IsFresh) {
        $State.Kt = $eff.PersistKt
        $State.KtTimestamp = $now.ToString('o')
    } elseif ($null -ne $eff.PersistKt) {
        $State.Kt = $eff.PersistKt          # keep a decayed/held value, but not its timestamp
    } else {
        $State.Kt = $null                    # we were guessing; do not remember a guess
        $State.KtTimestamp = $null
    }
    Save-State $State

} finally {
    Close-MonitorReadings $readings
    Save-Log
}
