#Requires -Version 7.0
<#
    TodoTxt.psm1 - A PowerShell port of the todo.txt CLI (todo.sh).

    This module implements the behaviour of https://github.com/todotxt/todo.txt-cli
    in pure PowerShell. Where it is faster or cleaner, it leans on .NET BCL types
    (System.IO.File, System.Text.StringBuilder, System.Collections.Generic.List,
    System.Text.RegularExpressions.Regex) instead of pure-PowerShell idioms.

    The public entry point is Invoke-Todo. The remaining functions are exported so
    that the Pester suite (and power users) can unit-test the internals directly.
#>

Set-StrictMode -Version Latest

$script:TodoVersion = '1.0.0'

# Status carried across a single Invoke-Todo call (0 = ok, 1 = a non-fatal
# per-item failure occurred, mirroring todo.sh's `exit $status`).
$script:TodoStatus = 0

#region .NET-backed file I/O ----------------------------------------------------

function Read-TodoFile {
    <# Returns the file as a string[] (no trailing empty element). Missing file => @(). #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return , ([string[]]@()) }
    return , ([string[]][System.IO.File]::ReadAllLines($Path))
}

function Write-TodoFile {
    <# Writes one task per line as UTF-8 (no BOM); the file ends with a newline. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $encoding)
}

#endregion

#region Parsing helpers ---------------------------------------------------------

function Get-TodoPrefix {
    <# basename with the first extension stripped, upper-cased: todo.txt -> TODO. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    $name = [System.IO.Path]::GetFileName($Path)
    $base = $name.Split('.')[0]
    return $base.ToUpperInvariant()
}

function Split-TodoMarker {
    <#
        Splits an optional leading single-character status marker from a task.
        Recognized markers are 'x ' (done) and 'i ' (in-progress). Everything that
        reasons about a task's priority/date/text first skips this marker, so an
        in-progress task such as "i (A) buy milk" still reports priority A and
        sorts among its priority peers. The set is intentionally limited to {x, i}
        so a real task beginning with a single-letter word (e.g. "a +proj") is
        never mistaken for a marker.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    if ($Line -match '^([xi] )') {
        return [pscustomobject]@{ Marker = $Matches[1]; Rest = $Line.Substring(2) }
    }
    return [pscustomobject]@{ Marker = ''; Rest = $Line }
}

function Get-TodoPriority {
    <# Returns the single-letter priority (A-Z) of a task line, or $null.
       A leading status marker (x / i) is skipped first. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $rest = (Split-TodoMarker -Line $Line).Rest
    if ($rest -match '^\(([A-Z])\) ') { return $Matches[1] }
    return $null
}

function ConvertTo-TodoCleanInput {
    <# todo.sh cleaninput(): tasks are single lines, so CR/LF become spaces. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return ($Text -replace "`r", ' ' -replace "`n", ' ')
}

function ConvertTo-TodoUppercasePriority {
    <# todo.sh uppercasePriority(): a leading lower-case (a) priority becomes (A). #>
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($Text -match '^\(([a-zA-Z])\)') {
        return '(' + $Matches[1].ToUpperInvariant() + ')' + $Text.Substring(3)
    }
    return $Text
}

function Split-TodoPrefix {
    <#
        Splits a task into its optional leading status marker, priority and
        creation-date prefixes, and the remaining text, mirroring todo.sh's
        priAndDateExpr. Marker/Priority/Date include their trailing space (or are
        empty strings). Callers that rebuild the line MUST re-emit Marker first,
        otherwise an in-progress 'i ' marker is silently dropped.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $m = Split-TodoMarker -Line $Line
    $marker = $m.Marker
    $priority = ''
    $date = ''
    $rest = $m.Rest
    if ($rest -match '^(\([^)]\) )') {
        $priority = $Matches[1]
        $rest = $rest.Substring($priority.Length)
    }
    if ($rest -match '^([0-9]{2,4}-[0-9]{2}-[0-9]{2} )') {
        $date = $Matches[1]
        $rest = $rest.Substring($date.Length)
    }
    return [pscustomobject]@{ Marker = $marker; Priority = $priority; Date = $date; Rest = $rest }
}

#endregion

#region Errors / messaging ------------------------------------------------------

function Invoke-TodoDie {
    <# Fatal error: terminates the current action (todo.sh die / exit 1). #>
    param([Parameter(Mandatory)][string]$Message)
    throw $Message
}

function Write-TodoWarning {
    <# Non-fatal per-item failure: written to stderr (clean, like todo.sh),
       and sets the exit status to 1. #>
    param([Parameter(Mandatory)][string]$Message)
    $script:TodoStatus = 1
    [Console]::Error.WriteLine($Message)
}

function Get-TodoExitCode {
    <# Exit code for the most recent Invoke-Todo call. #>
    [OutputType([int])]
    param()
    return $script:TodoStatus
}

function Confirm-TodoAction {
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Prompt)

    if ($Config.Force) { return $true }
    $answer = Read-Host -Prompt "$($Prompt)? (y/n)"
    return ($answer -match '^(y|yes)$')
}

function Get-TodoDate {
    <# Wrapped so tests can mock the current date. #>
    [OutputType([string])]
    param()
    return (Get-Date).ToString('yyyy-MM-dd')
}

#endregion

#region Configuration -----------------------------------------------------------

function Get-TodoColorMap {
    <# Default ANSI colour map (real ESC sequences). #>
    param([switch]$Plain)

    $esc = [char]27
    $code = {
        param($c)
        if ([string]::IsNullOrEmpty($c)) { return '' }
        return "$esc[$c" + 'm'
    }
    if ($Plain) {
        $colors = @{}
        foreach ($k in 'PRI_A', 'PRI_B', 'PRI_C', 'PRI_X', 'COLOR_DONE', 'COLOR_INPROGRESS',
            'COLOR_PROJECT', 'COLOR_CONTEXT', 'COLOR_DATE', 'COLOR_NUMBER',
            'COLOR_META', 'DEFAULT') { $colors[$k] = '' }
        return $colors
    }
    return @{
        PRI_A            = (& $code '1;33')   # yellow
        PRI_B            = (& $code '0;32')   # green
        PRI_C            = (& $code '1;34')   # light blue
        PRI_X            = (& $code '1;37')   # white
        COLOR_DONE       = (& $code '0;37')   # light grey
        COLOR_INPROGRESS = (& $code '1;36')   # light cyan
        COLOR_PROJECT    = ''
        COLOR_CONTEXT    = ''
        COLOR_DATE       = ''
        COLOR_NUMBER     = ''
        COLOR_META       = ''
        DEFAULT          = (& $code '0')
    }
}

function ConvertFrom-TodoConfig {
    <#
        Parses a todo.cfg / config file (a Bash script of `export VAR=value`
        assignments) into an ordered hashtable. Supports comments, single/double
        quotes, and $VAR / ${VAR} expansion against previously-assigned variables,
        the standard ANSI colour names, and the process environment.
    #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $vars = [ordered]@{}

    # Seed the well-known ANSI colour names so `PRI_A=$YELLOW` resolves.
    $esc = [char]27
    $ansi = @{
        NONE = ''; BLACK = "$esc[0;30m"; RED = "$esc[0;31m"; GREEN = "$esc[0;32m"
        BROWN = "$esc[0;33m"; BLUE = "$esc[0;34m"; PURPLE = "$esc[0;35m"
        CYAN = "$esc[0;36m"; LIGHT_GREY = "$esc[0;37m"; DARK_GREY = "$esc[1;30m"
        LIGHT_RED = "$esc[1;31m"; LIGHT_GREEN = "$esc[1;32m"; YELLOW = "$esc[1;33m"
        LIGHT_BLUE = "$esc[1;34m"; LIGHT_PURPLE = "$esc[1;35m"; LIGHT_CYAN = "$esc[1;36m"
        WHITE = "$esc[1;37m"; DEFAULT = "$esc[0m"
    }
    foreach ($k in $ansi.Keys) { $vars[$k] = $ansi[$k] }

    $expand = {
        param([string]$value)
        # ${VAR} and $VAR expansion.
        $value = [regex]::Replace($value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', {
                param($m)
                $n = $m.Groups[1].Value
                if ($vars.Contains($n)) { return [string]$vars[$n] }
                return [string][System.Environment]::GetEnvironmentVariable($n)
            })
        $value = [regex]::Replace($value, '\$([A-Za-z_][A-Za-z0-9_]*)', {
                param($m)
                $n = $m.Groups[1].Value
                if ($vars.Contains($n)) { return [string]$vars[$n] }
                return [string][System.Environment]::GetEnvironmentVariable($n)
            })
        # Literal ANSI escapes written as \033 or \\033.
        $value = $value -replace '\\+033', "$([char]27)"
        $value = $value -replace '\\+e', "$([char]27)"
        return $value
    }

    foreach ($raw in (Read-TodoFile -Path $Path)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2].Trim()

        # Strip a trailing inline comment when the value is unquoted.
        if ($value -notmatch '^[''"]' -and $value -match '\s+#') {
            $value = ($value -replace '\s+#.*$', '').Trim()
        }
        # Strip matching surrounding quotes.
        if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[-1] -eq "'") {
            $value = $value.Substring(1, $value.Length - 2)
        }
        elseif ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[-1] -eq '"') {
            $value = (& $expand $value.Substring(1, $value.Length - 2))
        }
        else {
            $value = (& $expand $value)
        }
        $vars[$name] = $value
    }
    return $vars
}

