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
    [double]$ResyncAfterMinutes,     # unwatched this long, a changed panel is a wake, not a touch

    # pacing (daemon mode)
    [int]   $TickSeconds,            # gap between ticks while something is moving
    [int]   $IdleTickSeconds,        # gap once the panel has settled
    [int]   $NightTickSeconds,       # gap once the sun is below the ramp entirely
    [double]$WeatherIntervalMinutes, # how often the sky is re-measured over the network
    [double]$BatteryFactor,          # multiply every gap by this when on battery
    [int]   $HeartbeatMinutes,       # log an uneventful tick at least this often

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
    [switch]$Loop,                   # stay resident and tick on a timer (the cheap way)
    [switch]$Quiet                   # no console output (the scheduled task uses this)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSBoundParameters is per-*function*, so inside any function below it would describe that
# function's own parameters and know nothing about how the script was invoked. Capture the
# script's binding here, at script scope, while it still means what we want.
$script:ScriptArgs = $PSBoundParameters

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
    # the level rides along so an uneventful daemon tick can drop its own routine chatter
    # at flush time while still keeping anything that acted or went wrong
    [void]$script:LogLines.Add([pscustomobject]@{ Level = $Level; Line = $line })
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
    <#
      Writes this tick's lines and empties the buffer, so a resident daemon does not
      re-append its whole history every time round.

      -DropRoutine discards plain 'info' lines. At a 20-second tick an unfiltered log
      would be thousands of identical "holding at 84%" entries a day: megabytes of disk
      writes that are themselves part of the power cost, and that bury the handful of
      lines actually worth reading. Anything that acted, warned or failed is always kept,
      and the heartbeat guarantees the log still proves the daemon is alive.
    #>
    param([switch]$DropRoutine)

    if ($script:LogLines.Count -eq 0) { return }

    $entries = @($script:LogLines)
    $script:LogLines.Clear()
    if ($DropRoutine) { $entries = @($entries | Where-Object { $_.Level -ne 'info' }) }
    if ($entries.Count -eq 0) { return }
    $lines = @($entries | ForEach-Object { $_.Line })

    try {
        if (Test-Path $LogPath) {
            # A log written by the old script carries a UTF-16 BOM. Appending UTF-8 to it
            # produces a file that is neither, and that no tool can read straight through,
            # so retire it once and start clean rather than corrupting it further.
            try {
                $fs = [System.IO.File]::OpenRead($LogPath)
                try {
                    $bom = New-Object byte[] 2
                    $read = $fs.Read($bom, 0, 2)
                } finally { $fs.Dispose() }
                if ($read -eq 2 -and (($bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) -or
                                      ($bom[0] -eq 0xFE -and $bom[1] -eq 0xFF))) {
                    Move-Item $LogPath "$LogPath.utf16.old" -Force
                }
            } catch { }

            # keep the log from growing without bound
            if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
                Move-Item $LogPath "$LogPath.1" -Force
            }
        }
        # UTF8 explicitly: PowerShell's ">>" redirection writes UTF-16, which made the
        # old log unreadable in anything but a Windows editor
        Add-Content -Path $LogPath -Value $lines -Encoding UTF8
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
    ResyncAfterMinutes   = 45.0
    TickSeconds          = 20
    IdleTickSeconds      = 180
    NightTickSeconds     = 600
    WeatherIntervalMinutes = 10.0
    BatteryFactor        = 3.0
    HeartbeatMinutes     = 30
    TimeoutSec           = 10
}

