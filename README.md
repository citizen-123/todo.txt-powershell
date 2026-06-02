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
* A full [Pester](https://pester.dev) 5 test suite (73 tests).

## Requirements

* [PowerShell 7.0+](https://learn.microsoft.com/powershell/) (`pwsh`)
* [Pester 5+](https://pester.dev) — for running the tests only.

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
`TODOTXT_SIGIL_VALID_PATTERN`, `TODOTXT_SIGIL_AFTER_PATTERN`.

## Add-on actions

Unknown actions are resolved against the actions directory (default
`$TODO_DIR/actions`, or `$TODO_ACTIONS_DIR`). PowerShell (`.ps1`) and native
executable add-ons are supported and receive the standard `TODO_DIR`,
`TODO_FILE`, `DONE_FILE`, `REPORT_FILE` environment variables (which are
restored afterwards, so add-ons never pollute your session).

## Differences from `todo.sh`

* Search `TERM`s use **.NET regular expressions** (case-insensitive) rather than
  POSIX `grep` BRE.
* `del NR TERM` matches the `TERM` **literally** (so `del 1 +project` works),
  matching the practical behaviour of the original's BRE.
* The default `TODO_DIR` is `~/.todo`; the script runs without a config file.
* `TODOTXT_SORT_COMMAND` / `TODOTXT_FINAL_FILTER` (arbitrary shell pipelines)
  are not supported; list sorting is implemented natively (ordinal,
  case-insensitive, matching `LC_COLLATE=C sort -f -k2`).

## Project layout

```
todo.ps1                 # CLI entry point (thin wrapper)
src/TodoTxt.psd1         # module manifest
src/TodoTxt.psm1         # implementation
tests/TodoTxt.Tests.ps1  # Pester suite
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