function New-TodoConfig {
    <#
        Builds the effective configuration. Precedence (lowest to highest):
        built-in defaults < environment variables < config file < explicit overrides.
    #>
    [OutputType([hashtable])]
    param(
        [string]$ConfigFile,
        [string]$TodoDir,
        [hashtable]$Overrides = @{}
    )

    $home = if ($env:HOME) { $env:HOME } elseif ($env:USERPROFILE) { $env:USERPROFILE } else { [System.IO.Path]::GetTempPath() }

    # --- defaults -----------------------------------------------------------
    $cfg = @{
        TodoDir                 = $null
        TodoFile                = $null
        DoneFile                = $null
        ReportFile              = $null
        ActionsDir              = $null
        Verbose                 = 1
        Plain                   = $false
        Force                   = $false
        PreserveLineNumbers     = $true
        AutoArchive             = $true
        DateOnAdd               = $false
        PriorityOnAdd           = ''
        DefaultAction           = ''
        DisableFilter           = $false
        SentenceDelimiters      = ',.:;'
        SigilBeforePattern      = ''
        SigilValidPattern       = '.*'
        SigilAfterPattern       = ''
        SourceVar               = ''
        HideProjects            = $false
        HideContexts            = $false
        HidePriority            = $false
        DateTags                = $false
        InProgress              = $false
        Git                     = $false
        GitRemote               = ''
        Colors                  = (Get-TodoColorMap)
        RawConfig               = @{}
    }

    # --- environment --------------------------------------------------------
    $envMap = @{
        TODO_DIR                      = { param($v) $cfg.TodoDir = $v }
        TODO_FILE                     = { param($v) $cfg.TodoFile = $v }
        DONE_FILE                     = { param($v) $cfg.DoneFile = $v }
        REPORT_FILE                   = { param($v) $cfg.ReportFile = $v }
        TODO_ACTIONS_DIR              = { param($v) $cfg.ActionsDir = $v }
        TODOTXT_VERBOSE               = { param($v) $cfg.Verbose = [int]$v }
        TODOTXT_PLAIN                 = { param($v) $cfg.Plain = ($v -eq '1') }
        TODOTXT_FORCE                 = { param($v) $cfg.Force = ($v -eq '1') }
        TODOTXT_PRESERVE_LINE_NUMBERS = { param($v) $cfg.PreserveLineNumbers = ($v -ne '0') }
        TODOTXT_AUTO_ARCHIVE          = { param($v) $cfg.AutoArchive = ($v -ne '0') }
        TODOTXT_DATE_ON_ADD           = { param($v) $cfg.DateOnAdd = ($v -eq '1') }
        TODOTXT_PRIORITY_ON_ADD       = { param($v) $cfg.PriorityOnAdd = $v }
        TODOTXT_DEFAULT_ACTION        = { param($v) $cfg.DefaultAction = $v }
        TODOTXT_DISABLE_FILTER        = { param($v) $cfg.DisableFilter = ($v -eq '1') }
        TODOTXT_SOURCEVAR             = { param($v) $cfg.SourceVar = $v }
        TODOTXT_SIGIL_BEFORE_PATTERN  = { param($v) $cfg.SigilBeforePattern = $v }
        TODOTXT_SIGIL_VALID_PATTERN   = { param($v) $cfg.SigilValidPattern = $v }
        TODOTXT_SIGIL_AFTER_PATTERN   = { param($v) $cfg.SigilAfterPattern = $v }
        TODOTXT_DATE_TAGS             = { param($v) $cfg.DateTags = ($v -eq '1') }
        TODOTXT_IN_PROGRESS           = { param($v) $cfg.InProgress = ($v -eq '1') }
        TODOTXT_GIT                   = { param($v) $cfg.Git = ($v -eq '1') }
        TODOTXT_GIT_REMOTE            = { param($v) $cfg.GitRemote = $v }
    }
    foreach ($name in $envMap.Keys) {
        $val = [System.Environment]::GetEnvironmentVariable($name)
        if ($null -ne $val -and $val -ne '') { & $envMap[$name] $val }
    }

    # --- config file --------------------------------------------------------
    if (-not $ConfigFile) { $ConfigFile = $env:TODOTXT_CFG_FILE }
    if (-not $ConfigFile) {
        $candidates = @(
            (Join-Path $home '.todo/config'),
            (Join-Path $home 'todo.cfg'),
            (Join-Path $home '.todo.cfg'),
            (Join-Path ($(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $home '.config' })) 'todo/config')
        )
        foreach ($c in $candidates) { if ([System.IO.File]::Exists($c)) { $ConfigFile = $c; break } }
    }
    if ($ConfigFile -and [System.IO.File]::Exists($ConfigFile)) {
        $vars = ConvertFrom-TodoConfig -Path $ConfigFile
        $cfg.RawConfig = $vars
        foreach ($k in $vars.Keys) {
            $v = [string]$vars[$k]
            switch ($k) {
                'TODO_DIR' { $cfg.TodoDir = $v }
                'TODO_FILE' { $cfg.TodoFile = $v }
                'DONE_FILE' { $cfg.DoneFile = $v }
                'REPORT_FILE' { $cfg.ReportFile = $v }
                'TODO_ACTIONS_DIR' { $cfg.ActionsDir = $v }
                'TODOTXT_VERBOSE' { $cfg.Verbose = [int]$v }
                'TODOTXT_PLAIN' { $cfg.Plain = ($v -eq '1') }
                'TODOTXT_FORCE' { $cfg.Force = ($v -eq '1') }
                'TODOTXT_PRESERVE_LINE_NUMBERS' { $cfg.PreserveLineNumbers = ($v -ne '0') }
                'TODOTXT_AUTO_ARCHIVE' { $cfg.AutoArchive = ($v -ne '0') }
                'TODOTXT_DATE_ON_ADD' { $cfg.DateOnAdd = ($v -eq '1') }
                'TODOTXT_PRIORITY_ON_ADD' { $cfg.PriorityOnAdd = $v }
                'TODOTXT_DEFAULT_ACTION' { $cfg.DefaultAction = $v }
                'TODOTXT_DISABLE_FILTER' { $cfg.DisableFilter = ($v -eq '1') }
                'TODOTXT_SOURCEVAR' { $cfg.SourceVar = $v }
                'TODOTXT_SIGIL_BEFORE_PATTERN' { $cfg.SigilBeforePattern = $v }
                'TODOTXT_SIGIL_VALID_PATTERN' { $cfg.SigilValidPattern = $v }
                'TODOTXT_SIGIL_AFTER_PATTERN' { $cfg.SigilAfterPattern = $v }
                'TODOTXT_DATE_TAGS' { $cfg.DateTags = ($v -eq '1') }
                'TODOTXT_IN_PROGRESS' { $cfg.InProgress = ($v -eq '1') }
                'TODOTXT_GIT' { $cfg.Git = ($v -eq '1') }
                'TODOTXT_GIT_REMOTE' { $cfg.GitRemote = $v }
                default {
                    if ($cfg.Colors.ContainsKey($k)) { $cfg.Colors[$k] = $v }
                }
            }
        }
    }

    # --- explicit overrides (command line) ----------------------------------
    if ($TodoDir) { $cfg.TodoDir = $TodoDir }
    foreach ($k in $Overrides.Keys) {
        switch ($k) {
            'Force' { $cfg.Force = [bool]$Overrides[$k] }
            'Plain' { $cfg.Plain = [bool]$Overrides[$k] }
            'PreserveLineNumbers' { $cfg.PreserveLineNumbers = [bool]$Overrides[$k] }
            'AutoArchive' { $cfg.AutoArchive = [bool]$Overrides[$k] }
            'DateOnAdd' { $cfg.DateOnAdd = [bool]$Overrides[$k] }
            'Verbose' { $cfg.Verbose = [int]$Overrides[$k] }
            'DisableFilter' { $cfg.DisableFilter = [bool]$Overrides[$k] }
            'HideProjects' { $cfg.HideProjects = [bool]$Overrides[$k] }
            'HideContexts' { $cfg.HideContexts = [bool]$Overrides[$k] }
            'HidePriority' { $cfg.HidePriority = [bool]$Overrides[$k] }
            default { $cfg[$k] = $Overrides[$k] }
        }
    }

    # --- derived paths ------------------------------------------------------
    if (-not $cfg.TodoDir) { $cfg.TodoDir = (Join-Path $home '.todo') }
    if (-not $cfg.TodoFile) { $cfg.TodoFile = (Join-Path $cfg.TodoDir 'todo.txt') }
    if (-not $cfg.DoneFile) { $cfg.DoneFile = (Join-Path $cfg.TodoDir 'done.txt') }
    if (-not $cfg.ReportFile) { $cfg.ReportFile = (Join-Path $cfg.TodoDir 'report.txt') }
    if (-not $cfg.ActionsDir) { $cfg.ActionsDir = (Join-Path $cfg.TodoDir 'actions') }

    if ($cfg.Plain) { $cfg.Colors = (Get-TodoColorMap -Plain) }
    # todo.sh blanks the project/context colour when hiding them.
    if ($cfg.HideProjects) { $cfg.Colors.COLOR_PROJECT = '' }
    if ($cfg.HideContexts) { $cfg.Colors.COLOR_CONTEXT = '' }

    if ($cfg.PriorityOnAdd -and $cfg.PriorityOnAdd -notmatch '^[A-Z]$') {
        Invoke-TodoDie "TODOTXT_PRIORITY_ON_ADD should be a capital letter from A to Z (it is now `"$($cfg.PriorityOnAdd)`")."
    }
    return $cfg
}

function Initialize-TodoFiles {
    <# Ensures the todo directory and the three core files exist. #>
    param([Parameter(Mandatory)]$Config)

    if (-not [System.IO.Directory]::Exists($Config.TodoDir)) {
        try { [void][System.IO.Directory]::CreateDirectory($Config.TodoDir) }
        catch { Invoke-TodoDie "Fatal Error: $($Config.TodoDir) is not a directory" }
    }
    foreach ($f in $Config.TodoFile, $Config.DoneFile, $Config.ReportFile) {
        if (-not [System.IO.File]::Exists($f)) { Write-TodoFile -Path $f -Lines @() }
    }
}

#endregion

#region Listing / formatting ----------------------------------------------------

function Get-TodoEntries {
    <# Numbers physical lines (1-based) and drops blank/whitespace-only tasks. #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [int]$Start = 1,
        [Nullable[int]]$ForceNumber = $null
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $text = $Lines[$i]
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $num = if ($null -ne $ForceNumber) { [int]$ForceNumber } else { $Start + $i }
        $entries.Add([pscustomobject]@{ Num = $num; Text = $text })
    }
    return , ($entries.ToArray())
}

function Test-TodoMatch {
    <# AND of grep-style terms; a leading '-' negates (exclude). Case-insensitive. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Text, [AllowEmptyCollection()][string[]]$Terms)

    foreach ($term in $Terms) {
        if ([string]::IsNullOrEmpty($term)) { continue }
        if ($term.StartsWith('-')) {
            $pattern = $term.Substring(1)
            if ($pattern -ne '' -and [regex]::IsMatch($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return $false
            }
        }
        else {
            if (-not [regex]::IsMatch($Text, $term, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                return $false
            }
        }
    }
    return $true
}

function Format-TodoDisplayLine {
    <# Renders one numbered task with colour + project/context/priority hiding. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$Num,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )

    $C = $Config.Colors
    $numStr = ([string]$Num).PadLeft($Width) -replace ' ', '0'  # todo.sh zero-pads
    $full = "$numStr $Text"

    $clr = ''
    if ($full -match '^[0-9]+ x ') {
        $clr = $C.COLOR_DONE
    }
    elseif ($full -match '^[0-9]+ i ') {
        # in-progress: colour by priority when present, else the in-progress colour
        if ($full -match '^[0-9]+ i \(([A-Z])\) ') {
            $p = $Matches[1]
            $clr = $C["PRI_$p"]
            if ([string]::IsNullOrEmpty($clr)) { $clr = $C.PRI_X }
        }
        else {
            $clr = $C.COLOR_INPROGRESS
        }
        if ($Config.HidePriority) { $full = $full -replace '^([0-9]+ i )\([A-Z]\) ', '$1' }
    }
    elseif ($full -match '^[0-9]+ \(([A-Z])\) ') {
        $p = $Matches[1]
        $clr = $C["PRI_$p"]
        if ([string]::IsNullOrEmpty($clr)) { $clr = $C.PRI_X }
        if ($Config.HidePriority) { $full = $full -replace '^([0-9]+) \([A-Z]\) ', '$1 ' }
    }

    $default = $C.DEFAULT
    $endClr = if ($clr) { $default } else { '' }

    $wrap = {
        param($begin, $word)
        if ([string]::IsNullOrEmpty($begin)) { return $word }
        return "$begin$word$default$clr"
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append($clr)
    $parts = [regex]::Split($full, '(\s+)')
    $wordIndex = 0
    foreach ($w in $parts) {
        if ($w -eq '') { continue }
        if ($w -match '^\s+$') { [void]$sb.Append($w); continue }

        if ($wordIndex -eq 0 -and $w -match '^[0-9]+$') {
            [void]$sb.Append((& $wrap $C.COLOR_NUMBER $w))
        }
        elseif ($w -match '^\+.*[A-Za-z0-9_]$') {
            [void]$sb.Append((& $wrap $C.COLOR_PROJECT $w))
        }
        elseif ($w -match '^@.*[A-Za-z0-9_]$') {
            [void]$sb.Append((& $wrap $C.COLOR_CONTEXT $w))
        }
        elseif ($w -match '^(19|20)[0-9][0-9]-(0[1-9]|1[012])-(0[1-9]|[12][0-9]|3[01])$') {
            [void]$sb.Append((& $wrap $C.COLOR_DATE $w))
        }
        elseif ($w -match '^[A-Za-z0-9]+:[^ ]+$') {
            [void]$sb.Append((& $wrap $C.COLOR_META $w))
        }
        else {
            [void]$sb.Append($w)
        }
        $wordIndex++
    }
    [void]$sb.Append($endClr)
    $line = $sb.ToString()

    if ($Config.HideProjects) { $line = $line -replace '\s\+\S+', '' }
    if ($Config.HideContexts) { $line = $line -replace '\s@\S+', '' }
    return $line
}

function Format-TodoEntries {
    <# Filters, sorts (ordinal, case-insensitive) and renders entries. #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Entries,
        [AllowEmptyCollection()][string[]]$Terms = @(),
        [int]$Width = 1,
        [string]$PriorityFilter = $null
    )

    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Entries) {
        if (-not (Test-TodoMatch -Text "$($e.Num) $($e.Text)" -Terms $Terms)) { continue }
        if ($PriorityFilter) {
            if ($e.Text -notmatch "^\([$PriorityFilter]\) ") { continue }
        }
        $filtered.Add($e)
    }

    $comparison = [System.Comparison[object]] {
        param($a, $b)
        # Skip a leading status marker (x / i) so in-progress and done tasks sort
        # by their underlying priority/text rather than clustering under the marker.
        $ka = (Split-TodoMarker -Line $a.Text).Rest
        $kb = (Split-TodoMarker -Line $b.Text).Rest
        $r = [string]::Compare($ka, $kb, [System.StringComparison]::OrdinalIgnoreCase)
        if ($r -eq 0) { $r = $a.Num.CompareTo($b.Num) }
        return $r
    }
    $filtered.Sort($comparison)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $filtered) {
        $lines.Add((Format-TodoDisplayLine -Config $Config -Num $e.Num -Text $e.Text -Width $Width))
    }
    return [pscustomobject]@{
        Lines = $lines.ToArray()
        Shown = $filtered.Count
        Total = @($Entries).Count
    }
}

function Get-TodoPadding {
    [OutputType([int])]
    param([AllowEmptyCollection()][string[]]$Lines)
    $count = @($Lines).Count
    if ($count -eq 0) { return 1 }
    return ([string]$count).Length
}

#endregion

#region Actions -----------------------------------------------------------------

function Add-TodoTask {
    <# todo.sh _addto(): cleans, upper-cases priority, applies date/priority-on-add. #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $text = ConvertTo-TodoCleanInput -Text $Text
    $text = ConvertTo-TodoUppercasePriority -Text $text

    if ($Config.DateOnAdd) {
        $now = Get-TodoDate
        if ($text -match '^(\([A-Z]\) )') {
            $text = $Matches[1] + "$now " + $text.Substring($Matches[1].Length)
        }
        else {
            $text = "$now $text"
        }
    }
    if ($Config.PriorityOnAdd) {
        if ($text -notmatch '^\([A-Z]\)') {
            $text = "($($Config.PriorityOnAdd)) $text"
        }
    }
    if ($Config.DateTags) {
        $text = "$text added:$(Get-TodoDate)"
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Read-TodoFile -Path $File))
    $lines.Add($text)
    Write-TodoFile -Path $File -Lines $lines

    if ($Config.Verbose -gt 0) {
        $num = $lines.Count
        "$num $text"
        "$(Get-TodoPrefix $File): $num added."
    }
}

function Get-TodoTaskText {
    <# Returns the text of task $Number from $File, or dies if absent. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Number,
        [string]$ErrorMessage
    )
    if ([string]::IsNullOrEmpty($Number)) { Invoke-TodoDie $ErrorMessage }
    if ($Number -notmatch '^[0-9]+$') { Invoke-TodoDie $ErrorMessage }

    $lines = Read-TodoFile -Path $File
    $idx = [int]$Number - 1
    if ($idx -lt 0 -or $idx -ge $lines.Count -or [string]::IsNullOrEmpty($lines[$idx])) {
        Invoke-TodoDie "$(Get-TodoPrefix $File): No task $Number."
    }
    return $lines[$idx]
}

function Invoke-TodoAdd {
    param($Config, [string[]]$Params)
    if ($Params.Count -eq 0) {
        if ($Config.Force) { Invoke-TodoDie 'usage: todo.ps1 add "TODO ITEM"' }
        $taskInput = Read-Host -Prompt 'Add'
    }
    else {
        $taskInput = ($Params -join ' ')
    }
    Add-TodoTask -Config $Config -File $Config.TodoFile -Text $taskInput
}

function Invoke-TodoAddMultiple {
    param($Config, [string[]]$Params)
    if ($Params.Count -eq 0) {
        if ($Config.Force) { Invoke-TodoDie 'usage: todo.ps1 addm "TODO ITEM"' }
        $taskInput = Read-Host -Prompt 'Add'
    }
    else {
        $taskInput = ($Params -join ' ')
    }
    foreach ($line in ($taskInput -split "`r?`n")) {
        Add-TodoTask -Config $Config -File $Config.TodoFile -Text $line
    }
}

function Invoke-TodoAddTo {
    param($Config, [string[]]$Params)
    $usage = 'usage: todo.ps1 addto DEST "TODO ITEM"'
    if ($Params.Count -lt 2) { Invoke-TodoDie $usage }
    $dest = Join-Path $Config.TodoDir $Params[0]
    if (-not [System.IO.File]::Exists($dest)) {
        Invoke-TodoDie "TODO: Destination file $dest does not exist."
    }
    $taskInput = ($Params[1..($Params.Count - 1)] -join ' ')
    Add-TodoTask -Config $Config -File $dest -Text $taskInput
}

function Invoke-TodoAppend {
    param($Config, [string[]]$Params)
    $usage = 'usage: todo.ps1 append NR "TEXT TO APPEND"'
    $item = if ($Params.Count -ge 1) { $Params[0] } else { '' }
    $todo = Get-TodoTaskText -File $Config.TodoFile -Number $item -ErrorMessage $usage

    if ($Params.Count -lt 2) {
        if ($Config.Force) { $taskInput = '' } else { $taskInput = Read-Host -Prompt 'Append' }
    }
    else {
        $taskInput = ($Params[1..($Params.Count - 1)] -join ' ')
    }
    $taskInput = ConvertTo-TodoCleanInput -Text $taskInput

    $space = ' '
    if ($taskInput.Length -gt 0 -and $Config.SentenceDelimiters.Contains($taskInput[0])) { $space = '' }

    $lines = Read-TodoFile -Path $Config.TodoFile
    $idx = [int]$item - 1
    $lines[$idx] = "$($lines[$idx])$space$taskInput"
    Write-TodoFile -Path $Config.TodoFile -Lines $lines

    if ($Config.Verbose -gt 0) { "$item $($lines[$idx])" }
}

function Invoke-TodoReplaceOrPrepend {
    param($Config, [string]$Action, [string[]]$Params)
    $usage = if ($Action -eq 'replace') { 'usage: todo.ps1 replace NR "UPDATED ITEM"' } else { 'usage: todo.ps1 prepend NR "TEXT TO PREPEND"' }
    $item = if ($Params.Count -ge 1) { $Params[0] } else { '' }
    $todo = Get-TodoTaskText -File $Config.TodoFile -Number $item -ErrorMessage $usage

    if ($Params.Count -lt 2) {
        if ($Config.Force) { $taskInput = '' } else { $taskInput = Read-Host -Prompt $(if ($Action -eq 'replace') { 'Replacement' } else { 'Prepend' }) }
    }
    else {
        $taskInput = ($Params[1..($Params.Count - 1)] -join ' ')
    }
    $taskInput = ConvertTo-TodoCleanInput -Text $taskInput

    $orig = Split-TodoPrefix -Line $todo
    $marker = $orig.Marker          # preserve a leading x / i status marker
    $priority = $orig.Priority
    $prepdate = $orig.Date

    if ($Action -eq 'replace') {
        $repl = Split-TodoPrefix -Line $taskInput
        if ($repl.Date) { $prepdate = $repl.Date }
        if ($repl.Priority) { $priority = $repl.Priority }
        $taskInput = $repl.Rest
        $newText = "$marker$priority$prepdate$taskInput"
    }
    else {
        # prepend: marker + priority + date + input + ' ' + remaining original text
        $newText = "$marker$priority$prepdate$taskInput $($orig.Rest)"
    }

    $lines = Read-TodoFile -Path $Config.TodoFile
    $idx = [int]$item - 1
    $lines[$idx] = $newText
    Write-TodoFile -Path $Config.TodoFile -Lines $lines

    if ($Config.Verbose -gt 0) {
        if ($Action -eq 'replace') {
            "$item $todo"
            'TODO: Replaced task with:'
            "$item $newText"
        }
        else {
            "$item $newText"
        }
    }
}

function Invoke-TodoDone {
    param($Config, [string[]]$Params)
    if ($Params.Count -eq 0) { Invoke-TodoDie 'usage: todo.ps1 do NR [NR ...]' }

    $items = ($Params -join ' ') -split '[ ,]+' | Where-Object { $_ -ne '' }
    $lines = Read-TodoFile -Path $Config.TodoFile
    $messages = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $items) {
        if ($item -notmatch '^[0-9]+$') { Invoke-TodoDie 'usage: todo.ps1 do NR [NR ...]' }
        $idx = [int]$item - 1
        if ($idx -lt 0 -or $idx -ge $lines.Count -or [string]::IsNullOrEmpty($lines[$idx])) {
            Invoke-TodoDie "$(Get-TodoPrefix $Config.TodoFile): No task $item."
        }
        $todo = $lines[$idx]
        $m = Split-TodoMarker -Line $todo
        if ($m.Marker -eq 'x ') {
            Write-TodoWarning "TODO: $item is already marked done."
            continue
        }
        $now = Get-TodoDate
        # Drop any leading status marker (e.g. in-progress 'i ') and the priority,
        # then mark done. A started: tag inside the body is preserved.
        $body = $m.Rest -replace '^\(.\) ', ''
        $line = "x $now $body"
        if ($Config.DateTags) { $line = "$line completed:$now" }
        $lines[$idx] = $line
        if ($Config.Verbose -gt 0) {
            $messages.Add("$item $($lines[$idx])")
            $messages.Add("TODO: $item marked as done.")
        }
    }
    Write-TodoFile -Path $Config.TodoFile -Lines $lines
    foreach ($m in $messages) { $m }

    if ($Config.AutoArchive) { Invoke-TodoArchive -Config $Config }
}

function Invoke-TodoStart {
    <#
        Marks tasks in-progress by prepending an 'i ' status marker and appending a
        started:<date> tag. The task's priority is preserved (stored after the
        marker, e.g. "i (A) task started:2026-06-02"). Requires TODOTXT_IN_PROGRESS.
    #>
    param($Config, [string[]]$Params)
    if (-not $Config.InProgress) {
        Invoke-TodoDie "TODO: the 'start' action requires in-progress tracking (set TODOTXT_IN_PROGRESS=1)."
    }
    if ($Params.Count -eq 0) { Invoke-TodoDie 'usage: todo.ps1 start NR [NR ...]' }

    $items = ($Params -join ' ') -split '[ ,]+' | Where-Object { $_ -ne '' }
    $lines = Read-TodoFile -Path $Config.TodoFile

    foreach ($item in $items) {
        if ($item -notmatch '^[0-9]+$') { Invoke-TodoDie 'usage: todo.ps1 start NR [NR ...]' }
        $idx = [int]$item - 1
        if ($idx -lt 0 -or $idx -ge $lines.Count -or [string]::IsNullOrEmpty($lines[$idx])) {
            Invoke-TodoDie "$(Get-TodoPrefix $Config.TodoFile): No task $item."
        }
        $m = Split-TodoMarker -Line $lines[$idx]
        if ($m.Marker -eq 'i ') {
            Write-TodoWarning "TODO: $item is already in progress."
            continue
        }
        if ($m.Marker -eq 'x ') {
            Write-TodoWarning "TODO: $item is already marked done."
            continue
        }
        $lines[$idx] = "i $($m.Rest) started:$(Get-TodoDate)"
        if ($Config.Verbose -gt 0) {
            "$item $($lines[$idx])"
            "TODO: $item marked in-progress."
        }
    }
    Write-TodoFile -Path $Config.TodoFile -Lines $lines
}

function Invoke-TodoDeprioritize {
    param($Config, [string[]]$Params)
    if ($Params.Count -eq 0) { Invoke-TodoDie 'usage: todo.ps1 depri NR [NR ...]' }

    $items = ($Params -join ' ') -split '[ ,]+' | Where-Object { $_ -ne '' }
    $lines = Read-TodoFile -Path $Config.TodoFile

    foreach ($item in $items) {
        if ($item -notmatch '^[0-9]+$') { Invoke-TodoDie 'usage: todo.ps1 depri NR [NR ...]' }
        $idx = [int]$item - 1
        if ($idx -lt 0 -or $idx -ge $lines.Count -or [string]::IsNullOrEmpty($lines[$idx])) {
            Invoke-TodoDie "$(Get-TodoPrefix $Config.TodoFile): No task $item."
        }
        $m = Split-TodoMarker -Line $lines[$idx]
        if ($m.Rest -match '^\(.\) ') {
            $lines[$idx] = $m.Marker + ($m.Rest -replace '^\(.\) ', '')
            if ($Config.Verbose -gt 0) {
                "$item $($lines[$idx])"
                "TODO: $item deprioritized."
            }
        }
        else {
            Write-TodoWarning "TODO: $item is not prioritized."
        }
    }
    Write-TodoFile -Path $Config.TodoFile -Lines $lines
}

function Invoke-TodoPrioritize {
    param($Config, [string[]]$Params)
    $usage = "usage: todo.ps1 pri NR PRIORITY [NR PRIORITY ...]`nnote: PRIORITY must be anywhere from A to Z."
    if ($Params.Count -lt 2 -or ($Params.Count % 2) -ne 0) { Invoke-TodoDie $usage }

    $lines = Read-TodoFile -Path $Config.TodoFile
    for ($i = 0; $i -lt $Params.Count; $i += 2) {
        $item = $Params[$i]
        $newpri = $Params[$i + 1].ToUpperInvariant()
        if ($newpri -notmatch '^[A-Z]$') { Invoke-TodoDie $usage }
        if ($item -notmatch '^[0-9]+$') { Invoke-TodoDie $usage }
        $idx = [int]$item - 1
        if ($idx -lt 0 -or $idx -ge $lines.Count -or [string]::IsNullOrEmpty($lines[$idx])) {
            Invoke-TodoDie "$(Get-TodoPrefix $Config.TodoFile): No task $item."
        }
        $oldpri = Get-TodoPriority -Line $lines[$idx]
        if ($oldpri -ne $newpri) {
            $m = Split-TodoMarker -Line $lines[$idx]
            $stripped = $m.Rest -replace '^\(.\) ', ''
            $lines[$idx] = $m.Marker + "($newpri) $stripped"
        }
        if ($Config.Verbose -gt 0) {
            "$item $($lines[$idx])"
            if ($oldpri -ne $newpri) {
                if ($oldpri) { "TODO: $item re-prioritized from ($oldpri) to ($newpri)." }
                else { "TODO: $item prioritized ($newpri)." }
            }
        }
        if ($oldpri -eq $newpri) {
            Write-TodoWarning "TODO: $item already prioritized ($newpri)."
        }
    }
    Write-TodoFile -Path $Config.TodoFile -Lines $lines
}

