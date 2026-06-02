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

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true

if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testresults.xml'
}

Invoke-Pester -Configuration $config
