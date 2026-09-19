<#
.SYNOPSIS
  Sets external monitor brightness (DDC/CI) from the sun's altitude.
  Sun high -> DayBrightness (100). Sun below horizon -> NightBrightness (9).
  Smoothstep ramp across twilight so it never jumps.

  Latitude/Longitude come from config.json next to this script unless passed
  explicitly. Run Install.ps1 once to create it.
#>
[CmdletBinding()]
param(
    [double]$Latitude,                    # decimal degrees, north positive
    [double]$Longitude,                   # decimal degrees, east positive
    [int]   $DayBrightness   = 100,
    [int]   $NightBrightness = 9,
    [double]$RampLowDeg      = -12.0,      # sun altitude at which night level is reached
    [double]$RampHighDeg     = 10.0,       # sun altitude at which day level is reached
    [datetime]$TestTime,                  # preview another moment
    [int]   $GlideStepMs     = 25,    # ms between 1-point steps when fading to the target
    [switch]$WhatIfOnly
)

# ---------- settings: explicit parameters win, then config.json, then defaults ----------
$configPath = Join-Path $PSScriptRoot 'config.json'
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    foreach ($key in 'Latitude','Longitude','DayBrightness','NightBrightness','RampLowDeg','RampHighDeg','GlideStepMs') {
        if (-not $PSBoundParameters.ContainsKey($key) -and $null -ne $cfg.$key) {
            Set-Variable -Name $key -Value $cfg.$key
        }
    }
}

if (-not $Latitude -and -not $Longitude) {
    throw "No location set. Run Install.ps1 to create config.json, or pass -Latitude and -Longitude."
}

function Get-SunAltitude {
    param([double]$Lat, [double]$Lon, [datetime]$When)

    $utc = $When.ToUniversalTime()
    $jd  = [double]$utc.ToOADate() + 2415018.5
    $t   = ($jd - 2451545.0) / 36525.0
    $rad = [Math]::PI / 180.0

    $L0 = (280.46646 + $t * (36000.76983 + $t * 0.0003032)) % 360.0
    if ($L0 -lt 0) { $L0 += 360.0 }
    $M = 357.52911 + $t * (35999.05029 - 0.0001537 * $t)
    $e = 0.016708634 - $t * (0.000042037 + 0.0000001267 * $t)

    $C = [Math]::Sin($M * $rad) * (1.914602 - $t * (0.004817 + 0.000014 * $t)) + [Math]::Sin(2 * $M * $rad) * (0.019993 - 0.000101 * $t) + [Math]::Sin(3 * $M * $rad) * 0.000289

    $trueLong = $L0 + $C
    $omega    = 125.04 - 1934.136 * $t
    $lambda   = $trueLong - 0.00569 - 0.00478 * [Math]::Sin($omega * $rad)

    $eps0 = 23.0 + (26.0 + (21.448 - $t * (46.815 + $t * (0.00059 - $t * 0.001813))) / 60.0) / 60.0
    $eps  = $eps0 + 0.00256 * [Math]::Cos($omega * $rad)
    $decl = [Math]::Asin([Math]::Sin($eps * $rad) * [Math]::Sin($lambda * $rad)) / $rad

    $y  = [Math]::Tan($eps / 2 * $rad) * [Math]::Tan($eps / 2 * $rad)
    $eq = 4 * (($y * [Math]::Sin(2 * $L0 * $rad) - 2 * $e * [Math]::Sin($M * $rad) + 4 * $e * $y * [Math]::Sin($M * $rad) * [Math]::Cos(2 * $L0 * $rad) - 0.5 * $y * $y * [Math]::Sin(4 * $L0 * $rad) - 1.25 * $e * $e * [Math]::Sin(2 * $M * $rad)) / $rad)

    $minutesUtc = $utc.Hour * 60.0 + $utc.Minute + $utc.Second / 60.0
    $trueSolar  = ($minutesUtc + $eq + 4.0 * $Lon) % 1440.0
    if ($trueSolar -lt 0) { $trueSolar += 1440.0 }
    $ha = $trueSolar / 4.0
    if ($ha -lt 0) { $ha += 180.0 } else { $ha -= 180.0 }

    $cosZ = [Math]::Sin($Lat * $rad) * [Math]::Sin($decl * $rad) + [Math]::Cos($Lat * $rad) * [Math]::Cos($decl * $rad) * [Math]::Cos($ha * $rad)
    $cosZ = [Math]::Max(-1.0, [Math]::Min(1.0, $cosZ))
    return 90.0 - ([Math]::Acos($cosZ) / $rad)
}

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

function Set-AllMonitorBrightness {
    param([int]$Percent, [int]$GlideStepMs = 25)

    $handles = New-Object System.Collections.ArrayList
    $cb = [DDC+MonitorEnumProc]{ param($hMon, $hdc, $lprc, $data) [void]$handles.Add($hMon); return $true }
    [void][DDC]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)

    foreach ($hm in $handles) {
        $count = 0
        if (-not [DDC]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$count)) { continue }
        $mons = New-Object DDC+PHYSICAL_MONITOR[] $count
        if (-not [DDC]::GetPhysicalMonitorsFromHMONITOR($hm, $count, $mons)) { continue }

        foreach ($m in $mons) {
            $name = [String]::new($m.szDescription).Trim([char]0)
            $min = 0; $cur = 0; $max = 0
            if ([DDC]::GetMonitorBrightness($m.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)) {
                # map the 0-100 request onto this monitor's own range
                $target = [int][Math]::Round($min + ($max - $min) * ($Percent / 100.0))
                if ($target -ne $cur) {
                    # fade one point at a time instead of snapping
                    $step = if ($target -gt $cur) { 1 } else { -1 }
                    for ($v = $cur + $step; ; $v += $step) {
                        [void][DDC]::SetMonitorBrightness($m.hPhysicalMonitor, [uint32]$v)
                        if ($v -eq $target) { break }
                        if ($GlideStepMs -gt 0) { Start-Sleep -Milliseconds $GlideStepMs }
                    }
                }
                Write-Output "  $name : $cur -> $target (range $min-$max)"
            } else {
                Write-Output "  $name : no DDC/CI brightness support, skipped"
            }
            [void][DDC]::DestroyPhysicalMonitor($m.hPhysicalMonitor)
        }
    }
}

$now = if ($PSBoundParameters.ContainsKey('TestTime')) { $TestTime } else { Get-Date }
$alt = Get-SunAltitude -Lat $Latitude -Lon $Longitude -When $now

$f = ($alt - $RampLowDeg) / ($RampHighDeg - $RampLowDeg)
$f = [Math]::Max(0.0, [Math]::Min(1.0, $f))
# smoothstep: flattens both ends so there is no kink where the ramp meets day/night
$f = $f * $f * (3.0 - 2.0 * $f)

$level = [int][Math]::Round($NightBrightness + ($DayBrightness - $NightBrightness) * $f)

Write-Output ("[{0}] sun altitude {1,6:N2} deg -> target {2}%" -f $now.ToString('yyyy-MM-dd HH:mm'), $alt, $level)
if ($WhatIfOnly) { return }
Set-AllMonitorBrightness -Percent $level -GlideStepMs $GlideStepMs