function Remove-TodoBlankLines {
    <# Removes completely-empty lines (todo.sh `/./!d`); keeps whitespace-only lines. #>
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$Lines)
    return , ([string[]]@($Lines | Where-Object { $_.Length -gt 0 }))
}

function Invoke-TodoDelete {
    param($Config, [string[]]$Params)
    $usage = 'usage: todo.ps1 del NR [TERM]'
    $item = if ($Params.Count -ge 1) { $Params[0] } else { '' }
    $todo = Get-TodoTaskText -File $Config.TodoFile -Number $item -ErrorMessage $usage
    $idx = [int]$item - 1
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]](Read-TodoFile -Path $Config.TodoFile))

    if ($Params.Count -lt 2) {
        if (-not (Confirm-TodoAction -Config $Config -Prompt "Delete '$todo'")) {
            Invoke-TodoDie 'TODO: No tasks were deleted.'
        }
        $lines[$idx] = ''
        if (-not $Config.PreserveLineNumbers) {
            $compacted = Remove-TodoBlankLines -Lines $lines.ToArray()
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.AddRange([string[]]$compacted)
        }
        Write-TodoFile -Path $Config.TodoFile -Lines $lines
        if ($Config.Verbose -gt 0) {
            "$item $todo"
            "TODO: $item deleted."
        }
    }
    else {
        $term = $Params[1]
        $prefix = Split-TodoPrefix -Line $todo
        # Preserve a leading status marker and the priority; remove the term from
        # the rest (which still includes any creation date) like todo.sh.
        $keep = $prefix.Marker + $prefix.Priority
        $body = $todo.Substring($keep.Length)
        # The TERM is matched literally (todo.sh uses a BRE in which +, @ etc.
        # are literal); this keeps `del NR +project` / `del NR @context` working.
        $pattern = [regex]::Escape($term)
        if (-not [regex]::IsMatch($body, $pattern)) {
            if ($Config.Verbose -gt 0) { "$item $todo" }
            Invoke-TodoDie "TODO: '$term' not found; no removal done."
        }
        $newBody = [regex]::Replace($body, $pattern, '')
        $newBody = ($newBody -replace '\s{2,}', ' ').Trim()
        $lines[$idx] = "$keep$newBody"
        Write-TodoFile -Path $Config.TodoFile -Lines $lines
        if ($Config.Verbose -gt 0) {
            "$item $todo"
            "TODO: Removed '$term' from task."
            "$item $($lines[$idx])"
        }
    }
}

