<#
.SYNOPSIS
  One-time setup: writes config.json and registers the "Adaptive Brightness" scheduled task.

.EXAMPLE
  .\Install.ps1
  Detects your approximate location from your IP and uses the defaults.

.EXAMPLE
  .\Install.ps1 -Latitude 40.7128 -Longitude -74.0060 -NightBrightness 15
#>
[CmdletBinding()]
param(
    [double]$Latitude,
    [double]$Longitude,

    [int]   $DayBrightness        = 100,
    [int]   $OvercastBrightness   = 55,
    [int]   $NightBrightness      = 9,
    [int]   $MinBrightness        = 5,
    [int]   $MaxBrightness        = 100,

    [double]$RampLowDeg           = -12.0,
    [double]$RampHighDeg          = 14.0,

    [double]$KtLow                = 0.25,
    [double]$KtHigh               = 0.95,
    [double]$KtFallback           = 0.50,
    [double]$KtTauMinutes         = 30.0,
    [double]$KtMaxAgeMinutes      = 180.0,

    [double]$MaxRatePerMinute     = 3.0,
    [double]$DeadbandPct          = 4.0,
    [int]   $GlideStepMs          = 25,
    [double]$OverrideTolerancePct = 6.0,
    [int]   $OverrideMinutes      = 120,
    [double]$MaxCatchUpMinutes    = 10.0,
    [int]   $TimeoutSec           = 10,

    # pacing
    [int]   $TickSeconds            = 20,
    [int]   $IdleTickSeconds        = 180,
    [int]   $NightTickSeconds       = 600,
    [double]$WeatherIntervalMinutes = 10.0,
    [double]$BatteryFactor          = 3.0,
    [int]   $HeartbeatMinutes       = 30,

    # How often the scheduler checks the daemon is still alive. This is a watchdog, not
    # the tick rate: MultipleInstances IgnoreNew means it costs nothing while the daemon
    # is running, and silently restarts it if it ever isn't.
    [int]   $WatchdogMinutes      = 15,
    [string]$TaskName             = 'Adaptive Brightness'
)

$ErrorActionPreference = 'Stop'

# ---------- location ----------
if (-not $PSBoundParameters.ContainsKey('Latitude') -or -not $PSBoundParameters.ContainsKey('Longitude')) {
    # reuse an existing config's coordinates before asking the internet again
    $existing = Join-Path $PSScriptRoot 'config.json'
    $reused = $false
    if (Test-Path $existing) {
        try {
            $old = Get-Content $existing -Raw | ConvertFrom-Json
            if ($null -ne $old.Latitude -and $null -ne $old.Longitude) {
                $Latitude = [double]$old.Latitude; $Longitude = [double]$old.Longitude
                Write-Host "Reusing coordinates from your existing config.json ($Latitude, $Longitude)" -ForegroundColor Green
                $reused = $true
            }
        } catch { }
    }
    if (-not $reused) {
        Write-Host "No coordinates given - looking up your approximate location by IP..." -ForegroundColor Cyan
        try {
            $geo = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,city,country,lat,lon' -TimeoutSec 10
            if ($geo.status -ne 'success') { throw "lookup returned '$($geo.status)'" }
            $Latitude  = [double]$geo.lat
            $Longitude = [double]$geo.lon
            Write-Host "  Detected: $($geo.city), $($geo.country)  ($Latitude, $Longitude)" -ForegroundColor Green
            Write-Host "  Wrong? Re-run with -Latitude and -Longitude." -ForegroundColor DarkGray
        } catch {
            throw "Could not detect location ($_). Re-run with -Latitude and -Longitude."
        }
    }
}

