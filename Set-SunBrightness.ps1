<#
.SYNOPSIS
  Deprecated. Forwards to Set-AdaptiveBrightness.ps1.

.DESCRIPTION
  This was the original sun-altitude-only script. It has been replaced by
  Set-AdaptiveBrightness.ps1, which also takes the measured sky into account so that an
  overcast noon no longer gets the same brightness as a cloudless one.

  This shim exists so that a scheduled task registered by an older Install.ps1 keeps
  working until it is re-registered. Run .\Install.ps1 to upgrade the task, after which
  this file is no longer used.

  -WhatIfOnly, -TestTime, -Latitude, -Longitude, -DayBrightness, -NightBrightness,
  -RampLowDeg, -RampHighDeg and -GlideStepMs are passed through. The old -RampHighDeg
  default of 10 is NOT reapplied; the new default of 14 is used unless you pass one.
#>
[CmdletBinding()]
param(
    [double]$Latitude,
    [double]$Longitude,
    [int]   $DayBrightness,
    [int]   $NightBrightness,
    [double]$RampLowDeg,
    [double]$RampHighDeg,
    [datetime]$TestTime,
    [int]   $GlideStepMs,
    [switch]$WhatIfOnly
)

$target = Join-Path $PSScriptRoot 'Set-AdaptiveBrightness.ps1'
if (-not (Test-Path $target)) {
    throw "Set-AdaptiveBrightness.ps1 is missing next to this script."
}

Write-Warning "Set-SunBrightness.ps1 is deprecated; forwarding to Set-AdaptiveBrightness.ps1. Run .\Install.ps1 to update your scheduled task."

# pass through only what the caller actually specified, so the new defaults still apply
$forward = @{}
foreach ($k in $PSBoundParameters.Keys) { $forward[$k] = $PSBoundParameters[$k] }

& $target @forward