function Invoke-TodoMove {
    param($Config, [string[]]$Params)
    $usage = 'usage: todo.ps1 mv NR DEST [SRC]'
    if ($Params.Count -lt 2) { Invoke-TodoDie $usage }
    $item = $Params[0]
    $dest = Join-Path $Config.TodoDir $Params[1]
    $src = if ($Params.Count -ge 3) { Join-Path $Config.TodoDir $Params[2] } else { $Config.TodoFile }

    if (-not [System.IO.File]::Exists($src)) { Invoke-TodoDie "TODO: Source file $src does not exist." }
    if (-not [System.IO.File]::Exists($dest)) { Invoke-TodoDie "TODO: Destination file $dest does not exist." }

    $todo = Get-TodoTaskText -File $src -Number $item -ErrorMessage $usage
    if (-not (Confirm-TodoAction -Config $Config -Prompt "Move '$todo' from $src to $dest")) {
        Invoke-TodoDie 'TODO: No tasks moved.'
    }

    $srcLines = [System.Collections.Generic.List[string]]::new()
    $srcLines.AddRange([string[]](Read-TodoFile -Path $src))
    $srcLines[[int]$item - 1] = ''
    if (-not $Config.PreserveLineNumbers) {
        $compacted = Remove-TodoBlankLines -Lines $srcLines.ToArray()
        $srcLines = [System.Collections.Generic.List[string]]::new()
        $srcLines.AddRange([string[]]$compacted)
    }
    Write-TodoFile -Path $src -Lines $srcLines

    $destLines = [System.Collections.Generic.List[string]]::new()
    $destLines.AddRange([string[]](Read-TodoFile -Path $dest))
    $destLines.Add($todo)
    Write-TodoFile -Path $dest -Lines $destLines

    if ($Config.Verbose -gt 0) {
        "$item $todo"
        "TODO: $item moved from '$src' to '$dest'."
    }
}