function Read-Config {
    <#
      Defaults, overlaid with config.json, overlaid with anything passed on the command
      line. A function rather than a straight-line block so the daemon can re-read the file
      after you edit it: the README promises changes take effect on the next tick without a
      reinstall, and a process that lives for weeks would quietly have broken that promise.
    #>
    $c = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $c[$k] = $Defaults[$k] }

    if (Test-Path $ConfigPath) {
        try {
            $fileCfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            foreach ($k in @($c.Keys)) {
                if ($null -ne $fileCfg.PSObject.Properties[$k] -and $null -ne $fileCfg.$k) {
                    $c[$k] = $fileCfg.$k
                }
            }
        } catch {
            Write-Log "config.json is unreadable ($($_.Exception.Message)); using defaults" 'warn'
        }
    }

    # explicit parameters beat the file
    foreach ($k in @($c.Keys)) {
        if ($script:ScriptArgs.ContainsKey($k)) { $c[$k] = $script:ScriptArgs[$k] }
    }

    # guard against a config that would invert or collapse the model
    if ($c.MinBrightness -gt $c.MaxBrightness) {
        Write-Log "MinBrightness > MaxBrightness; swapping them" 'warn'
        $t = $c.MinBrightness; $c.MinBrightness = $c.MaxBrightness; $c.MaxBrightness = $t
    }
    if ($c.KtLow -ge $c.KtHigh) {
        Write-Log "KtLow >= KtHigh; falling back to 0.25 / 0.95" 'warn'
        $c.KtLow = 0.25; $c.KtHigh = 0.95
    }
    # an ordinary night tick on battery must never look like "we were away", or every real
    # button press at night would be written off as a monitor waking up
    $longestTick = [double]$c.NightTickSeconds * [Math]::Max(1.0, [double]$c.BatteryFactor)
    if ($c.ResyncAfterMinutes * 60.0 -le $longestTick) {
        $c.ResyncAfterMinutes = [Math]::Ceiling($longestTick / 60.0) + 15.0
        Write-Log ("ResyncAfterMinutes is not longer than the slowest tick; raised to {0}" -f `
                   $c.ResyncAfterMinutes) 'warn'
    }
    return $c
}

function Get-ConfigStamp {
    # cheap enough to call every tick; re-parsing the JSON is not, so only the timestamp
    # is checked and the file is re-read when it actually changed
    try { if (Test-Path $ConfigPath) { return (Get-Item $ConfigPath).LastWriteTimeUtc.Ticks } }
    catch { }
    return 0
}

$Cfg = Read-Config
$script:CfgStamp = Get-ConfigStamp

if ($null -eq $Cfg.Latitude -or $null -eq $Cfg.Longitude) {
    Write-Log "No location configured. Run Install.ps1, or pass -Latitude and -Longitude." 'error'
    Save-Log
    exit 1
}

# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

function Read-State {
    $s = [ordered]@{
        Kt = $null; KtTimestamp = $null; LastApplied = $null
        LastRun = $null; LastFetch = $null; OverrideUntil = $null; Paused = $false
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

  [StructLayout(LayoutKind.Sequential)]
  public struct SYSTEM_POWER_STATUS { public byte ACLineStatus; public byte BatteryFlag; public byte BatteryLifePercent; public byte SystemStatusFlag; public uint BatteryLifeTime; public uint BatteryFullLifeTime; }
  [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
}
'@
}

function Test-OnBattery {
    <#
      True only when we are certain we are running on battery.

      ACLineStatus is 1 on mains, 0 on battery, and 255 when the machine has no idea -
      which is what a desktop without a battery reports. Treating "unknown" as battery
      would throttle every desktop for the rest of its life, so anything other than a
      clear 0 counts as mains.
    #>
    try {
        $st = New-Object DDC+SYSTEM_POWER_STATUS
        if (-not [DDC]::GetSystemPowerStatus([ref]$st)) { return $false }
        return ($st.ACLineStatus -eq 0)
    } catch { return $false }
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

function Invoke-BrightnessTick {
    <#
      One complete decision-and-act cycle. Factored out of the top level so the daemon can
      call it on a timer without paying to start a process, JIT-compile the DDC interop and
      re-read config every single time - which is the whole reason the resident mode is
      cheaper than a fast scheduled task, not merely tidier.

      Note the parameter is $Now: PowerShell variables are case-insensitive, so the body's
      existing $now references bind to it and every tick evaluates against its own instant
      rather than one captured when the process started. That distinction does not matter
      for a one-shot run and is the entire ballgame for a process that lives for days.

      Returns a hashtable the pacer reads: Changed, WithinDeadband, SunAltitude, Stop.
    #>
    param([datetime]$Now)

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

    # computed before the fetch decision, not after it: whether we already hold a usable Kt
    # is precisely what decides if this tick may skip the network
    $ktAgeSeconds = 1e9
    $ktStamp = ConvertTo-DateTimeOrNull $State.KtTimestamp
    if ($null -ne $ktStamp) { $ktAgeSeconds = [Math]::Max(0.0, ($now - $ktStamp).TotalSeconds) }

    if ($script:ScriptArgs.ContainsKey('SimulateKt')) {
        $sampleKt = Get-Clamped -Value $SimulateKt -Min 0.0 -Max 1.0
        $ghiText  = "simulated Kt $([Math]::Round($sampleKt,2))"
        $sunTooLow = $false
    } elseif ($Offline) {
        $ghiText = 'offline mode'
    } elseif ($sunTooLow) {
        $ghiText = 'sun too low to measure'
    } else {
        # Only the *sky* term needs the network, and Open-Meteo refreshes it about every 15
        # minutes. The sun term - which is what actually moves the panel from one tick to the
        # next - is pure local geometry and is recomputed above for free. So a fast tick loses
        # nothing by reusing a recent sample, and gains not making 180 identical HTTP calls an
        # hour: the single largest saving in this whole change, in power and in politeness to
        # a free service.
        $fetchAge = $null
        $lastFetch = ConvertTo-DateTimeOrNull $State.LastFetch
        if ($null -ne $lastFetch) { $fetchAge = ($now - $lastFetch).TotalSeconds }

        $haveKt = ($null -ne $State.Kt -and $ktAgeSeconds -le ($Cfg.KtMaxAgeMinutes * 60.0))
        $shouldFetch = Test-ShouldFetchWeather -LastFetchAgeSeconds $fetchAge -HaveUsableKt $haveKt `
                           -IntervalSeconds ($Cfg.WeatherIntervalMinutes * 60.0)

        if (-not $shouldFetch) {
            $ghiText = 'sky not re-measured this tick'
        } else {
        $State.LastFetch = $now.ToString('o')
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
    }

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
        $readings = @(Get-MonitorReadings)
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
            return @{ Changed = $false; WithinDeadband = $true; SunAltitude = $alt; Stop = $true }
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
            # settled-looking on purpose: a paused daemon should coast at the idle pace rather
            # than keep checking at full speed for a state only the user can end
            return @{ Changed = $false; WithinDeadband = $true; SunAltitude = $alt; Stop = $false }
        }

        # ---- an override already in force ----
        $overrideUntil = ConvertTo-DateTimeOrNull $State.OverrideUntil
        if ($null -ne $overrideUntil -and $now -lt $overrideUntil) {
            # keep watching the panel while standing down: a second touch restarts the clock
            # from *that* touch, and the level we ease on from later is the one the user
            # actually left, not the one they started from
            $again = Test-ManualOverride -LastApplied $lastApplied -ObservedBrightness $observedPct `
                                         -TolerancePct $Cfg.OverrideTolerancePct `
                                         -SecondsSinceLastLook $deltaSeconds `
                                         -ResyncAfterSeconds ($Cfg.ResyncAfterMinutes * 60.0)
            if ($again.Resync) {
                # the panel power-cycled while we were away; follow it, but a wake is not a
                # touch, so the override keeps its original deadline
                $State.LastApplied = $observedPct
                Write-Log ("panel moved while unwatched ({0}); adopting it" -f $again.Reason)
            }
            if ($again.IsOverridden) {
                $overrideUntil = $now.AddMinutes($Cfg.OverrideMinutes)
                $State.OverrideUntil = $overrideUntil.ToString('o')
                $State.LastApplied = $observedPct
                Write-Log ("manual change again ({0}); override restarted" -f $again.Reason) 'warn'
            }
            $mins = [int]([Math]::Ceiling(($overrideUntil - $now).TotalMinutes))
            Write-Log "manual override active for another $mins min; not adjusting" 'warn'
            Save-StandDown
            return @{ Changed = $false; WithinDeadband = $true; SunAltitude = $alt; Stop = $false }
        }
        if ($null -ne $overrideUntil -and $now -ge $overrideUntil) {
            Write-Log "manual override expired; resuming automatic control"
            $State.OverrideUntil = $null
        }

        # ---- did the user touch the monitor ----
        if (-not $WhatIfOnly) {
            $ov = Test-ManualOverride -LastApplied $lastApplied -ObservedBrightness $observedPct `
                                      -TolerancePct $Cfg.OverrideTolerancePct `
                                      -SecondsSinceLastLook $deltaSeconds `
                                      -ResyncAfterSeconds ($Cfg.ResyncAfterMinutes * 60.0)
            if ($ov.Resync) {
                # probably the monitor's own power cycle, not a person: take the panel as the
                # new baseline and ease from it. Zeroing the budget matters - the capped
                # catch-up allowance would otherwise spend itself in one visible jump.
                Write-Log ("panel moved while unwatched ({0}); easing on from there" -f $ov.Reason) 'act'
                $lastApplied = [double]$observedPct
                $actuationDelta = 0.0
            }
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
                return @{ Changed = $false; WithinDeadband = $true; SunAltitude = $alt; Stop = $false }
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
            return @{ Changed = $false; WithinDeadband = [bool]$decision.Settled
                      SunAltitude = $alt; Stop = $true }
        }

        if ($readings.Count -eq 0) {
            # no panel to talk to - the display is probably asleep or on a laptop's internal
            # eDP. Report it as settled so we stop spinning the DDC bus every few seconds
            # waiting for hardware that may not come back until the user returns.
            Write-Log "no DDC/CI capable monitor found; nothing to set" 'warn'
            return @{ Changed = $false; WithinDeadband = $true; SunAltitude = $alt; Stop = $false }
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

        return @{ Changed = [bool]$decision.Changed; WithinDeadband = [bool]$decision.Settled
                  SunAltitude = $alt; Stop = $false }

    } finally {
        # handles must be released every tick, including the ones that returned early - a
        # daemon that leaked one physical monitor handle per tick would exhaust the display
        # driver within a day, which a process that exited immediately never had to care about
        Close-MonitorReadings $readings
    }
}

