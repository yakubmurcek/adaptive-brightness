<#
  PSScriptAnalyzer configuration.

  Every exclusion below is a rule that is *wrong for this code*, not a rule this code
  failed to meet. They are listed with reasons so the next reader can judge that for
  themselves rather than taking it on trust - an analyzer config with silent exclusions is
  worth very little.
#>
@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # The scripts are console tools whose entire output contract is coloured, human-read
        # text. Write-Output would put that text on the pipeline, where callers would have to
        # filter it back out of their results.
        'PSAvoidUsingWriteHost',

        # Get-PhysicalMonitorHandles, Get-MonitorReadings and Close-MonitorReadings really do
        # act on the whole set of attached monitors. A singular name would be a lie, and
        # Windows itself names the underlying API GetPhysicalMonitorsFromHMONITOR.
        'PSUseSingularNouns',

        # MonitorEnumProc is a Win32 callback. Its signature is fixed by user32.dll, so hdc,
        # lprc and dwData must be declared whether or not this particular callback reads them.
        'PSReviewUnusedParameter',

        # A brightness controller must never hard-fail because a log line could not be
        # written, a BOM could not be sniffed, or a deliberately corrupt state file could not
        # be parsed. Those catches are empty on purpose and each carries a comment saying so;
        # the analyzer cannot see the difference between "swallowed by accident" and
        # "swallowed because the alternative is worse".
        'PSAvoidUsingEmptyCatchBlock',

        # Write-Log collides with a cmdlet shipped in some PowerShell editions. This one is a
        # script-local function that buffers lines for a single tick and is never exported,
        # so the shadowing is contained and intentional.
        'PSAvoidOverwritingBuiltInCmdlets',

        # Install/Uninstall change machine state by definition; -WhatIf on an installer that
        # already has -WhatIfOnly on the thing it installs would be noise.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