function Invoke-TodoArchive {
    param($Config)
    $lines = Read-TodoFile -Path $Config.TodoFile
    $kept = [System.Collections.Generic.List[string]]::new()
    $archived = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line.Length -eq 0) { continue }   # defragment blank lines
        if ($line.StartsWith('x ')) { $archived.Add($line) }
        else { $kept.Add($line) }
    }

    if ($archived.Count -gt 0) {
        $done = [System.Collections.Generic.List[string]]::new()
        $done.AddRange([string[]](Read-TodoFile -Path $Config.DoneFile))
        $done.AddRange($archived)
        Write-TodoFile -Path $Config.DoneFile -Lines $done
        Write-TodoFile -Path $Config.TodoFile -Lines $kept
        if ($Config.Verbose -gt 0) {
            foreach ($a in $archived) { $a }
            "TODO: $($Config.TodoFile) archived."
        }
    }
    else {
        # Still defragment blank lines, matching todo.sh's first sed.
        Write-TodoFile -Path $Config.TodoFile -Lines $kept
        if ($Config.Verbose -gt 0) {
            "TODO: $($Config.TodoFile) does not contain any done tasks."
        }
    }
}

function Invoke-TodoDeduplicate {
    param($Config)
    $lines = Read-TodoFile -Path $Config.TodoFile
    $originalCount = (Remove-TodoBlankLines -Lines $lines).Count

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($seen.Contains($line)) {
            if ($Config.PreserveLineNumbers) { $out.Add('') }
            # else: drop the duplicate entirely
        }
        else {
            [void]$seen.Add($line)
            $out.Add($line)
        }
    }
    Write-TodoFile -Path $Config.TodoFile -Lines $out
    $newCount = (Remove-TodoBlankLines -Lines $out.ToArray()).Count
    $removed = $originalCount - $newCount
    if ($removed -eq 0) {
        Invoke-TodoDie 'TODO: No duplicate tasks found'
    }
    "TODO: $removed duplicate task(s) removed"
}

function Invoke-TodoReport {
    param($Config)
    Invoke-TodoArchive -Config $Config   # archive first (todo.sh prints its message too)

    $todoLines = Read-TodoFile -Path $Config.TodoFile
    $doneLines = Read-TodoFile -Path $Config.DoneFile
    $total = $todoLines.Count
    $tdone = $doneLines.Count
    $newData = "$total $tdone"

    $report = Read-TodoFile -Path $Config.ReportFile
    $lastLine = if ($report.Count -gt 0) { $report[-1] } else { '' }
    $lastData = if ($lastLine -match '^\S+\s+(.*)$') { $Matches[1] } else { '' }

    if ($lastData -eq $newData) {
        $lastLine
        if ($Config.Verbose -gt 0) { 'TODO: Report file is up-to-date.' }
    }
    else {
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $newReport = "$stamp $newData"
        $list = [System.Collections.Generic.List[string]]::new()
        $list.AddRange([string[]]$report)
        $list.Add($newReport)
        Write-TodoFile -Path $Config.ReportFile -Lines $list
        $newReport
        if ($Config.Verbose -gt 0) { 'TODO: Report file updated.' }
    }
}

