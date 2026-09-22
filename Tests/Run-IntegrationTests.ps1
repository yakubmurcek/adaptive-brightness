<#
.SYNOPSIS
  End-to-end tests for Set-AdaptiveBrightness.ps1 against the real monitor.

.DESCRIPTION
  Run-Tests.ps1 covers the algorithm. This covers the plumbing the algorithm cannot see:
  DDC reads and writes, state persistence, manual-override detection, pause/resume, and
  behaviour with no network.

  This DOES change your monitor brightness while it runs. It records the level it found
  and puts it back at the end, along with any pre-existing state.json.

.EXAMPLE
  pwsh -File .\Tests\Run-IntegrationTests.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root   = Split-Path $PSScriptRoot -Parent
$Script = Join-Path $Root 'Set-AdaptiveBrightness.ps1'
$State  = Join-Path $Root 'state.json'
$Backup = Join-Path $env:TEMP 'adaptive-brightness-state.backup.json'

. (Join-Path $Root 'BrightnessCore.ps1')

$script:Passed = 0
$script:Failed = 0
function Section { param($n) Write-Host "`n$n" -ForegroundColor Cyan }
function Assert-True { param([bool]$c, [string]$n, [string]$d)
    if ($c) { $script:Passed++; Write-Host "  [pass] $n" -ForegroundColor DarkGreen }
    else    { $script:Failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red
              if ($d) { Write-Host "         $d" -ForegroundColor DarkYellow } } }

