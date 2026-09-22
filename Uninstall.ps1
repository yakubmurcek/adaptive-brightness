<#
.SYNOPSIS
  Removes the scheduled task. Leaves your monitor at its current brightness.

.EXAMPLE
  .\Uninstall.ps1
  Removes the task but keeps config.json.

.EXAMPLE
  .\Uninstall.ps1 -RemoveConfig
  Also deletes config.json, state.json and the log.
#>
[CmdletBinding()]
param(
    [string[]]$TaskName = @('Adaptive Brightness', 'Sun Brightness'),
    [switch]$RemoveConfig
)

$found = $false
foreach ($name in $TaskName) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Host "Removed scheduled task '$name'." -ForegroundColor Green
        $found = $true
    }
}
if (-not $found) {
    Write-Host "No matching scheduled task found." -ForegroundColor Yellow
}

if ($RemoveConfig) {
    foreach ($f in 'config.json', 'state.json', 'brightness.log', 'brightness.log.1') {
        $p = Join-Path $PSScriptRoot $f
        if (Test-Path $p) { Remove-Item $p -Force; Write-Host "Deleted $f" -ForegroundColor Green }
    }
} else {
    Write-Host "config.json and state.json kept. Use -RemoveConfig to delete them too." -ForegroundColor DarkGray
}