function Invoke-TodoList {
    param($Config, [string[]]$Terms, [string]$File = $null)
    if (-not $File) { $File = $Config.TodoFile }
    else { $File = Resolve-TodoListFile -Config $Config -Name $File }

    $lines = Read-TodoFile -Path $File
    $width = Get-TodoPadding -Lines $lines
    $entries = Get-TodoEntries -Lines $lines
    $result = Format-TodoEntries -Config $Config -Entries $entries -Terms $Terms -Width $width

    foreach ($l in $result.Lines) { $l }
    if ($Config.Verbose -gt 0) {
        '--'
        "$(Get-TodoPrefix $File): $($result.Shown) of $($result.Total) tasks shown"
    }
}

function Resolve-TodoListFile {
    [OutputType([string])]
    param($Config, [string]$Name)
    if ([System.IO.Path]::IsPathRooted($Name) -and [System.IO.File]::Exists($Name)) { return $Name }
    $inDir = Join-Path $Config.TodoDir $Name
    if ([System.IO.File]::Exists($inDir)) { return $inDir }
    if ([System.IO.File]::Exists($Name)) { return $Name }
    $withExt = Join-Path $Config.TodoDir "$Name.txt"
    if ([System.IO.File]::Exists($withExt)) { return $withExt }
    Invoke-TodoDie "TODO: File $Name does not exist."
}

function Invoke-TodoListAll {
    param($Config, [string[]]$Terms)
    $todoLines = Read-TodoFile -Path $Config.TodoFile
    $doneLines = Read-TodoFile -Path $Config.DoneFile
    $width = Get-TodoPadding -Lines $todoLines

    $entries = [System.Collections.Generic.List[object]]::new()
    $entries.AddRange((Get-TodoEntries -Lines $todoLines))
    foreach ($e in (Get-TodoEntries -Lines $doneLines -ForceNumber 0)) { $entries.Add($e) }

    $result = Format-TodoEntries -Config $Config -Entries $entries.ToArray() -Terms $Terms -Width $width
    foreach ($l in $result.Lines) { $l }

    if ($Config.Verbose -gt 0) {
        $todoEntries = Get-TodoEntries -Lines $todoLines
        $doneEntries = Get-TodoEntries -Lines $doneLines
        $todoShown = @($todoEntries | Where-Object { Test-TodoMatch -Text "$($_.Num) $($_.Text)" -Terms $Terms }).Count
        $doneShown = @($doneEntries | Where-Object { Test-TodoMatch -Text "$($_.Num) $($_.Text)" -Terms $Terms }).Count
        $total = $todoEntries.Count
        $tdone = $doneEntries.Count
        '--'
        "$(Get-TodoPrefix $Config.TodoFile): $todoShown of $total tasks shown"
        "$(Get-TodoPrefix $Config.DoneFile): $doneShown of $tdone tasks shown"
        "total $($todoShown + $doneShown) of $($total + $tdone) tasks shown"
    }
}

function Invoke-TodoListPriority {
    param($Config, [string[]]$Params)
    $pri = 'A-Z'
    $terms = $Params
    if ($Params.Count -ge 1 -and $Params[0] -match '^([A-Za-z]|[A-Za-z]-[A-Za-z]|[A-Z][A-Z-]*[A-Z])$') {
        $pri = $Params[0].ToUpperInvariant()
        $terms = if ($Params.Count -gt 1) { $Params[1..($Params.Count - 1)] } else { @() }
    }
    $lines = Read-TodoFile -Path $Config.TodoFile
    $width = Get-TodoPadding -Lines $lines
    $entries = Get-TodoEntries -Lines $lines
    $result = Format-TodoEntries -Config $Config -Entries $entries -Terms $terms -Width $width -PriorityFilter $pri
    foreach ($l in $result.Lines) { $l }
    if ($Config.Verbose -gt 0) {
        '--'
        "$(Get-TodoPrefix $Config.TodoFile): $($result.Shown) of $($result.Total) tasks shown"
    }
}

function Get-TodoSigilWords {
    <# todo.sh listWordsWithSigil(): unique tokens beginning with the sigil. #>
    param($Config, [string]$Sigil, [string[]]$Terms)

    $file = $Config.TodoFile
    if ($Config.SourceVar) {
        switch -Wildcard ($Config.SourceVar) {
            '*DONE_FILE*' { $file = $Config.DoneFile }
            '*TODO_FILE*' { $file = $Config.TodoFile }
        }
    }
    $found = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in (Read-TodoFile -Path $file)) {
        if (-not (Test-TodoMatch -Text $line -Terms $Terms)) { continue }
        foreach ($token in ($line -split '\s+')) {
            if ($token.Length -lt 2 -or $token[0] -ne $Sigil[0]) { continue }
            $word = $token
            if ($Config.SigilBeforePattern) { $word = $word -replace "^$($Config.SigilBeforePattern)", '' }
            if ($Config.SigilAfterPattern) { $word = $word -replace "$($Config.SigilAfterPattern)`$", '' }
            if ($word -match "^$([regex]::Escape($Sigil))$($Config.SigilValidPattern)$") {
                [void]$found.Add($word)
            }
        }
    }
    foreach ($w in $found) { $w }
}

function Invoke-TodoListAddons {
    param($Config)
    if (-not [System.IO.Directory]::Exists($Config.ActionsDir)) {
        Invoke-TodoDie "TODO: '$($Config.ActionsDir)' does not exist."
    }
    $count = 0
    foreach ($item in [System.IO.Directory]::GetFileSystemEntries($Config.ActionsDir)) {
        $name = [System.IO.Path]::GetFileName($item)
        if ([System.IO.File]::Exists($item)) { $name; $count++ }
        elseif ([System.IO.Directory]::Exists($item) -and [System.IO.File]::Exists((Join-Path $item $name))) { $name; $count++ }
    }
    if ($count -eq 0) {
        Invoke-TodoDie "TODO: '$($Config.ActionsDir)' does not contain valid actions."
    }
    if ($Config.Verbose -gt 1) {
        '--'
        "TODO: $count valid addon actions found."
    }
}

function Get-TodoAddonPath {
    [OutputType([string])]
    param($Config, [string]$Action)
    if (-not [System.IO.Directory]::Exists($Config.ActionsDir)) { return $null }
    foreach ($candidate in @(
            (Join-Path $Config.ActionsDir "$Action.ps1"),
            (Join-Path $Config.ActionsDir $Action),
            (Join-Path $Config.ActionsDir (Join-Path $Action $Action)),
            (Join-Path $Config.ActionsDir (Join-Path $Action "$Action.ps1")))) {
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
    }
    return $null
}

function Invoke-TodoAddon {
    param($Config, [string]$Path, [string[]]$Params)

    # TODO_SH points at the real wrapper so add-ons can re-invoke built-ins via
    # `& $env:TODO_SH command <action> ...` (the module lives in src/, the wrapper
    # is one level up at the repo/install root).
    $todoSh = 'todo.ps1'
    $wrapper = Join-Path $PSScriptRoot '..' 'todo.ps1'
    if ([System.IO.File]::Exists($wrapper)) { $todoSh = (Resolve-Path $wrapper).Path }

    # Expose the standard todo.sh add-on environment, but restore it afterwards
    # so running an add-on never mutates the caller's process environment.
    $exported = @{
        TODO_DIR    = $Config.TodoDir
        TODO_FILE   = $Config.TodoFile
        DONE_FILE   = $Config.DoneFile
        REPORT_FILE = $Config.ReportFile
        TODO_SH     = $todoSh
    }
    $previous = @{}
    foreach ($name in $exported.Keys) {
        $previous[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, $exported[$name])
    }
    try {
        & $Path @Params
    }
    finally {
        foreach ($name in $previous.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

#endregion

#region Git integration ---------------------------------------------------------

# Actions that change files on disk; only these trigger a git sync. Everything
# else (list/help/etc.) is read-only. Includes canonical names and aliases
# because the sync runs in Invoke-Todo against the raw action token.
$script:TodoMutatingActions = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'add', 'a', 'addm', 'addto', 'append', 'app', 'prepend', 'prep', 'replace',
        'del', 'rm', 'depri', 'dp', 'do', 'done', 'pri', 'p', 'move', 'mv',
        'archive', 'deduplicate', 'report', 'start', 'ip'
    ),
    [System.StringComparer]::OrdinalIgnoreCase
)

function Test-TodoMutatingAction {
    <# True if the action name is one that writes to the todo files. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Action)
    return $script:TodoMutatingActions.Contains($Action)
}

function Test-TodoGitAvailable {
    <# True when the git executable is on PATH. Mockable in tests. #>
    [OutputType([bool])]
    param()
    return [bool](Get-Command git -ErrorAction SilentlyContinue)
}

function Invoke-TodoGitCommand {
    <#
        Runs `git -C <TodoDir> <args>` quietly, returning
        @{ ExitCode = <int>; Output = <string> }. Never throws.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$GitArgs)

    try {
        $output = & git -C $Config.TodoDir @GitArgs 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = "$_" }
    }
}