# ---------------------------------------------------------------------------
# DDC helpers (independent of the script under test, so a bug there cannot hide)
# ---------------------------------------------------------------------------
if (-not ('DDCT' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DDCT {
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

function Get-FirstMonitor {
    $handles = New-Object System.Collections.ArrayList
    $cb = [DDCT+MonitorEnumProc]{ param($hMon, $hdc, $lprc, $data) [void]$handles.Add($hMon); return $true }
    [void][DDCT]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)
    foreach ($hm in $handles) {
        $count = 0
        if (-not [DDCT]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$count)) { continue }
        if ($count -le 0) { continue }
        $mons = New-Object DDCT+PHYSICAL_MONITOR[] $count
        if (-not [DDCT]::GetPhysicalMonitorsFromHMONITOR($hm, $count, $mons)) { continue }
        foreach ($m in $mons) {
            $min = 0; $cur = 0; $max = 0
            if ([DDCT]::GetMonitorBrightness($m.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)) { return $m }
            [void][DDCT]::DestroyPhysicalMonitor($m.hPhysicalMonitor)
        }
    }
    return $null
}

function Get-Pct { param($Mon)
    $min = 0; $cur = 0; $max = 0
    [void][DDCT]::GetMonitorBrightness($Mon.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)
    if ($max -le $min) { return 0.0 }
    return (([double]$cur - $min) / ($max - $min)) * 100.0
}
function Set-Pct { param($Mon, [double]$Pct)
    $min = 0; $cur = 0; $max = 0
    [void][DDCT]::GetMonitorBrightness($Mon.hPhysicalMonitor, [ref]$min, [ref]$cur, [ref]$max)
    $raw = [int][Math]::Round($min + ($max - $min) * ($Pct / 100.0))
    [void][DDCT]::SetMonitorBrightness($Mon.hPhysicalMonitor, [uint32]$raw)
}

function Invoke-Tick {
    <#
      Runs one tick. AdvanceSeconds backdates the recorded last-run time first, which is
      how we simulate the real 2-minute spacing between scheduled ticks without waiting.

      This matters: the rate limiter budgets change per *elapsed minute*, so ticks fired
      milliseconds apart are correctly allowed to move almost nothing. Without backdating,
      an integration test can only ever observe the limiter refusing to act.
    #>
    param([string[]]$ScriptArgs = @(), [double]$AdvanceSeconds = 120)

    if ($AdvanceSeconds -gt 0 -and (Test-Path $State)) {
        try {
            $s = Get-Content $State -Raw | ConvertFrom-Json
            if ($null -ne $s.PSObject.Properties['LastRun'] -and $null -ne $s.LastRun) {
                $s.LastRun = ([datetime]::Parse($s.LastRun, [Globalization.CultureInfo]::InvariantCulture)
                             ).AddSeconds(-$AdvanceSeconds).ToString('o')
                $s | ConvertTo-Json | Set-Content -Path $State -Encoding UTF8
            }
        } catch { }   # a deliberately corrupt state file is a test case, not a failure here
    }

    $all = @('-NoProfile', '-File', $Script) + $ScriptArgs
    return (& pwsh @all 2>&1 | Out-String)
}
function Get-StateObj {
    if (-not (Test-Path $State)) { return $null }
    return (Get-Content $State -Raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------

$mon = Get-FirstMonitor
if ($null -eq $mon) {
    Write-Host "No DDC/CI-capable monitor found - cannot run integration tests." -ForegroundColor Red
    Write-Host "(Check that DDC/CI is enabled in your monitor's OSD menu.)" -ForegroundColor DarkGray
    exit 2
}

$originalPct = Get-Pct $mon
Write-Host ("Monitor found. Current brightness {0:N0}% - will be restored at the end." -f $originalPct) -ForegroundColor DarkGray
if (Test-Path $State) { Copy-Item $State $Backup -Force }

try {
    # =======================================================================
    Section 'cold start writes a sensible level and records state'
    # =======================================================================
    if (Test-Path $State) { Remove-Item $State -Force }
    Set-Pct $mon 50
    Start-Sleep -Milliseconds 400

    $out = Invoke-Tick @('-SimulateKt', '0.95')
    $s = Get-StateObj
    Assert-True ($null -ne $s) 'state.json is created on the first run'
    Assert-True ($null -ne $s.LastApplied) 'the commanded level is recorded' $out
    $pct = Get-Pct $mon
    Assert-True ([Math]::Abs($pct - $s.LastApplied) -le 3) `
        'the panel ends up where the script says it commanded' "panel $pct vs state $($s.LastApplied)"
    $coldLevel = $s.LastApplied
    Write-Host ("         cold start -> {0:N0}%" -f $coldLevel) -ForegroundColor DarkGray

    # =======================================================================
    Section 'a repeat tick with an unchanged sky does not move the panel'
    # =======================================================================
    $before = Get-Pct $mon
    $out = Invoke-Tick @('-SimulateKt', '0.95')
    $after = Get-Pct $mon
    Assert-True ([Math]::Abs($after - $before) -le 1) 'an unchanged sky produces no visible move' `
        "before $before after $after`n$out"
    Assert-True ($out -match 'deadband|already at target|holding') 'and the log says why it held' $out

    # =======================================================================
    Section 'a sky collapse walks the panel down smoothly and settles'
    # =======================================================================
    # A single tick deliberately moves very little: the EMA does not believe an instant
    # sky collapse, and the rate limiter caps what any one tick may do. The property
    # worth testing is the shape of the whole descent, not the size of the first step.
    $start = Get-Pct $mon
    $prev = $start
    $maxStep = 0.0
    $rose = $false
    $undershot = $false
    $trail = @($start)

    foreach ($i in 1..30) {
        [void](Invoke-Tick @('-SimulateKt', '0.05'))
        Start-Sleep -Milliseconds 250          # let the DDC glide finish before reading back
        $now = Get-Pct $mon
        $step = [Math]::Abs($now - $prev)
        if ($step -gt $maxStep) { $maxStep = $step }
        if ($now -gt $prev + 1.5) { $rose = $true }
        if ($now -lt 48) { $undershot = $true }
        $prev = $now
        $trail += $now
    }

    Assert-True ($prev -lt $start - 20) 'a sustained overcast sky brings the panel well down' `
        "from $start to $prev"
    Assert-True (-not $rose) 'brightness never rises while the sky is steadily overcast' `
        ("trail: " + (($trail | ForEach-Object { '{0:N0}' -f $_ }) -join ' '))
    Assert-True (-not $undershot) 'it never undershoots below the overcast floor' "reached $prev"
    Assert-True ($maxStep -le 8) 'no single tick makes a jarring jump' "largest step $maxStep"
    Assert-True ([Math]::Abs($prev - 55) -le 8) 'it settles at the configured overcast level' `
        "settled at $prev"
    Write-Host ("         {0:N0}% -> {1:N0}%, largest step {2:N0} pts" -f $start, $prev, $maxStep) -ForegroundColor DarkGray

    # =======================================================================
    Section 'manual override is detected and respected'
    # =======================================================================
    Set-Pct $mon 25                       # stand in for the user pressing the OSD buttons
    Start-Sleep -Milliseconds 400
    $out = Invoke-Tick @('-SimulateKt', '0.95')
    $s = Get-StateObj
    Assert-True ($out -match 'manual change detected') 'a hand-set level is recognised as an override' $out
    Assert-True ($null -ne $s.OverrideUntil) 'the override is recorded with an expiry'
    $pct = Get-Pct $mon
    Assert-True ([Math]::Abs($pct - 25) -le 3) 'the user-chosen level is left alone' "panel at $pct"

    $out = Invoke-Tick @('-SimulateKt', '0.95')
    $pct = Get-Pct $mon
    Assert-True ($out -match 'override active') 'later ticks keep standing down' $out
    Assert-True ([Math]::Abs($pct - 25) -le 3) 'and still do not touch the panel' "panel at $pct"

    # =======================================================================
    Section 'clearing the override resumes control, easing on from where the user left it'
    # =======================================================================
    [void](Invoke-Tick @('-ClearOverride'))
    $s = Get-StateObj
    Assert-True ($null -eq $s.OverrideUntil) 'the override is cleared'
    $before = Get-Pct $mon
    $out = Invoke-Tick @('-SimulateKt', '0.95')
    Start-Sleep -Milliseconds 250
    $after = Get-Pct $mon
    Assert-True ($after -gt $before) 'control resumes and starts climbing again' `
        "before $before after $after`n$out"
    Assert-True (($after - $before) -le 14) 'the resume is gradual, not a snap back to full' `
        "jumped $($after - $before) points"
    Write-Host ("         resumed {0:N0}% -> {1:N0}%" -f $before, $after) -ForegroundColor DarkGray

    # =======================================================================
    Section 'pause and resume'
    # =======================================================================
    [void](Invoke-Tick @('-Pause'))
    $before = Get-Pct $mon
    $out = Invoke-Tick @('-SimulateKt', '0.05')
    $after = Get-Pct $mon
    Assert-True ($out -match 'paused') 'a paused tick says so' $out
    Assert-True ([Math]::Abs($after - $before) -le 1) 'a paused tick does not touch the panel' `
        "before $before after $after"
    $s = Get-StateObj
    Assert-True ($s.Paused -eq $true) 'the pause is persisted, so it survives a reboot'

    [void](Invoke-Tick @('-Resume'))
    $s = Get-StateObj
    Assert-True ($s.Paused -eq $false) 'resume clears the pause'
    $before = Get-Pct $mon
    [void](Invoke-Tick @('-SimulateKt', '0.05'))
    $after = Get-Pct $mon
    Assert-True ([Math]::Abs($after - $before) -gt 0.5 -or [Math]::Abs($after - 55) -le 6) `
        'and control genuinely resumes' "before $before after $after"

    # =======================================================================
    Section 'no network is survivable'
    # =======================================================================
    if (Test-Path $State) { Remove-Item $State -Force }
    $out = Invoke-Tick @('-Offline')
    Assert-True ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) 'an offline run exits cleanly'
    Assert-True ($out -match 'offline mode') 'the log records that it ran without data' $out
    Assert-True ($out -match 'target') 'it still produces a target' $out
    $s = Get-StateObj
    Assert-True ($null -eq $s.Kt) 'and it refuses to persist the guess it used' "Kt = $($s.Kt)"

    # =======================================================================
    Section 'corrupt state and config are handled'
    # =======================================================================
    Set-Content -Path $State -Value '{ this is not json' -Encoding UTF8
    $out = Invoke-Tick @('-SimulateKt', '0.5')
    Assert-True ($out -match 'unreadable') 'a corrupt state.json is reported' $out
    Assert-True ($out -match 'target') 'and the tick still completes' $out
    $s = Get-StateObj
    Assert-True ($null -ne $s -and $null -ne $s.LastApplied) 'state.json is rewritten cleanly'

    # =======================================================================
    Section 'read-only modes never touch the panel'
    # =======================================================================
    $before = Get-Pct $mon
    [void](Invoke-Tick @('-Status'))
    [void](Invoke-Tick @('-SimulateKt', '0.05', '-WhatIfOnly'))
    [void](Invoke-Tick @('-SimulateKt', '1.0', '-WhatIfOnly'))
    $after = Get-Pct $mon
    Assert-True ([Math]::Abs($after - $before) -le 1) '-Status and -WhatIfOnly leave the panel alone' `
        "before $before after $after"

} finally {
    Write-Host ''
    Write-Host ("Restoring brightness to {0:N0}% and previous state..." -f $originalPct) -ForegroundColor DarkGray
    Set-Pct $mon $originalPct
    [void][DDCT]::DestroyPhysicalMonitor($mon.hPhysicalMonitor)
    if (Test-Path $Backup) { Copy-Item $Backup $State -Force; Remove-Item $Backup -Force }
    elseif (Test-Path $State) { Remove-Item $State -Force }
}

Write-Host ''
Write-Host ('=' * 60)
$total = $script:Passed + $script:Failed
if ($script:Failed -eq 0) {
    Write-Host ("ALL {0} INTEGRATION TESTS PASSED" -f $total) -ForegroundColor Green
    Write-Host ('=' * 60)
    exit 0
} else {
    Write-Host ("{0} of {1} INTEGRATION TESTS FAILED" -f $script:Failed, $total) -ForegroundColor Red
    Write-Host ('=' * 60)
    exit 1
}
