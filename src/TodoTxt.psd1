@{
    RootModule        = 'TodoTxt.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f6c1de-2a4e-4c8a-9d11-7f0a6c2e9a01'
    Author            = 'Citizen1'
    Copyright         = '(c) 2026 Citizen1. MIT License.'
    Description       = 'A PowerShell port of the todo.txt command-line interface (todo.sh), using .NET BCL types for speed.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Invoke-Todo', 'Get-TodoExitCode',
        'Read-TodoFile', 'Write-TodoFile', 'Get-TodoPrefix', 'Get-TodoPriority',
        'ConvertTo-TodoCleanInput', 'ConvertTo-TodoUppercasePriority', 'Split-TodoPrefix',
        'ConvertFrom-TodoConfig', 'New-TodoConfig', 'Initialize-TodoFiles',
        'Get-TodoEntries', 'Test-TodoMatch', 'Format-TodoDisplayLine', 'Format-TodoEntries',
        'Get-TodoPadding', 'Get-TodoColorMap', 'Remove-TodoBlankLines',
        'Add-TodoTask', 'Get-TodoTaskText', 'Get-TodoSigilWords', 'Get-TodoDate',
        'Invoke-TodoAdd', 'Invoke-TodoAddMultiple', 'Invoke-TodoAddTo', 'Invoke-TodoAppend',
        'Invoke-TodoArchive', 'Invoke-TodoDeduplicate', 'Invoke-TodoDelete', 'Invoke-TodoDeprioritize',
        'Invoke-TodoDone', 'Invoke-TodoList', 'Invoke-TodoListAll', 'Invoke-TodoListPriority',
        'Invoke-TodoListAddons', 'Invoke-TodoMove', 'Invoke-TodoPrioritize', 'Invoke-TodoReplaceOrPrepend',
        'Invoke-TodoReport', 'Invoke-TodoAction', 'ConvertFrom-TodoArgument',
        'Get-TodoUsage', 'Get-TodoShortHelp', 'Get-TodoHelp', 'Get-TodoVersion'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('todo', 'todo.txt', 'cli', 'gtd', 'tasks', 'productivity')
            LicenseUri = 'https://github.com/citizen-123/todo.txt-powershell/blob/main/LICENSE'
            ProjectUri = 'https://github.com/citizen-123/todo.txt-powershell'
        }
    }
}