function Test-TodoGitRepo {
    <# True when TodoDir is inside a git work tree. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Config)
    $r = Invoke-TodoGitCommand -Config $Config -GitArgs @('rev-parse', '--is-inside-work-tree')
    return ($r.ExitCode -eq 0 -and $r.Output.Trim() -eq 'true')
}

function Sync-TodoGit {
    <#
        Commits (and optionally pushes) the todo directory after a mutating action.
        No-op unless TODOTXT_GIT is enabled. Auto-initializes the repo (and adds the
        configured remote) when needed. Any failure is reported via Write-TodoWarning
        (which sets exit code 1) but never throws.
    #>
    param([Parameter(Mandatory)]$Config, [string]$Action = '')

    if (-not $Config.Git) { return }
    try {
        if (-not (Test-TodoGitAvailable)) {
            Write-TodoWarning 'TODO: git not found on PATH; skipping git sync.'
            return
        }
        if (-not (Test-TodoGitRepo -Config $Config)) {
            $init = Invoke-TodoGitCommand -Config $Config -GitArgs @('init', '--quiet')
            if ($init.ExitCode -ne 0) {
                Write-TodoWarning "TODO: git init failed: $($init.Output.Trim())"
                return
            }
            if ($Config.GitRemote) {
                Invoke-TodoGitCommand -Config $Config -GitArgs @('remote', 'add', 'origin', $Config.GitRemote) | Out-Null
            }
        }

        $add = Invoke-TodoGitCommand -Config $Config -GitArgs @('add', '-A')
        if ($add.ExitCode -ne 0) {
            Write-TodoWarning "TODO: git add failed: $($add.Output.Trim())"
            return
        }

        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        $message = "todo: $Action $stamp".Trim()
        $commit = Invoke-TodoGitCommand -Config $Config -GitArgs @('commit', '--quiet', '-m', $message)
        if ($commit.ExitCode -ne 0) {
            # "nothing to commit" is normal (a no-op action) and not a failure.
            if ($commit.Output -notmatch 'nothing to commit|no changes added|working tree clean') {
                Write-TodoWarning "TODO: git commit failed: $($commit.Output.Trim())"
            }
            return
        }

        if ($Config.GitRemote) {
            $push = Invoke-TodoGitCommand -Config $Config -GitArgs @('push', '--quiet')
            if ($push.ExitCode -ne 0) {
                Write-TodoWarning "TODO: git push failed: $($push.Output.Trim())"
            }
        }
    }
    catch {
        Write-TodoWarning "TODO: git sync error: $($_.Exception.Message)"
    }
}

#endregion

#region Help / usage / version --------------------------------------------------

function Get-TodoOnelineUsage { 'todo.ps1 [-fhpcnNaAtTvVx] [-@ -+ -P] [-d todo_config] action [task_number] [task_description]' }

function Get-TodoUsage {
    @(
        "Usage: $(Get-TodoOnelineUsage)"
        "Try 'todo.ps1 -h' for more information."
    )
}

function Get-TodoShortHelp {
    @'
  Usage: todo.ps1 [-fhpcnNaAtTvVx] [-@ -+ -P] [-d todo_config] action [task_number] [task_description]

  Actions:
    add|a "THING I NEED TO DO +project @context"
    addm "THINGS I NEED TO DO
          MORE THINGS I NEED TO DO"
    addto DEST "TEXT TO ADD"
    append|app NR "TEXT TO APPEND"
    archive
    command [ACTIONS]
    deduplicate
    del|rm NR [TERM]
    depri|dp NR [NR ...]
    done|do NR [NR ...]
    help [ACTION...]
    list|ls [TERM...]
    listall|lsa [TERM...]
    listaddons
    listcon|lsc [TERM...]
    listfile|lf [SRC [TERM...]]
    listpri|lsp [PRIORITIES] [TERM...]
    listproj|lsprj [TERM...]
    move|mv NR DEST [SRC]
    prepend|prep NR "TEXT TO PREPEND"
    pri|p NR PRIORITY [NR PRIORITY ...]
    replace NR "UPDATED TODO"
    report
    shorthelp
    start|ip NR [NR ...]              (requires TODOTXT_IN_PROGRESS)

  See "help" for more details.
'@ -split "`n"
}

function Get-TodoHelp {
    @'
  Usage: todo.ps1 [-fhpcnNaAtTvVx] [-@ -+ -P] [-d todo_config] action [task_number] [task_description]

  Options:
    -@
        Hide context names in list output. Use twice to show context names.
    -+
        Hide project names in list output. Use twice to show project names.
    -c
        Color mode
    -d CONFIG_FILE
        Use a configuration file other than the defaults.
    -f
        Forces actions without confirmation or interactive input
    -h
        Display a short help message; same as action "shorthelp"
    -p
        Plain mode turns off colors
    -P
        Hide priority labels in list output. Use twice to show priority labels.
    -a
        Don't auto-archive tasks automatically on completion
    -A
        Auto-archive tasks automatically on completion
    -n
        Don't preserve line numbers; automatically remove blank lines on deletion
    -N
        Preserve line numbers
    -t
        Prepend the current date to a task automatically when it's added.
    -T
        Do not prepend the current date to a task automatically when it's added.
    -v
        Verbose mode turns on confirmation messages
    -vv
        Extra verbose mode prints some debugging information
    -V
        Displays version, license and credits
    -x
        Disables the final filter

  Environment variables:
    TODO_DIR                        directory holding todo.txt / done.txt
    TODOTXT_AUTO_ARCHIVE            is same as option -a (0)/-A (1)
    TODOTXT_CFG_FILE=CONFIG_FILE    is same as option -d CONFIG_FILE
    TODOTXT_FORCE=1                 is same as option -f
    TODOTXT_PRESERVE_LINE_NUMBERS   is same as option -n (0)/-N (1)
    TODOTXT_PLAIN                   is same as option -p (1)/-c (0)
    TODOTXT_DATE_ON_ADD             is same as option -t (1)/-T (0)
    TODOTXT_PRIORITY_ON_ADD=pri     default priority A-Z
    TODOTXT_VERBOSE=1               is same as option -v
    TODOTXT_DISABLE_FILTER=1        is same as option -x
    TODOTXT_DEFAULT_ACTION=""       run this when called with no arguments
    TODOTXT_DATE_TAGS=1             tag tasks with added:/completed: dates
    TODOTXT_IN_PROGRESS=1           enable the start|ip action + started: tag
    TODOTXT_GIT=1                   commit (and push) the todo dir after changes
    TODOTXT_GIT_REMOTE=URL          remote to push to when git tracking is on
'@ -split "`n"
}

function Get-TodoVersion {
    @(
        "TODO.TXT Command Line Interface (PowerShell port) v$($script:TodoVersion)"
        ''
        'Homepage: http://todotxt.org/'
        'Code repository: https://github.com/todotxt/todo.txt-cli'
        'License: MIT'
    )
}

#endregion

#region Option parsing & dispatch -----------------------------------------------

function ConvertFrom-TodoArgument {
    <#
        Parses the leading option run. Returns the overrides hashtable, the
        index of the first non-option token, and short-circuit flags.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argv)

    $ovr = @{}
    $idx = 0
    $version = $false
    $shortHelp = $false

    while ($idx -lt $Argv.Count) {
        $tok = $Argv[$idx]
        if ($tok -eq '--') { $idx++; break }
        if ($tok.Length -lt 1 -or $tok[0] -ne '-' -or $tok -eq '-') { break }

        $chars = $tok.Substring(1).ToCharArray()
        $ci = 0
        while ($ci -lt $chars.Count) {
            $c = [string]$chars[$ci]
            switch -CaseSensitive ($c) {
                'f' { $ovr.Force = $true }
                'p' { $ovr.Plain = $true }
                'c' { $ovr.Plain = $false }
                'n' { $ovr.PreserveLineNumbers = $false }
                'N' { $ovr.PreserveLineNumbers = $true }
                'a' { $ovr.AutoArchive = $false }
                'A' { $ovr.AutoArchive = $true }
                't' { $ovr.DateOnAdd = $true }
                'T' { $ovr.DateOnAdd = $false }
                'x' { $ovr.DisableFilter = $true }
                'V' { $version = $true }
                'h' { $shortHelp = $true }
                'v' {
                    if (-not $ovr.ContainsKey('Verbose')) { $ovr.Verbose = 1 }
                    $ovr.Verbose = [int]$ovr.Verbose + 1
                }
                '+' { $ovr.HideProjects = -not [bool]$ovr['HideProjects'] }
                '@' { $ovr.HideContexts = -not [bool]$ovr['HideContexts'] }
                'P' { $ovr.HidePriority = -not [bool]$ovr['HidePriority'] }
                'd' {
                    $rest = if (($ci + 1) -lt $chars.Count) { -join $chars[($ci + 1)..($chars.Count - 1)] } else { '' }
                    if ($rest) { $ovr.ConfigFile = $rest }
                    else { $idx++; $ovr.ConfigFile = $Argv[$idx] }
                    $ci = $chars.Count
                    continue
                }
                default { Invoke-TodoDie ((Get-TodoUsage) -join "`n") }
            }
            $ci++
        }
        $idx++
    }
    return [pscustomobject]@{
        Overrides = $ovr
        Index     = $idx
        Version   = $version
        ShortHelp = $shortHelp
    }
}

