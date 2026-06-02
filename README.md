# todo.txt-powershell

A PowerShell port of the [todo.txt CLI](https://github.com/todotxt/todo.txt-cli)
(`todo.sh`). It implements the same actions, options, configuration and on-disk
[todo.txt format](https://github.com/todotxt/todo.txt), and is validated for
byte-for-byte output and file parity against the original `todo.sh`.

Where it pays off, the implementation leans on **.NET BCL types**
(`System.IO.File`, `System.Text.StringBuilder`,
`System.Collections.Generic.List<T>`, `System.Text.RegularExpressions.Regex`)
instead of slower pure-PowerShell idioms.

* Cross-platform: PowerShell 7+ on Linux, macOS and Windows.
* No external dependencies at runtime.
* Optional extras: in-progress tracking, lifecycle date tags, and git syncing.
* A full [Pester](https://pester.dev) 5 test suite (105 tests).

## Requirements

* [PowerShell 7.0+](https://learn.microsoft.com/powershell/) (`pwsh`)
* [Pester 5+](https://pester.dev) — for running the tests only.

## Install

The interactive installer fetches the project, creates your todo directory,
writes a config file, and (optionally) registers a `todo` command in your
PowerShell profile:

```powershell
# Interactive
iwr https://raw.githubusercontent.com/citizen-123/todo.txt-powershell/main/install.ps1 | iex

# Non-interactive (accept defaults). A piped script can't take parameters, so
# set the env var first:
$env:TODO_INSTALL_DEFAULT = '1'; iwr <url> | iex

# Or pass flags via a script block:
& ([scriptblock]::Create((iwr <url>).Content)) -Default
```

Local checkout: `./install.ps1` (interactive) or `./install.ps1 -Default`.
Useful flags: `-InstallDir`, `-TodoDir`, `-Force`. The installer prompts for git
tracking, in-progress tracking, date tags, and the profile alias; `-Default`
skips the prompts (git/in-progress/date-tags off, alias registered).

## Quick start

```powershell
# Run directly via the wrapper script:
./todo.ps1 add "buy milk +groceries @store"
./todo.ps1 add "(A) call mom @phone"
./todo.ps1 ls
./todo.ps1 do 1
./todo.ps1 ls

# Or import the module and use the cmdlet:
Import-Module ./src/TodoTxt.psd1
Invoke-Todo -Arguments 'add', 'write the report +work'
Invoke-Todo -Arguments 'ls'
```

By default tasks live in `~/.todo/todo.txt` (override with `TODO_DIR`, a config
file, or the `-d` option). Completed tasks are archived to `done.txt`.

### Add the wrapper to your PATH (optional)

```powershell
# PowerShell profile
Set-Alias todo (Resolve-Path ./todo.ps1)
# or on Linux/macOS, symlink it onto your PATH:
#   ln -s "$PWD/todo.ps1" ~/.local/bin/todo
```

## Actions

```
add|a "THING I NEED TO DO +project @context"
addm "MULTIPLE\nTASKS"
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
start|ip NR [NR ...]            (requires TODOTXT_IN_PROGRESS)
```

## Options

| Option | Meaning |
| ------ | ------- |
| `-@` / `-@@` | Hide / show context names in list output |
| `-+` / `-++` | Hide / show project names in list output |
| `-c` | Color mode |
| `-p` | Plain mode (no color) |
| `-P` / `-PP` | Hide / show priority labels in list output |
| `-d CONFIG_FILE` | Use an alternate configuration file |
| `-f` | Force (no confirmation / interactive input) |
| `-h` | Short help (same as `shorthelp`) |
| `-a` / `-A` | Disable / enable auto-archive on completion |
| `-n` / `-N` | Don't preserve / preserve line numbers on deletion |
| `-t` / `-T` | Enable / disable prepending the creation date on add |
| `-v` / `-vv` | Verbose / extra-verbose |
| `-V` | Version |
| `-x` | Disable the final filter |

Run `./todo.ps1 help` for the full reference.

## Configuration

Configuration is layered, lowest to highest precedence:

1. Built-in defaults
2. Environment variables (`TODO_DIR`, `TODOTXT_*`, …)
3. A configuration file
4. Command-line options

Configuration files use the same `export VAR=value` syntax as the original
`todo.cfg` (including `$VAR` expansion and the standard ANSI color names), so
existing configurations are largely compatible. See
[`todo.cfg.example`](./todo.cfg.example).

Config file search order (first existing one wins, unless `-d` /
`TODOTXT_CFG_FILE` is given):

```
$HOME/.todo/config
$HOME/todo.cfg
$HOME/.todo.cfg
${XDG_CONFIG_HOME:-$HOME/.config}/todo/config
```

### Supported environment variables

`TODO_DIR`, `TODO_FILE`, `DONE_FILE`, `REPORT_FILE`, `TODO_ACTIONS_DIR`,
`TODOTXT_CFG_FILE`, `TODOTXT_AUTO_ARCHIVE`, `TODOTXT_DATE_ON_ADD`,
`TODOTXT_PRIORITY_ON_ADD`, `TODOTXT_PRESERVE_LINE_NUMBERS`, `TODOTXT_PLAIN`,
`TODOTXT_FORCE`, `TODOTXT_VERBOSE`, `TODOTXT_DISABLE_FILTER`,
`TODOTXT_DEFAULT_ACTION`, `TODOTXT_SOURCEVAR`, `TODOTXT_SIGIL_BEFORE_PATTERN`,
`TODOTXT_SIGIL_VALID_PATTERN`, `TODOTXT_SIGIL_AFTER_PATTERN`,
`TODOTXT_DATE_TAGS`, `TODOTXT_IN_PROGRESS`, `TODOTXT_GIT`, `TODOTXT_GIT_REMOTE`.

## In-progress tracking & date tags

Two optional, independent extensions (both off by default):

* **`TODOTXT_DATE_TAGS=1`** appends a `key:value` tag to tasks: `added:<date>` on
  `add`, and `completed:<date>` on `do`.
* **`TODOTXT_IN_PROGRESS=1`** enables the `start` (alias `ip`) action, which marks
  a task in-progress by prefixing an `i ` status marker (analogous to the `x `
  done marker) and appending `started:<date>`. The task's priority is preserved:

  ```
  todo add "(A) write the report"      # (A) write the report
  todo start 1                         # i (A) write the report started:2026-06-02
  todo do 1                            # x 2026-06-02 write the report started:... completed:...
  ```

  A leading `x `/`i ` status marker is transparent to priority, sorting and
  coloring, so an in-progress `(A)` task still sorts among its priority peers and
  `pri`/`depri` keep working. `archive` moves only completed (`x `) tasks; `i `
  tasks stay put. In-progress tasks get their own color (`COLOR_INPROGRESS`).

## Git tracking

Set **`TODOTXT_GIT=1`** to version your todo directory automatically. After any
file-changing action the CLI runs `git add`/`git commit` in `TODO_DIR`, and
`git push` when **`TODOTXT_GIT_REMOTE`** is set. The repository is auto-initialized
(and the remote added) on first use. Read-only actions (`ls`, `listall`, …) never
commit. If `git` is missing or a git step fails, the command still succeeds but a
warning is printed and the exit code is `1` — your tasks are never lost to a git
error.

## Add-on actions

Add-ons live in the actions directory (default `$TODO_DIR/actions`, or
`$TODO_ACTIONS_DIR`) and mirror todo.sh: a script whose name matches an action
**overrides** the built-in of the same name; any other name adds a brand-new
command. PowerShell (`.ps1`) and native executables are supported, and receive
the standard `TODO_DIR`, `TODO_FILE`, `DONE_FILE`, `REPORT_FILE` and `TODO_SH`
environment variables (restored afterwards, so add-ons never pollute your
session). `TODO_SH` points at the real wrapper, so an add-on can re-invoke a
built-in:

```powershell
# actions/hello.ps1 — a new command
param() "hi, you have $((Get-Content $env:TODO_FILE).Count) tasks"

# actions/do.ps1 — override `do`, then call the built-in via the escape hatch
param() & $env:TODO_SH command do @args
```

Use **`command <action>`** to force the built-in even when an override exists.

## Differences from `todo.sh`

* Search `TERM`s use **.NET regular expressions** (case-insensitive) rather than
  POSIX `grep` BRE.
* `del NR TERM` matches the `TERM` **literally** (so `del 1 +project` works),
  matching the practical behaviour of the original's BRE.
* The default `TODO_DIR` is `~/.todo`; the script runs without a config file.
* `TODOTXT_SORT_COMMAND` / `TODOTXT_FINAL_FILTER` (arbitrary shell pipelines)
  are not supported; list sorting is implemented natively (ordinal,
  case-insensitive, matching `LC_COLLATE=C sort -f -k2`).
* A leading status marker (`x `/`i `) is skipped when computing the sort key, so
  completed and in-progress tasks sort by their underlying text/priority rather
  than clustering under the marker character.
* Adds the `start`/`ip` action, the `added:`/`started:`/`completed:` date tags,
  and git tracking — all opt-in (see above) and absent from upstream `todo.sh`.

## Project layout

```
todo.ps1                 # CLI entry point (thin wrapper)
install.ps1              # interactive installer (iwr | iex)
src/TodoTxt.psd1         # module manifest
src/TodoTxt.psm1         # implementation
tests/TodoTxt.Tests.ps1  # Pester suite
tests/Install.Tests.ps1  # installer helper tests
tests/Invoke-Tests.ps1   # test runner
todo.cfg.example         # sample configuration
```

## Running the tests

```powershell
# Install Pester if needed:
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck

# Run the suite:
pwsh -File tests/Invoke-Tests.ps1
# CI mode (also writes tests/testresults.xml):
pwsh -File tests/Invoke-Tests.ps1 -CI
```

## License

MIT — see [LICENSE](./LICENSE).