# ---------- config ----------
$config = [ordered]@{
    Latitude             = $Latitude
    Longitude            = $Longitude
    DayBrightness        = $DayBrightness
    OvercastBrightness   = $OvercastBrightness
    NightBrightness      = $NightBrightness
    MinBrightness        = $MinBrightness
    MaxBrightness        = $MaxBrightness
    RampLowDeg           = $RampLowDeg
    RampHighDeg          = $RampHighDeg
    KtLow                = $KtLow
    KtHigh               = $KtHigh
    KtFallback           = $KtFallback
    KtTauMinutes         = $KtTauMinutes
    KtMaxAgeMinutes      = $KtMaxAgeMinutes
    MaxRatePerMinute     = $MaxRatePerMinute
    DeadbandPct          = $DeadbandPct
    GlideStepMs          = $GlideStepMs
    OverrideTolerancePct = $OverrideTolerancePct
    OverrideMinutes      = $OverrideMinutes
    MaxCatchUpMinutes    = $MaxCatchUpMinutes
    TickSeconds            = $TickSeconds
    IdleTickSeconds        = $IdleTickSeconds
    NightTickSeconds       = $NightTickSeconds
    WeatherIntervalMinutes = $WeatherIntervalMinutes
    BatteryFactor          = $BatteryFactor
    HeartbeatMinutes       = $HeartbeatMinutes
    TimeoutSec           = $TimeoutSec
}
$configPath = Join-Path $PSScriptRoot 'config.json'
$config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
Write-Host "Wrote $configPath" -ForegroundColor Green

# ---------- retire the old sun-only task, if this is an upgrade ----------
foreach ($old in @('Sun Brightness')) {
    if (Get-ScheduledTask -TaskName $old -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $old -Confirm:$false
        Write-Host "Removed the older '$old' task (it only tracked the sun, not the sky)." -ForegroundColor Yellow
    }
}

# ---------- scheduled task ----------
$script = Join-Path $PSScriptRoot 'Set-AdaptiveBrightness.ps1'

# prefer PowerShell 7 when it is installed; fall back to Windows PowerShell
$exe = 'powershell.exe'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
if ($null -ne $pwsh) { $exe = $pwsh.Source }

# -Loop  : one resident process that sleeps between ticks, instead of the scheduler
#          starting a whole new PowerShell every couple of minutes. Starting a process
#          costs about a second of CPU - loading the runtime, parsing the scripts,
#          JIT-compiling the DDC interop - to do a few milliseconds of real work, and it
#          used to pay that some 720 times a day. Paying it once per boot is what buys
#          the much faster tick rate at a fraction of the power.
# -Quiet  : the script writes its own UTF-8 log; no shell redirection needed
$action = New-ScheduledTaskAction -Execute $exe `
    -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Loop -Quiet' -f $script)

$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # watchdog, not a tick: IgnoreNew below makes this a no-op whenever the daemon is
    # already running, so its only effect is to bring it back if it ever died
    New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $WatchdogMinutes)
)

# ExecutionTimeLimit 0 = no limit. The old task was killed after five minutes, which was
# generous for a one-shot and fatal for something meant to stay up for weeks.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

# stop any previous instance first, or IgnoreNew will keep the *old* code resident
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
    -Description "Sets monitor brightness from the sun's altitude and the measured sky (DDC/CI)" -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' (resident daemon, starts at logon)" -ForegroundColor Green
Write-Host ("  ticks every {0}s while moving, backing off to {1}s idle and {2}s at night" -f `
            $TickSeconds, $IdleTickSeconds, $NightTickSeconds) -ForegroundColor DarkGray
Write-Host ("  sky re-measured over the network every {0:N0} min" -f $WeatherIntervalMinutes) -ForegroundColor DarkGray

# ---------- first run ----------
# a visible one-shot before the daemon starts: it proves the config is usable and shows
# the reasoning, which a silent background process never would
Write-Host "`nRunning once now:" -ForegroundColor Cyan
& $script

Start-ScheduledTask -TaskName $TaskName
Write-Host "`nDaemon started, so there is no need to log out and back in." -ForegroundColor Green

Write-Host "`nDone. Useful next steps:" -ForegroundColor Cyan
Write-Host "  .\Set-AdaptiveBrightness.ps1 -Status                     what it thinks right now" -ForegroundColor DarkGray
Write-Host "  .\Set-AdaptiveBrightness.ps1 -SimulateKt 0.1 -WhatIfOnly what it would do under heavy overcast" -ForegroundColor DarkGray
Write-Host "  .\Set-AdaptiveBrightness.ps1 -Pause                      stop adjusting for now" -ForegroundColor DarkGray