function Invoke-TodoAction {
    <# Dispatches a single resolved action against an initialized config. #>
    param($Config, [string]$Action, [string[]]$Params, [switch]$BuiltinOnly)

    # Add-ons override built-ins (todo.sh behaviour): an actions-dir script whose
    # name matches the action runs instead of the built-in. `command <action>`
    # passes -BuiltinOnly and is the escape hatch to force the built-in.
    if (-not $BuiltinOnly) {
        $addon = Get-TodoAddonPath -Config $Config -Action $Action
        if ($addon) { Invoke-TodoAddon -Config $Config -Path $addon -Params $Params; return }
    }

    switch -Regex ($Action) {
        '^(add|a)$' { Invoke-TodoAdd -Config $Config -Params $Params; break }
        '^addm$' { Invoke-TodoAddMultiple -Config $Config -Params $Params; break }
        '^addto$' { Invoke-TodoAddTo -Config $Config -Params $Params; break }
        '^(append|app)$' { Invoke-TodoAppend -Config $Config -Params $Params; break }
        '^archive$' { Invoke-TodoArchive -Config $Config; break }
        '^command$' {
            if ($Params.Count -eq 0) { Invoke-TodoDie ((Get-TodoUsage) -join "`n") }
            Invoke-TodoAction -Config $Config -Action $Params[0] -Params @($Params | Select-Object -Skip 1) -BuiltinOnly
            break
        }
        '^deduplicate$' { Invoke-TodoDeduplicate -Config $Config; break }
        '^(del|rm)$' { Invoke-TodoDelete -Config $Config -Params $Params; break }
        '^(depri|dp)$' { Invoke-TodoDeprioritize -Config $Config -Params $Params; break }
        '^(do|done)$' { Invoke-TodoDone -Config $Config -Params $Params; break }
        '^(start|ip)$' { Invoke-TodoStart -Config $Config -Params $Params; break }
        '^help$' {
            if ($Params.Count -gt 0) { Get-TodoShortHelp } else { Get-TodoHelp }
            break
        }
        '^shorthelp$' { Get-TodoShortHelp; break }
        '^(list|ls)$' { Invoke-TodoList -Config $Config -Terms $Params; break }
        '^(listall|lsa)$' { Invoke-TodoListAll -Config $Config -Terms $Params; break }
        '^listaddons$' { Invoke-TodoListAddons -Config $Config; break }
        '^(listcon|lsc)$' { Get-TodoSigilWords -Config $Config -Sigil '@' -Terms $Params; break }
        '^(listproj|lsprj)$' { Get-TodoSigilWords -Config $Config -Sigil '+' -Terms $Params; break }
        '^(listfile|lf)$' {
            if ($Params.Count -eq 0) {
                if ($Config.Verbose -gt 0) { 'Files in the todo.txt directory:' }
                $names = [System.IO.Directory]::GetFiles($Config.TodoDir, '*.txt') |
                    ForEach-Object { [System.IO.Path]::GetFileName($_) } |
                    Sort-Object -CaseSensitive
                foreach ($n in $names) { $n }
            }
            else {
                Invoke-TodoList -Config $Config -Terms @($Params | Select-Object -Skip 1) -File $Params[0]
            }
            break
        }
        '^(listpri|lsp)$' { Invoke-TodoListPriority -Config $Config -Params $Params; break }
        '^(move|mv)$' { Invoke-TodoMove -Config $Config -Params $Params; break }
        '^(prepend|prep)$' { Invoke-TodoReplaceOrPrepend -Config $Config -Action 'prepend' -Params $Params; break }
        '^(pri|p)$' { Invoke-TodoPrioritize -Config $Config -Params $Params; break }
        '^replace$' { Invoke-TodoReplaceOrPrepend -Config $Config -Action 'replace' -Params $Params; break }
        '^report$' { Invoke-TodoReport -Config $Config; break }
        default {
            # Add-on lookup already happened above; an unknown action is an error.
            Invoke-TodoDie ((Get-TodoUsage) -join "`n")
        }
    }
}

function Invoke-Todo {
    <#
        .SYNOPSIS
            PowerShell port of the todo.txt CLI (todo.sh).
        .PARAMETER Arguments
            The command-line arguments (options, action and parameters).
        .PARAMETER TodoDir
            Convenience override for the todo directory (highest precedence).
        .PARAMETER ConfigFile
            Path to a configuration file (same as -d).
        .EXAMPLE
            Invoke-Todo -Arguments 'add', 'buy milk +groceries'
        .EXAMPLE
            Invoke-Todo -TodoDir /tmp/t -Arguments '-f', 'ls'
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments = @(),
        [string]$TodoDir,
        [string]$ConfigFile
    )

    $script:TodoStatus = 0
    $argv = [string[]]@($Arguments)

    $parsed = ConvertFrom-TodoArgument -Argv $argv
    $ovr = $parsed.Overrides
    if ($parsed.Version) { return Get-TodoVersion }

    if ($parsed.ShortHelp) {
        $action = 'shorthelp'
        $params = @()
    }
    else {
        $rest = @(if ($parsed.Index -lt $argv.Count) { $argv[$parsed.Index..($argv.Count - 1)] } else { @() })
        if ($rest.Count -eq 0) { $action = $null } else { $action = $rest[0] }
        $params = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { @() })
    }

    $cfgFile = if ($ConfigFile) { $ConfigFile } elseif ($ovr.ContainsKey('ConfigFile')) { $ovr.ConfigFile } else { $null }
    if ($ovr.ContainsKey('ConfigFile')) { [void]$ovr.Remove('ConfigFile') }

    $config = New-TodoConfig -ConfigFile $cfgFile -TodoDir $TodoDir -Overrides $ovr

    if (-not $action) {
        if ($config.DefaultAction) {
            $da = $config.DefaultAction -split '\s+'
            $action = $da[0]
            $params = if ($da.Count -gt 1) { $da[1..($da.Count - 1)] } else { @() }
        }
        else {
            return Get-TodoUsage
        }
    }

    Initialize-TodoFiles -Config $config
    $output = Invoke-TodoAction -Config $config -Action $action -Params ([string[]]$params)

    # Git sync after a successful mutating action. Resolve `command <action>` to
    # its inner action, and conservatively sync for anything that isn't read-only
    # (covers add-ons, which may edit the files).
    if ($config.Git) {
        $effective = if ($action -eq 'command' -and $params.Count -gt 0) { $params[0] } else { $action }
        $readOnly = @('list', 'ls', 'listall', 'lsa', 'listpri', 'lsp', 'listproj', 'lsprj',
            'listcon', 'lsc', 'listfile', 'lf', 'listaddons', 'help', 'shorthelp')
        if ($effective -notin $readOnly) {
            Sync-TodoGit -Config $config -Action $effective
        }
    }

    $output
}

#endregion

Export-ModuleMember -Function @(
    'Invoke-Todo', 'Get-TodoExitCode',
    'Read-TodoFile', 'Write-TodoFile', 'Get-TodoPrefix', 'Get-TodoPriority',
    'ConvertTo-TodoCleanInput', 'ConvertTo-TodoUppercasePriority', 'Split-TodoPrefix', 'Split-TodoMarker',
    'ConvertFrom-TodoConfig', 'New-TodoConfig', 'Initialize-TodoFiles',
    'Get-TodoEntries', 'Test-TodoMatch', 'Format-TodoDisplayLine', 'Format-TodoEntries',
    'Get-TodoPadding', 'Get-TodoColorMap', 'Remove-TodoBlankLines',
    'Add-TodoTask', 'Get-TodoTaskText', 'Get-TodoSigilWords', 'Get-TodoDate',
    'Invoke-TodoAdd', 'Invoke-TodoAddMultiple', 'Invoke-TodoAddTo', 'Invoke-TodoAppend',
    'Invoke-TodoArchive', 'Invoke-TodoDeduplicate', 'Invoke-TodoDelete', 'Invoke-TodoDeprioritize',
    'Invoke-TodoDone', 'Invoke-TodoStart', 'Invoke-TodoList', 'Invoke-TodoListAll', 'Invoke-TodoListPriority',
    'Invoke-TodoListAddons', 'Invoke-TodoMove', 'Invoke-TodoPrioritize', 'Invoke-TodoReplaceOrPrepend',
    'Invoke-TodoReport', 'Invoke-TodoAction', 'ConvertFrom-TodoArgument',
    'Get-TodoUsage', 'Get-TodoShortHelp', 'Get-TodoHelp', 'Get-TodoVersion',
    'Sync-TodoGit', 'Test-TodoGitAvailable', 'Test-TodoGitRepo', 'Invoke-TodoGitCommand',
    'Test-TodoMutatingAction'
)
