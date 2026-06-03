#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
    Runs the Pester suite for the todo.txt PowerShell CLI.

    Usage:
        pwsh -File tests/Invoke-Tests.ps1            # run all tests
        pwsh -File tests/Invoke-Tests.ps1 -CI        # CI mode: also emit NUnit XML
#>
[CmdletBinding()]
param(
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge ([version]'5.0.0'))) {
    throw "Pester 5+ is required. Install with: Install-Module Pester -Scope CurrentUser -Force"
}

Import-Module Pester -MinimumVersion 5.0.0

$repoRoot = Split-Path -Parent $PSScriptRoot

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = 'Detailed'

if ($CI) {
    # PassThru (not Run.Exit) so we can print coverage and set the exit code after.
    $config.Run.PassThru = $true
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testresults.xml'

    # Code coverage over the module + installer.
    $config.CodeCoverage.Enabled = $true
    $config.CodeCoverage.Path = @(
        (Join-Path $repoRoot 'src' 'TodoTxt.psm1'),
        (Join-Path $repoRoot 'install.ps1')
    )
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
    $config.CodeCoverage.OutputPath = Join-Path $PSScriptRoot 'coverage.xml'

    $result = Invoke-Pester -Configuration $config
    if ($result.CodeCoverage) {
        $cov = $result.CodeCoverage
        $analyzed = $cov.CommandsAnalyzedCount
        $covered = $cov.CommandsExecutedCount
        $pct = if ($analyzed -gt 0) { [math]::Round(100.0 * $covered / $analyzed, 1) } else { 0 }
        Write-Host "Code coverage: $pct% ($covered / $analyzed commands)" -ForegroundColor Cyan
    }
    exit $result.FailedCount
}

$config.Run.Exit = $true
Invoke-Pester -Configuration $config
