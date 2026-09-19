<#
.SYNOPSIS
  One-time setup: writes config.json and registers the "Sun Brightness" scheduled task.

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
    [int]   $DayBrightness   = 100,
    [int]   $NightBrightness = 9,
    [double]$RampLowDeg      = -12.0,
    [double]$RampHighDeg     = 10.0,
    [int]   $GlideStepMs     = 25,
    [int]   $IntervalMinutes = 2,
    [string]$TaskName        = 'Sun Brightness'
)

$ErrorActionPreference = 'Stop'

# ---------- location ----------
if (-not $PSBoundParameters.ContainsKey('Latitude') -or -not $PSBoundParameters.ContainsKey('Longitude')) {
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

# ---------- config ----------
$config = [ordered]@{
    Latitude        = $Latitude
    Longitude       = $Longitude
    DayBrightness   = $DayBrightness
    NightBrightness = $NightBrightness
    RampLowDeg      = $RampLowDeg
    RampHighDeg     = $RampHighDeg
    GlideStepMs     = $GlideStepMs
}
$configPath = Join-Path $PSScriptRoot 'config.json'
$config | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
Write-Host "Wrote $configPath" -ForegroundColor Green

# ---------- scheduled task ----------
$script = Join-Path $PSScriptRoot 'Set-SunBrightness.ps1'
$log    = Join-Path $PSScriptRoot 'brightness.log'
$cmd    = "& '$script' *>> '$log'"

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"$cmd`""

$triggers = @(
    New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings `
    -Description "Adjusts monitor brightness to the sun's altitude (DDC/CI)" -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' (every $IntervalMinutes min + at logon)" -ForegroundColor Green

# ---------- first run ----------
Write-Host "`nRunning once now:" -ForegroundColor Cyan
& $script
