#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
    todo.ps1 - command-line entry point for the PowerShell todo.txt CLI.

    A thin wrapper around the TodoTxt module's Invoke-Todo. It forwards all
    arguments verbatim, prints results, and propagates the exit code.

    Note: this script intentionally declares NO parameters and reads $args
    directly. That keeps PowerShell's parameter binder from swallowing
    todo.sh-style options such as -a, -P or -d (which would otherwise be
    interpreted as parameters of the script itself).

    Examples:
        ./todo.ps1 add "buy milk +groceries @store"
        ./todo.ps1 ls
        ./todo.ps1 -a do 1
        ./todo.ps1 -d ~/.todo/config ls @work
#>

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'src/TodoTxt.psd1') -Force

$todoArgs = [string[]]@($args)

try {
    Invoke-Todo -Arguments $todoArgs | ForEach-Object { Write-Output $_ }
    exit (Get-TodoExitCode)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
