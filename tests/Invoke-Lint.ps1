#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
    Runs PSScriptAnalyzer over the repository using PSScriptAnalyzerSettings.psd1.

    Usage:
        pwsh -File tests/Invoke-Lint.ps1            # analyze, exit 1 on any finding
        pwsh -File tests/Invoke-Lint.ps1 -Install   # install the analyzer first

    Note: PSScriptAnalyzer must be available (Install-Module PSScriptAnalyzer),
    which requires PowerShell Gallery access; CI installs it before invoking this.
#>
[CmdletBinding()]
param(
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

if ($Install -and -not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck
}
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    throw "PSScriptAnalyzer is not installed. Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force (or run with -Install)."
}
Import-Module PSScriptAnalyzer

$settings = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$results = Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Settings $settings

if ($results) {
    $results | Sort-Object ScriptName, Line | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String | Write-Host
    Write-Host "PSScriptAnalyzer found $($results.Count) issue(s)." -ForegroundColor Red
    exit 1
}

Write-Host 'PSScriptAnalyzer: no issues found.' -ForegroundColor Green