# ---------------------------------------------------------------------------
# drive it: once, or resident
# ---------------------------------------------------------------------------

if (-not $Loop) {
    $result = Invoke-BrightnessTick -Now $now
    Save-Log
    exit 0
}

# ---- daemon ----
#
# One process, sleeping between ticks, instead of the scheduler starting a fresh
# PowerShell every couple of minutes. The saving is not subtle: a cold start has to load
# the runtime, parse three files and JIT-compile the DDC interop before it can read a
# single value - on the order of a second of CPU - and it paid that ~720 times a day to
# do a few milliseconds of actual work. Here it is paid once, per boot.
#
# What is left over is genuinely cheap: a sleeping thread costs nothing measurable, so
# the tick can be far *faster* than the old schedule while using a small fraction of the
# power. Responsiveness went up and the bill went down, which is the rare case where the
# two are not in tension.

Write-Log ("daemon started (pid {0}): tick {1}s, idle {2}s, night {3}s, sky every {4:N0} min" -f `
           $PID, $Cfg.TickSeconds, $Cfg.IdleTickSeconds, $Cfg.NightTickSeconds,
           $Cfg.WeatherIntervalMinutes) 'act'
Save-Log

$sleepSeconds  = [double]$Cfg.TickSeconds
$lastHeartbeat = Get-Date

while ($true) {
    $tickNow = Get-Date

    # pick up an edited config.json without a reinstall, as the one-shot mode always did
    $stamp = Get-ConfigStamp
    if ($stamp -ne $script:CfgStamp) {
        $script:CfgStamp = $stamp
        $Cfg = Read-Config
        Write-Log 'config.json changed; reloaded' 'act'
    }

    try {
        $result = Invoke-BrightnessTick -Now $tickNow
    } catch {
        # A daemon that dies on one bad tick is worse than no daemon, because the user has
        # no reason to suspect their brightness stopped tracking. Log it, back off to the
        # idle pace, and try again - transient DDC and network failures are exactly the
        # kind of thing that fixes itself.
        Write-Log "tick failed: $($_.Exception.Message)" 'error'
        $result = @{ Changed = $false; WithinDeadband = $true
                     SunAltitude = 0.0; Stop = $false }
    }

    if ($result.Stop) {
        Save-Log
        break
    }

    $onBattery = Test-OnBattery
    $sleepSeconds = Get-NextTickSeconds -Changed $result.Changed `
                        -WithinDeadband $result.WithinDeadband `
                        -SunAltitudeDeg $result.SunAltitude `
                        -PreviousSeconds $sleepSeconds `
                        -FastSeconds $Cfg.TickSeconds -IdleSeconds $Cfg.IdleTickSeconds `
                        -NightSeconds $Cfg.NightTickSeconds -RampLowDeg $Cfg.RampLowDeg `
                        -BatteryFactor $Cfg.BatteryFactor -OnBattery $onBattery

    # An uneventful tick writes nothing, so the log stays readable and the disk stays
    # asleep; the heartbeat is what still proves the daemon is alive and tracking.
    $heartbeatDue = (($tickNow - $lastHeartbeat).TotalMinutes -ge $Cfg.HeartbeatMinutes)
    if ($heartbeatDue) { $lastHeartbeat = $tickNow }
    Save-Log -DropRoutine:(-not $heartbeatDue)

    Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Round($sleepSeconds)))
}
