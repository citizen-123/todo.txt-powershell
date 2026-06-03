# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-06-03

### Added
- **Due / threshold / recurrence dates** (todo.txt `key:value` conventions):
  - `agenda` action (alias `due`) lists undone `due:` tasks, optionally within an
    `N`-day horizon, sorted by date.
  - `TODOTXT_HIDE_FUTURE_TASKS` hides tasks whose `t:` (threshold) date is in the
    future from `ls`/`lsa`/`listpri` (opt-in).
  - `TODOTXT_RECURRENCE` respawns the next occurrence of a `rec:`-tagged task when
    it is completed, advancing `due:`/`t:` (strict `rec:+…` advances from the
    task's own due date) (opt-in).
  - New helpers: `Get-TodoTag`, `Set-TodoTag`, `Add-TodoDateInterval`,
    `ConvertTo-TodoDate`, `New-TodoRecurrence`.
- **Tab completion**: `Register-TodoArgumentCompleter` completes action names and
  `+project` / `@context` tokens from the live file; the installer can wire it
  into your profile. Backed by the pure `Get-TodoCompletion` / `Get-TodoSigilSet`.
- **CI tooling**: PSScriptAnalyzer config + `tests/Invoke-Lint.ps1` and a lint job;
  Pester code-coverage (JaCoCo) under `Invoke-Tests.ps1 -CI`; a dormant
  `publish.yml` for PowerShell Gallery releases (gated on a `PSGALLERY_API_KEY`
  secret + a `vX.Y.Z` tag).

### Changed
- **Sort parity restored**: completed (`x `) tasks once again sort lexically like
  `todo.sh`; only in-progress (`i `) tasks skip their marker in the sort key.

## [1.0.0] - 2026-06-02

### Added
- Initial PowerShell port of the todo.txt CLI (`todo.sh`): all core actions,
  options, configuration, colorized listing, and add-on actions, validated for
  output/file parity against the original.
- In-progress tracking (`start`/`ip` + `i ` marker, `TODOTXT_IN_PROGRESS`).
- Lifecycle date tags `added:` / `completed:` (`TODOTXT_DATE_TAGS`).
- Optional git tracking of the todo directory (`TODOTXT_GIT` / `TODOTXT_GIT_REMOTE`).
- Add-ons that override built-ins (with `command <action>` as the escape hatch).
- Interactive installer (`install.ps1`) for `iwr | iex`.

[1.1.0]: https://github.com/citizen-123/todo.txt-powershell/releases/tag/v1.1.0
[1.0.0]: https://github.com/citizen-123/todo.txt-powershell/releases/tag/v1.0.0
