@{
    # PSScriptAnalyzer configuration for the todo.txt PowerShell CLI.
    # Runs the default rules at Error/Warning severity, minus a small set that
    # conflict with this project's deliberate, pre-existing design.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The CLI faithfully ports todo.sh verb names (Split-TodoPrefix,
        # Split-TodoMarker). 'Split' is not an "approved" PowerShell verb, but
        # these are part of the established, exported API.
        'PSUseApprovedVerbs',

        # Several exported helpers describe collections (Get-TodoEntries,
        # Get-TodoSigilWords, Initialize-TodoFiles). Renaming them would break the
        # public surface for no functional gain.
        'PSUseSingularNouns',

        # install.ps1 is an interactive installer whose Write-Host calls are
        # intentional user-facing output (not data returned down a pipeline).
        'PSAvoidUsingWriteHost',

        # Many pure helpers use state-changing verbs (New-TodoConfig, Set-TodoTag,
        # Add-TodoDateInterval) but only compute and return values; they have no
        # external side effects to gate behind -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions',

        # Argument-completer and event scriptblocks must declare the full
        # positional parameter list mandated by their API even when only some are
        # used, which this rule misreports as unused.
        'PSReviewUnusedParameter'
    )
}
