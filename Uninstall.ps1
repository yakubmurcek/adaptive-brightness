<#
.SYNOPSIS
  Removes the scheduled task. Leaves your monitor at its current brightness.
#>
[CmdletBinding()]
param([string]$TaskName = 'Sun Brightness')

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
} else {
    Write-Host "No scheduled task named '$TaskName' found." -ForegroundColor Yellow
}
