#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester suite for the PowerShell todo.txt CLI.

    Layout:
      * "Unit:" Describe blocks exercise the pure helper functions directly.
      * "Action:" Describe blocks drive the public Invoke-Todo end-to-end against
        an isolated temporary todo directory (one per test), asserting both the
        emitted output and the resulting todo.txt / done.txt contents.

    Determinism: tests run in plain mode (no ANSI color) and mock Get-TodoDate so
    completion / creation dates are fixed.
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..' 'src' 'TodoTxt.psd1'
    Import-Module $script:ModulePath -Force

    # Plain output everywhere for stable string comparisons.
    $env:TODOTXT_PLAIN = '1'

    # New isolated todo directory for a test.
    function New-TestDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ("todotest_" + [guid]::NewGuid().ToString('N'))
        [void][System.IO.Directory]::CreateDirectory($d)
        return $d
    }

    # Run the CLI against a directory and return its emitted lines.
    function Invoke-T {
        param([string]$Dir, [string[]]$CliArgs)
        Invoke-Todo -TodoDir $Dir -Arguments $CliArgs
    }

    function Get-TodoLines { param([string]$Dir) Read-TodoFile -Path (Join-Path $Dir 'todo.txt') }
    function Get-DoneLines { param([string]$Dir) Read-TodoFile -Path (Join-Path $Dir 'done.txt') }
}

