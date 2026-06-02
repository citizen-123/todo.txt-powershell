#!/usr/bin/env bash
#
# Best-effort environment setup for Claude Code web sessions (and CI shells).
#
# Ensures PowerShell 7 (`pwsh`) and Pester 5 are available so the test suite
# can run. Idempotent: it skips anything already installed. Never fails the
# session — every step is guarded and logs to stderr on error.
set -u

PWSH_VERSION="7.4.6"
PESTER_VERSION="5.7.1"

log() { printf '[setup] %s\n' "$*"; }

install_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then
        log "pwsh already installed ($(pwsh --version 2>/dev/null))"
        return 0
    fi
    if ! command -v dpkg >/dev/null 2>&1; then
        log "dpkg not available; cannot install pwsh automatically"
        return 1
    fi
    local arch deb url tmp
    arch="$(uname -m)"
    case "$arch" in
        x86_64) deb="powershell_${PWSH_VERSION}-1.deb_amd64.deb" ;;
        aarch64|arm64) deb="powershell_${PWSH_VERSION}-1.deb_arm64.deb" ;;
        *) log "unsupported arch $arch"; return 1 ;;
    esac
    url="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/${deb}"
    tmp="$(mktemp -d)"
    log "downloading PowerShell ${PWSH_VERSION}..."
    if ! curl -fsSL "$url" -o "$tmp/pwsh.deb"; then
        log "failed to download pwsh"; return 1
    fi
    log "installing PowerShell..."
    dpkg -i "$tmp/pwsh.deb" >/dev/null 2>&1 || apt-get install -f -y >/dev/null 2>&1
    rm -rf "$tmp"
    command -v pwsh >/dev/null 2>&1
}

install_pester() {
    command -v pwsh >/dev/null 2>&1 || return 1
    if pwsh -NoProfile -Command "if (Get-Module -ListAvailable Pester | Where-Object Version -ge ([version]'5.0.0')) { exit 0 } else { exit 1 }" 2>/dev/null; then
        log "Pester 5+ already installed"
        return 0
    fi
    # The PowerShell Gallery is frequently unreachable from sandboxes; fetch the
    # module straight from nuget.org instead and unpack it into the module path.
    local dir tmp
    dir="$HOME/.local/share/powershell/Modules/Pester/${PESTER_VERSION}"
    if [ -f "$dir/Pester.psd1" ]; then log "Pester present at $dir"; return 0; fi
    tmp="$(mktemp -d)"
    log "downloading Pester ${PESTER_VERSION} from nuget.org..."
    if ! curl -fsSL "https://api.nuget.org/v3-flatcontainer/pester/${PESTER_VERSION}/pester.${PESTER_VERSION}.nupkg" -o "$tmp/pester.nupkg"; then
        log "failed to download Pester"; rm -rf "$tmp"; return 1
    fi
    mkdir -p "$dir"
    ( cd "$dir" && unzip -oq "$tmp/pester.nupkg" 2>/dev/null )
    # The nupkg ships the module under tools/; flatten it into the version dir.
    if [ -f "$dir/tools/Pester.psd1" ]; then
        ( shopt -s dotglob; mv "$dir"/tools/* "$dir"/ )
        rmdir "$dir/tools" 2>/dev/null || true
    fi
    rm -f "$dir/[Content_Types].xml" "$dir/.signature.p7s" "$dir/Pester.nuspec" \
          "$dir/VERIFICATION.txt" "$dir"/chocolatey*.ps1 2>/dev/null || true
    rm -rf "$tmp"
    [ -f "$dir/Pester.psd1" ]
}

install_pwsh   || log "PowerShell install skipped/failed (continuing)"
install_pester || log "Pester install skipped/failed (continuing)"
log "done"
exit 0