AfterAll {
    Remove-Item Env:\TODOTXT_PLAIN -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Describe 'Unit: parsing helpers' {

    It 'Get-TodoPriority extracts a priority' {
        Get-TodoPriority '(A) do something' | Should -Be 'A'
    }
    It 'Get-TodoPriority returns null when unprioritized' {
        Get-TodoPriority 'do something' | Should -BeNullOrEmpty
    }
    It 'Get-TodoPriority ignores a priority that is not at the start' {
        Get-TodoPriority 'note (A) inline' | Should -BeNullOrEmpty
    }

    It 'Get-TodoPrefix strips the extension and upper-cases' {
        Get-TodoPrefix '/some/path/todo.txt' | Should -Be 'TODO'
        Get-TodoPrefix '/x/done.txt'         | Should -Be 'DONE'
        Get-TodoPrefix 'inbox.backup.txt'    | Should -Be 'INBOX'
    }

    It 'ConvertTo-TodoCleanInput replaces CR/LF with spaces' {
        ConvertTo-TodoCleanInput "a`r`nb`nc" | Should -Be 'a  b c'
    }

    It 'ConvertTo-TodoUppercasePriority upper-cases a leading priority only' {
        ConvertTo-TodoUppercasePriority '(a) task' | Should -Be '(A) task'
        ConvertTo-TodoUppercasePriority 'plain (a)' | Should -Be 'plain (a)'
    }

    Context 'Split-TodoPrefix' {
        It 'splits priority + date + rest' {
            $s = Split-TodoPrefix '(A) 2020-01-02 buy milk'
            $s.Priority | Should -Be '(A) '
            $s.Date     | Should -Be '2020-01-02 '
            $s.Rest     | Should -Be 'buy milk'
        }
        It 'handles a bare task' {
            $s = Split-TodoPrefix 'buy milk'
            $s.Priority | Should -Be ''
            $s.Date     | Should -Be ''
            $s.Rest     | Should -Be 'buy milk'
        }
        It 'handles date without priority' {
            $s = Split-TodoPrefix '2020-01-02 buy milk'
            $s.Priority | Should -Be ''
            $s.Date     | Should -Be '2020-01-02 '
        }
    }

    It 'Get-TodoPadding returns digit width of the line count' {
        Get-TodoPadding @('a', 'b', 'c')            | Should -Be 1
        Get-TodoPadding (1..12 | ForEach-Object { "t$_" }) | Should -Be 2
        Get-TodoPadding @()                          | Should -Be 1
    }

    It 'Remove-TodoBlankLines drops empty but keeps whitespace-only lines' {
        $r = Remove-TodoBlankLines @('a', '', ' ', 'b')
        $r | Should -Be @('a', ' ', 'b')
    }
}

# ----------------------------------------------------------------------------
Describe 'Unit: Test-TodoMatch (search filtering)' {
    It 'matches a single term (case-insensitive)' {
        Test-TodoMatch '1 Buy Milk' @('milk') | Should -BeTrue
    }
    It 'requires all terms (AND)' {
        Test-TodoMatch '1 buy milk @store' @('milk', 'store') | Should -BeTrue
        Test-TodoMatch '1 buy milk'         @('milk', 'store') | Should -BeFalse
    }
    It 'excludes terms prefixed with a dash' {
        Test-TodoMatch '1 buy milk' @('-milk') | Should -BeFalse
        Test-TodoMatch '1 buy eggs' @('-milk') | Should -BeTrue
    }
    It 'returns true with no terms' {
        Test-TodoMatch '1 anything' @() | Should -BeTrue
    }
}

# ----------------------------------------------------------------------------
Describe 'Unit: Format-TodoDisplayLine' {
    BeforeAll { $cfg = New-TodoConfig -TodoDir (Join-Path ([System.IO.Path]::GetTempPath()) 'fmt') -Overrides @{ Plain = $true } }

    It 'zero-pads the number to the requested width' {
        Format-TodoDisplayLine -Config $cfg -Num 3 -Text 'task' -Width 2 | Should -Be '03 task'
        Format-TodoDisplayLine -Config $cfg -Num 12 -Text 'task' -Width 2 | Should -Be '12 task'
    }
    It 'does not pad single-width numbers' {
        Format-TodoDisplayLine -Config $cfg -Num 3 -Text 'task' -Width 1 | Should -Be '3 task'
    }
    It 'hides priority when requested' {
        $c = New-TodoConfig -TodoDir 'x' -Overrides @{ Plain = $true; HidePriority = $true }
        Format-TodoDisplayLine -Config $c -Num 1 -Text '(A) task' -Width 1 | Should -Be '1 task'
    }
    It 'hides projects and contexts when requested' {
        $c = New-TodoConfig -TodoDir 'x' -Overrides @{ Plain = $true; HideProjects = $true; HideContexts = $true }
        Format-TodoDisplayLine -Config $c -Num 1 -Text 'buy milk +groceries @store' -Width 1 | Should -Be '1 buy milk'
    }
    It 'emits ANSI color for a prioritized task in color mode' {
        $c = New-TodoConfig -TodoDir 'x' -Overrides @{ Plain = $false }
        $line = Format-TodoDisplayLine -Config $c -Num 1 -Text '(A) task' -Width 1
        $line | Should -Match ([char]27)
    }
}

# ----------------------------------------------------------------------------
Describe 'Unit: ConvertFrom-TodoConfig' {
    BeforeAll {
        $cfgDir = New-TestDir
        $cfgFile = Join-Path $cfgDir 'todo.cfg'
        @(
            '# a comment'
            'export TODO_DIR="/home/me/.todo"'
            'export TODO_FILE="$TODO_DIR/todo.txt"'
            'export TODOTXT_DATE_ON_ADD=1'
            'PRI_A=$YELLOW'
        ) | Set-Content -Path $cfgFile
    }
    It 'parses assignments with export and quotes' {
        $v = ConvertFrom-TodoConfig -Path $cfgFile
        $v['TODO_DIR'] | Should -Be '/home/me/.todo'
        $v['TODOTXT_DATE_ON_ADD'] | Should -Be '1'
    }
    It 'expands variable references' {
        $v = ConvertFrom-TodoConfig -Path $cfgFile
        $v['TODO_FILE'] | Should -Be '/home/me/.todo/todo.txt'
    }
    It 'resolves named ANSI colors to escape sequences' {
        $v = ConvertFrom-TodoConfig -Path $cfgFile
        $v['PRI_A'] | Should -Be "$([char]27)[1;33m"
    }
    It 'New-TodoConfig honors a config file via -ConfigFile' {
        $c = New-TodoConfig -ConfigFile $cfgFile
        $c.DateOnAdd | Should -BeTrue
        $c.TodoDir   | Should -Be '/home/me/.todo'
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: add / addm / addto' {
    BeforeEach { $script:d = New-TestDir }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'adds a task and reports its number' {
        $out = Invoke-T $d @('add', 'buy milk +groceries @store')
        $out[0] | Should -Be '1 buy milk +groceries @store'
        $out[1] | Should -Be 'TODO: 1 added.'
        (Get-TodoLines $d) | Should -Be @('buy milk +groceries @store')
    }
    It 'upper-cases a leading priority on add' {
        Invoke-T $d @('add', '(b) lower') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(B) lower'
    }
    It 'addm adds each line separately' {
        Invoke-T $d @('addm', "first`nsecond") | Out-Null
        (Get-TodoLines $d) | Should -Be @('first', 'second')
    }
    It 'addto appends to an arbitrary file in the todo dir' {
        Set-Content -Path (Join-Path $d 'inbox.txt') -Value @()
        Invoke-T $d @('addto', 'inbox.txt', 'captured idea') | Out-Null
        (Read-TodoFile -Path (Join-Path $d 'inbox.txt')) | Should -Be @('captured idea')
    }
    It 'addto fails for a missing destination' {
        { Invoke-T $d @('addto', 'nope.txt', 'x') } | Should -Throw '*does not exist*'
    }
    It 'add with date-on-add prepends the (mocked) current date' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-01-15' }
        Invoke-T $d @('-t', 'add', 'dated') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '2020-01-15 dated'
    }
    It 'add with date-on-add keeps the date after an existing priority' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-01-15' }
        Invoke-T $d @('-t', 'add', '(A) dated') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) 2020-01-15 dated'
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: append / prepend / replace' {
    BeforeEach {
        $script:d = New-TestDir
        Invoke-T $d @('add', '(A) 2020-01-01 write report +work') | Out-Null
    }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'append adds text with a separating space' {
        Invoke-T $d @('append', '1', 'by EOD') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) 2020-01-01 write report +work by EOD'
    }
    It 'append omits the space before a sentence delimiter' {
        Invoke-T $d @('append', '1', ', urgent') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) 2020-01-01 write report +work, urgent'
    }
    It 'prepend inserts after the priority and date' {
        Invoke-T $d @('prepend', '1', 'URGENT') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) 2020-01-01 URGENT write report +work'
    }
    It 'replace swaps the text but keeps priority and date' {
        Invoke-T $d @('replace', '1', 'new body') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) 2020-01-01 new body'
    }
    It 'replace honors a new priority supplied in the replacement' {
        Invoke-T $d @('replace', '1', '(C) new body') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(C) 2020-01-01 new body'
    }
    It 'append to a missing task throws' {
        { Invoke-T $d @('append', '9', 'x') } | Should -Throw '*No task 9*'
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: do / depri / pri' {
    BeforeEach {
        $script:d = New-TestDir
        Invoke-T $d @('-A', 'add', '(B) buy milk') | Out-Null
        Invoke-T $d @('-A', 'add', 'call mom') | Out-Null
    }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'marks a task done with the completion date and removes priority (no auto-archive)' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-02-02' }
        Invoke-T $d @('-a', 'do', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'x 2020-02-02 buy milk'
    }
    It 'auto-archives completed tasks by default' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-02-02' }
        Invoke-T $d @('-A', 'do', '1') | Out-Null
        (Get-TodoLines $d) | Should -Be @('call mom')
        (Get-DoneLines $d) | Should -Be @('x 2020-02-02 buy milk')
    }
    It 'warns and sets exit code 1 when already done' {
        Invoke-T $d @('-a', 'do', '1') | Out-Null
        Invoke-T $d @('-a', 'do', '1') 2>$null | Out-Null
        Get-TodoExitCode | Should -Be 1
    }
    It 'pri assigns a priority' {
        Invoke-T $d @('pri', '2', 'a') | Out-Null
        (Get-TodoLines $d)[1] | Should -Be '(A) call mom'
    }
    It 'pri re-prioritizes an existing priority' {
        Invoke-T $d @('pri', '1', 'C') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(C) buy milk'
    }
    It 'depri removes a priority' {
        Invoke-T $d @('depri', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'buy milk'
    }
    It 'depri on an unprioritized task sets exit code 1' {
        Invoke-T $d @('depri', '2') 2>$null | Out-Null
        Get-TodoExitCode | Should -Be 1
    }
    It 'do accepts comma- and space-separated lists' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-02-02' }
        Invoke-T $d @('-a', 'do', '1,2') | Out-Null
        (Get-TodoLines $d) | Should -Be @('x 2020-02-02 buy milk', 'x 2020-02-02 call mom')
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: del / move' {
    BeforeEach {
        $script:d = New-TestDir
        Invoke-T $d @('add', '(A) one +proj') | Out-Null
        Invoke-T $d @('add', 'two') | Out-Null
        Invoke-T $d @('add', 'three') | Out-Null
    }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'del with -f and preserve leaves a blank line' {
        Invoke-T $d @('-f', '-N', 'del', '2') | Out-Null
        (Read-TodoFile -Path (Join-Path $d 'todo.txt')) | Should -Be @('(A) one +proj', '', 'three')
    }
    It 'del with -n compacts the file' {
        Invoke-T $d @('-f', '-n', 'del', '2') | Out-Null
        (Get-TodoLines $d) | Should -Be @('(A) one +proj', 'three')
    }
    It 'del TERM removes only the term, keeping the priority' {
        Invoke-T $d @('del', '1', '+proj') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be '(A) one'
    }
    It 'del TERM not found throws and changes nothing' {
        { Invoke-T $d @('del', '1', 'missing') } | Should -Throw '*not found*'
        (Get-TodoLines $d)[0] | Should -Be '(A) one +proj'
    }
    It 'del without -f respects a declined confirmation' {
        Mock -ModuleName TodoTxt Read-Host { 'n' }
        { Invoke-T $d @('del', '2') } | Should -Throw '*No tasks were deleted*'
        (Get-TodoLines $d).Count | Should -Be 3
    }
    It 'move relocates a task to another file' {
        Set-Content -Path (Join-Path $d 'someday.txt') -Value @()
        Invoke-T $d @('-f', '-n', 'move', '2', 'someday.txt') | Out-Null
        (Get-TodoLines $d) | Should -Be @('(A) one +proj', 'three')
        (Read-TodoFile -Path (Join-Path $d 'someday.txt')) | Should -Be @('two')
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: archive / deduplicate / report' {
    BeforeEach { $script:d = New-TestDir }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'archive moves done tasks to done.txt and compacts todo.txt' {
        Set-Content -Path (Join-Path $d 'todo.txt') -Value @('x done one', 'open task', '', 'x done two')
        Invoke-T $d @('archive') | Out-Null
        (Get-TodoLines $d) | Should -Be @('open task')
        (Get-DoneLines $d) | Should -Be @('x done one', 'x done two')
    }
    It 'deduplicate removes duplicates (preserve mode leaves a blank)' {
        Set-Content -Path (Join-Path $d 'todo.txt') -Value @('a', 'b', 'a')
        $out = Invoke-T $d @('-N', 'deduplicate')
        $out | Should -Be 'TODO: 1 duplicate task(s) removed'
        (Read-TodoFile -Path (Join-Path $d 'todo.txt')) | Should -Be @('a', 'b', '')
    }
    It 'deduplicate with -n compacts duplicates away' {
        Set-Content -Path (Join-Path $d 'todo.txt') -Value @('a', 'b', 'a')
        Invoke-T $d @('-n', 'deduplicate') | Out-Null
        (Get-TodoLines $d) | Should -Be @('a', 'b')
    }
    It 'deduplicate throws when there is nothing to remove' {
        Set-Content -Path (Join-Path $d 'todo.txt') -Value @('a', 'b')
        { Invoke-T $d @('deduplicate') } | Should -Throw '*No duplicate tasks found*'
    }
    It 'report appends a timestamped count line' {
        Set-Content -Path (Join-Path $d 'todo.txt') -Value @('one', 'two')
        $out = Invoke-T $d @('report')
        ($out | Select-String '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} 2 0') | Should -Not -BeNullOrEmpty
        (Read-TodoFile -Path (Join-Path $d 'report.txt')).Count | Should -Be 1
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: list family' {
    BeforeEach {
        $script:d = New-TestDir
        Invoke-T $d @('add', '(B) buy milk +groceries @store') | Out-Null
        Invoke-T $d @('add', 'call mom @phone') | Out-Null
        Invoke-T $d @('add', '(A) finish report +work') | Out-Null
        Invoke-T $d @('add', 'plain task') | Out-Null
    }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'ls sorts by priority then text and shows footer' {
        $out = Invoke-T $d @('ls')
        $out[0] | Should -Be '3 (A) finish report +work'
        $out[1] | Should -Be '1 (B) buy milk +groceries @store'
        $out[2] | Should -Be '2 call mom @phone'
        $out[3] | Should -Be '4 plain task'
        $out[4] | Should -Be '--'
        $out[5] | Should -Be 'TODO: 4 of 4 tasks shown'
    }
    It 'ls filters by a search term' {
        $out = Invoke-T $d @('ls', 'milk')
        ($out | Where-Object { $_ -match 'buy milk' }).Count | Should -Be 1
        $out | Should -Contain 'TODO: 1 of 4 tasks shown'
    }
    It 'listpri filters by a priority range' {
        $out = Invoke-T $d @('lsp', 'A-B')
        $out[0] | Should -Be '3 (A) finish report +work'
        $out[1] | Should -Be '1 (B) buy milk +groceries @store'
        $out | Should -Contain 'TODO: 2 of 4 tasks shown'
    }
    It 'listproj lists unique projects, sorted' {
        Invoke-T $d @('lsprj') | Should -Be @('+groceries', '+work')
    }
    It 'listcon lists unique contexts, sorted' {
        Invoke-T $d @('lsc') | Should -Be @('@phone', '@store')
    }
    It 'listall numbers done tasks as 0' {
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-02-02' }
        Invoke-T $d @('-A', 'do', '4') | Out-Null   # archives "plain task"
        $out = Invoke-T $d @('lsa')
        ($out | Where-Object { $_ -match '^0 x 2020-02-02 plain task$' }).Count | Should -Be 1
    }
    It 'listfile lists *.txt files alphabetically when given no name' {
        $out = Invoke-T $d @('-p', 'lf')
        $out | Should -Contain 'todo.txt'
        $out | Should -Contain 'done.txt'
    }
    It 'numbers are zero-padded once there are 10+ lines' {
        6..13 | ForEach-Object { Invoke-T $d @('add', "filler $_") | Out-Null }
        $out = Invoke-T $d @('ls', 'milk')
        $out[0] | Should -Be '01 (B) buy milk +groceries @store'
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: options & meta commands' {
    BeforeEach { $script:d = New-TestDir }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It '-V prints version information' {
        $out = Invoke-T $d @('-V')
        ($out -join "`n") | Should -Match 'TODO.TXT Command Line Interface'
    }
    It '-h / shorthelp lists the actions' {
        $out = Invoke-T $d @('-h')
        ($out -join "`n") | Should -Match 'add\|a'
    }
    It 'no action with no default action prints usage' {
        $out = Invoke-T $d @()
        ($out -join "`n") | Should -Match 'Usage:'
    }
    It 'an unknown action throws usage' {
        { Invoke-T $d @('frobnicate') } | Should -Throw '*Usage:*'
    }
    It 'verbose 0 suppresses the add confirmation' {
        $env:TODOTXT_VERBOSE = '0'
        try {
            $out = Invoke-T $d @('add', 'quiet task')
            $out | Should -BeNullOrEmpty
        }
        finally { Remove-Item Env:\TODOTXT_VERBOSE -ErrorAction SilentlyContinue }
    }
    It 'command forwards to a built-in action' {
        Invoke-T $d @('command', 'add', 'via command') | Out-Null
        (Get-TodoLines $d) | Should -Be @('via command')
    }
    It 'a default action runs when no action is given' {
        Invoke-T $d @('add', 'a task') | Out-Null
        $out = Invoke-Todo -TodoDir $d -Arguments @() -ErrorAction SilentlyContinue 2>$null
        # Use config-provided default action.
        $cfgFile = Join-Path $d 'cfg'
        "export TODOTXT_DEFAULT_ACTION=ls" | Set-Content $cfgFile
        $out = Invoke-Todo -TodoDir $d -ConfigFile $cfgFile -Arguments @()
        ($out | Where-Object { $_ -match 'a task' }).Count | Should -Be 1
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: addon execution' {
    BeforeEach { $script:d = New-TestDir }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'runs a PowerShell add-on action for an unknown command' {
        $actions = Join-Path $d 'actions'
        [void][System.IO.Directory]::CreateDirectory($actions)
        'param($a) "addon ran: $a"' | Set-Content -Path (Join-Path $actions 'greet.ps1')
        $env:TODO_ACTIONS_DIR = $actions
        try {
            $out = Invoke-T $d @('greet', 'hello')
            $out | Should -Be 'addon ran: hello'
        }
        finally { Remove-Item Env:\TODO_ACTIONS_DIR -ErrorAction SilentlyContinue }
    }
    It 'listaddons enumerates the actions directory' {
        $actions = Join-Path $d 'actions'
        [void][System.IO.Directory]::CreateDirectory($actions)
        '1' | Set-Content -Path (Join-Path $actions 'foo.ps1')
        $env:TODO_ACTIONS_DIR = $actions
        try {
            Invoke-T $d @('listaddons') | Should -Contain 'foo.ps1'
        }
        finally { Remove-Item Env:\TODO_ACTIONS_DIR -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------------------------
Describe 'Unit: Split-TodoMarker (status markers)' {
    It 'splits a done marker' {
        $m = Split-TodoMarker 'x 2020-01-01 done'
        $m.Marker | Should -Be 'x '
        $m.Rest   | Should -Be '2020-01-01 done'
    }
    It 'splits an in-progress marker' {
        $m = Split-TodoMarker 'i (A) task started:2020-01-01'
        $m.Marker | Should -Be 'i '
        $m.Rest   | Should -Be '(A) task started:2020-01-01'
    }
    It 'leaves a bare task untouched' {
        $m = Split-TodoMarker 'plain task'
        $m.Marker | Should -Be ''
        $m.Rest   | Should -Be 'plain task'
    }
    It 'does not treat an arbitrary leading letter as a marker' {
        (Split-TodoMarker 'a quick note').Marker | Should -Be ''
    }
    It 'Get-TodoPriority sees through a marker' {
        Get-TodoPriority 'i (A) task' | Should -Be 'A'
    }
    It 'Split-TodoPrefix exposes marker, priority and date' {
        $p = Split-TodoPrefix 'i (A) 2020-01-02 task'
        $p.Marker   | Should -Be 'i '
        $p.Priority | Should -Be '(A) '
        $p.Date     | Should -Be '2020-01-02 '
        $p.Rest     | Should -Be 'task'
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: in-progress (start) + lifecycle date tags' {
    BeforeEach {
        $script:d = New-TestDir
        $env:TODOTXT_IN_PROGRESS = '1'
        $env:TODOTXT_DATE_TAGS = '1'
        Mock -ModuleName TodoTxt Get-TodoDate { '2020-01-15' }
    }
    AfterEach {
        Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TODOTXT_IN_PROGRESS, Env:\TODOTXT_DATE_TAGS -ErrorAction SilentlyContinue
    }

    It 'add appends an added: tag when date tags are on' {
        Invoke-T $d @('add', 'buy milk') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'buy milk added:2020-01-15'
    }
    It 'start prepends i and a started: tag, preserving priority' {
        Invoke-T $d @('add', '(A) write report') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'i (A) write report added:2020-01-15 started:2020-01-15'
    }
    It 'start on an already in-progress task sets exit code 1' {
        Invoke-T $d @('add', 'task') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        Invoke-T $d @('start', '1') 2>$null | Out-Null
        Get-TodoExitCode | Should -Be 1
    }
    It 'do on an in-progress task drops i + priority, keeps started, adds completed' {
        Invoke-T $d @('add', '(A) write report') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        Invoke-T $d @('-a', 'do', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'x 2020-01-15 write report added:2020-01-15 started:2020-01-15 completed:2020-01-15'
    }
    It 'pri changes priority while keeping the in-progress marker' {
        Invoke-T $d @('add', '(A) task') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        Invoke-T $d @('pri', '1', 'C') | Out-Null
        (Get-TodoLines $d)[0] | Should -Match '^i \(C\) task'
    }
    It 'depri removes priority while keeping the in-progress marker' {
        Invoke-T $d @('add', '(A) task') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        Invoke-T $d @('depri', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Match '^i task'
    }
    It 'archive keeps in-progress tasks but moves done tasks' {
        Invoke-T $d @('add', 'one') | Out-Null
        Invoke-T $d @('add', 'two') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null
        Invoke-T $d @('-a', 'do', '2') | Out-Null   # mark done without auto-archiving
        Invoke-T $d @('archive') | Out-Null         # explicit archive
        (Get-TodoLines $d) | Should -HaveCount 1
        (Get-TodoLines $d)[0] | Should -Match '^i one'
        (Get-DoneLines $d)[0] | Should -Match '^x 2020-01-15 two'
    }
    It 'in-progress task sorts by its underlying priority' {
        Invoke-T $d @('add', '(A) alpha') | Out-Null
        Invoke-T $d @('add', '(B) bravo') | Out-Null
        Invoke-T $d @('start', '1') | Out-Null   # i (A) alpha -> still sorts first
        $out = Invoke-T $d @('ls')
        $out[0] | Should -Match 'i \(A\) alpha'
        $out[1] | Should -Match '\(B\) bravo'
    }
}

Describe 'Action: start requires the feature toggle' {
    BeforeEach { $script:d = New-TestDir }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'throws when TODOTXT_IN_PROGRESS is not enabled' {
        Invoke-T $d @('add', 'task') | Out-Null
        { Invoke-T $d @('start', '1') } | Should -Throw '*in-progress tracking*'
    }
}

Describe 'Action: date tags off by default' {
    BeforeEach { $script:d = New-TestDir; Mock -ModuleName TodoTxt Get-TodoDate { '2020-01-15' } }
    AfterEach { Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue }

    It 'add does not tag when date tags are off' {
        Invoke-T $d @('add', 'buy milk') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'buy milk'
    }
    It 'do does not add a completed: tag when date tags are off' {
        Invoke-T $d @('add', 'buy milk') | Out-Null
        Invoke-T $d @('-a', 'do', '1') | Out-Null
        (Get-TodoLines $d)[0] | Should -Be 'x 2020-01-15 buy milk'
    }
}

# ----------------------------------------------------------------------------
Describe 'Color: in-progress marker' {
    It 'emits the in-progress color for an i line without priority' {
        $c = New-TodoConfig -TodoDir 'x' -Overrides @{ Plain = $false }
        $line = Format-TodoDisplayLine -Config $c -Num 1 -Text 'i buy milk' -Width 1
        $line | Should -Match ([char]27)
        $line | Should -Match ([regex]::Escape($c.Colors.COLOR_INPROGRESS))
    }
    It 'colors an in-progress priority task by its priority color' {
        $c = New-TodoConfig -TodoDir 'x' -Overrides @{ Plain = $false }
        $line = Format-TodoDisplayLine -Config $c -Num 1 -Text 'i (A) task' -Width 1
        $line | Should -Match ([regex]::Escape($c.Colors.PRI_A))
    }
}

# ----------------------------------------------------------------------------
Describe 'Action: add-ons override built-ins' {
    BeforeEach {
        $script:d = New-TestDir
        $script:actions = Join-Path $script:d 'actions'
        [void][System.IO.Directory]::CreateDirectory($script:actions)
        $env:TODO_ACTIONS_DIR = $script:actions
    }
    AfterEach {
        Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TODO_ACTIONS_DIR -ErrorAction SilentlyContinue
    }

    It 'an add.ps1 add-on shadows the built-in add' {
        'param() "OVERRIDE:$args"' | Set-Content -Path (Join-Path $actions 'add.ps1')
        $out = Invoke-T $d @('add', 'hello')
        $out | Should -Be 'OVERRIDE:hello'
        (Get-TodoLines $d) | Should -BeNullOrEmpty   # built-in add never ran
    }
    It 'command <action> bypasses the override and runs the built-in' {
        'param() "OVERRIDE"' | Set-Content -Path (Join-Path $actions 'add.ps1')
        Invoke-T $d @('command', 'add', 'real task') | Out-Null
        (Get-TodoLines $d) | Should -Be @('real task')
    }
    It 'the add-on receives a real TODO_SH wrapper path' {
        'param() $env:TODO_SH' | Set-Content -Path (Join-Path $actions 'whereami.ps1')
        $out = Invoke-T $d @('whereami')
        $out | Should -Match 'todo\.ps1$'
        Test-Path $out | Should -BeTrue
    }
}

# ----------------------------------------------------------------------------
Describe 'Git tracking (mocked git)' {
    BeforeEach {
        $script:d = New-TestDir
        $env:TODOTXT_GIT = '1'
        Mock -ModuleName TodoTxt Test-TodoGitAvailable { $true }
        Mock -ModuleName TodoTxt Test-TodoGitRepo { $true }
        Mock -ModuleName TodoTxt Invoke-TodoGitCommand { [pscustomobject]@{ ExitCode = 0; Output = '' } }
    }
    AfterEach {
        Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TODOTXT_GIT, Env:\TODOTXT_GIT_REMOTE -ErrorAction SilentlyContinue
    }

    It 'commits after a mutating action' {
        Invoke-T $d @('add', 'task') | Out-Null
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'add' }
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'commit' }
    }
    It 'does not run git for a read-only action' {
        Invoke-T $d @('add', 'task') | Out-Null   # set up state
        # Re-arm the mock counters by acting again on a read-only command.
        $before = 0
        Invoke-T $d @('ls') | Out-Null
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'commit' } -Times 1 -Exactly
        # exactly one commit total (from the add), none from ls
    }
    It 'pushes when a remote is configured' {
        $env:TODOTXT_GIT_REMOTE = 'git@example.com:me/todo.git'
        Invoke-T $d @('add', 'task') | Out-Null
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'push' }
    }
    It 'auto-initializes the repo when missing (and adds the remote)' {
        $env:TODOTXT_GIT_REMOTE = 'git@example.com:me/todo.git'
        Mock -ModuleName TodoTxt Test-TodoGitRepo { $false }
        Invoke-T $d @('add', 'task') | Out-Null
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'init' }
        Should -Invoke -ModuleName TodoTxt Invoke-TodoGitCommand -ParameterFilter { $GitArgs[0] -eq 'remote' -and $GitArgs[1] -eq 'add' }
    }
}

Describe 'Git tracking: unavailable git' {
    BeforeEach {
        $script:d = New-TestDir
        $env:TODOTXT_GIT = '1'
        Mock -ModuleName TodoTxt Test-TodoGitAvailable { $false }
    }
    AfterEach {
        Remove-Item $script:d -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\TODOTXT_GIT -ErrorAction SilentlyContinue
    }

    It 'still writes the task, warns, and sets exit code 1' {
        Invoke-T $d @('add', 'task') 2>$null | Out-Null
        (Get-TodoLines $d) | Should -Be @('task')
        Get-TodoExitCode | Should -Be 1
    }
}
