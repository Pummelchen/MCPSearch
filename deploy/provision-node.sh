#!/bin/bash
# Provision one cluster node with a native SearXNG.
#
# Runs on the node, piped over ssh:
#
# Keep the password out of every argv. As `SUDO_PASSWORD=... bash -s` the value is in the argv of
# the shell `sshd` starts on the node — readable there with `ps` — and in the local `ssh` argv, and
# it stays in the environment inherited by every child. Read it from a 600 file on
# the node instead: the command string below mentions only the file, and `VAR="$(cat file)" cmd`
# puts the value in the environment rather than in an argument list.
#
#   ssh node1@node1.local 'SUDO_PASSWORD="$(cat ~/.mcps-sudo)" bash -s' < deploy/provision-node.sh
#
# This script is deliberately thin. The SearXNG install itself lives in `deploy/install.sh` — the
# same path a workstation install uses, and the one that is exercised — so this only does what a
# headless node needs *first* (sudo, Homebrew, a Python the native install accepts), fetches the
# repository, and runs that installer. One implementation, one set of guarantees.
#
# It used to build a Colima container with a digest-pinned image and a canary swap. The fleet runs
# native now, so that produced something other than what is running — and a provisioning script
# that disagrees with the deployment is worse than no script, because it looks authoritative.
#
# Options are environment variables, because the script arrives on stdin:
#
#   SUDO_PASSWORD   sudo password, when the account has no passwordless sudo
#   SEARXNG_PORT    port to serve on                   (default 8888)
#   SEARXNG_BIND    interface to bind                  (default 0.0.0.0: nodes serve the tailnet)
#   MCPS_REPO       repository URL                     (default the public GitHub repository)
#   MCPS_REF        branch, tag or SHA to install      (default main)
#   MCPS_REPO_DIR   where to keep the checkout         (default ~/mcps-install)
#   FORCE=1         stop a running instance so the installer reinstalls instead of adopting it
#
# Idempotent: re-running converges. An instance that is already serving is adopted and verified
# rather than rebuilt, so this is safe to run against a healthy node.

set -uo pipefail

NODE_NAME="$(hostname -s)"
LOG_PREFIX="[$(date +%H:%M:%S) $NODE_NAME]"

say() { echo "$LOG_PREFIX $*"; }
fail() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 1; }

SEARXNG_PORT="${SEARXNG_PORT:-8888}"
SEARXNG_BIND="${SEARXNG_BIND:-0.0.0.0}"
MCPS_REPO="${MCPS_REPO:-https://github.com/Pummelchen/MCPSearch}"
MCPS_REF="${MCPS_REF:-main}"
MCPS_REPO_DIR="${MCPS_REPO_DIR:-${HOME}/mcps-install}"
FORCE="${FORCE:-0}"

# ---------------------------------------------------------------------------
# Private scratch space
# ---------------------------------------------------------------------------
# Every log below used to be written to a fixed name under the shared, world-writable /tmp. A
# plain `>` follows a symlink planted there, so a local user could make this run — an account
# that also has cached sudo — truncate or clobber any file the provisioning account can write.
# One unpredictable directory, created 0700, holds every artefact of this run instead.
#
# Extracted as a function so the guard can be exercised without provisioning a node.
make_provision_tmp() {
    local dir
    dir="$(mktemp -d)" || return 1
    install -d -m 700 "${dir}" || return 1
    printf '%s\n' "${dir}"
}

PROVISION_TMP="$(make_provision_tmp)" \
    || fail "could not create a private temporary directory for the provisioning logs"

# Remove the directory however the script ends — `fail` exits, so the EXIT trap covers the failure
# path as well as the success one. On a failed run the log `fail` just pointed at is the
# diagnostic and the directory is about to go, so its tail is shown first; bounded so a chatty
# install cannot bury the real error. The removal itself is reported rather than fatal: this runs
# while the script is already exiting, so `fail` here would recurse.
cleanup_provision_tmp() {
    local status="$1" log
    [ -n "${PROVISION_TMP:-}" ] || return 0
    if [ "${status}" -ne 0 ]; then
        for log in "${PROVISION_TMP}"/*.log; do
            [ -f "${log}" ] || continue
            echo "--- ${log} (last 40 lines) ---" >&2
            tail -n 40 "${log}" >&2
        done
    fi
    rm -rf "${PROVISION_TMP}" \
        || say "could not remove the private temporary directory ${PROVISION_TMP}"
}
trap 'cleanup_provision_tmp $?' EXIT

# ---------------------------------------------------------------------------
# 0. sudo
# ---------------------------------------------------------------------------
# An ssh command runs a non-login, non-interactive shell: no TTY, so sudo cannot prompt. Cache
# the credential up front from SUDO_PASSWORD when the account has no passwordless sudo, then the
# rest of this script can use sudo normally.
if ! sudo -n true 2>/dev/null; then
    if [ -n "${SUDO_PASSWORD:-}" ]; then
        say "caching sudo credential"
        printf '%s\n' "$SUDO_PASSWORD" | sudo -S -v 2>/dev/null \
            || fail "sudo rejected the supplied password"
    else
        fail "sudo needs a password: re-run with the SUDO_PASSWORD environment variable set"
    fi
fi
sudo -n true 2>/dev/null || fail "sudo is not usable"
say "sudo available"

# ---------------------------------------------------------------------------
# 1. Homebrew
# ---------------------------------------------------------------------------
# A non-login shell does not apply Homebrew's shellenv, so `command -v brew` reports "not found"
# even when Homebrew is installed. Check the known prefixes first, otherwise a working
# installation gets needlessly reinstalled.
for prefix in /opt/homebrew /usr/local; do
    if [ -x "${prefix}/bin/brew" ]; then
        eval "$("${prefix}/bin/brew" shellenv)"
        break
    fi
done

if ! command -v brew >/dev/null 2>&1; then
    say "installing Homebrew (non-interactive)"
    # Downloaded to a file and checked against a pinned digest instead of being piped into a
    # shell. A pipe runs whatever arrived — a truncated download, a proxy's error page — and
    # nothing ties the bytes to a reviewed script. The digest below is the whole of that tie, so
    # when upstream changes this stops with instructions rather than running something new.
    HOMEBREW_INSTALLER_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
    HOMEBREW_INSTALLER_SHA256="25548e1da7930c1563dbbe2cb05834a4131c4da09234540b6fdac812fda3c287"
    installer="$(mktemp -t homebrew-install)"
    if ! curl -fsSL "${HOMEBREW_INSTALLER_URL}" -o "${installer}"; then
        rm -f "${installer}"
        fail "could not download the Homebrew installer"
    fi
    actual="$(shasum -a 256 "${installer}" | awk '{print $1}')"
    if [ "${actual}" != "${HOMEBREW_INSTALLER_SHA256}" ]; then
        rm -f "${installer}"
        fail "Homebrew installer digest changed (expected ${HOMEBREW_INSTALLER_SHA256}, got ${actual}); review ${HOMEBREW_INSTALLER_URL} and update the pin in this script"
    fi
    # NONINTERACTIVE avoids the "press RETURN" prompt; sudo is already cached above.
    NONINTERACTIVE=1 /bin/bash "${installer}" > "${PROVISION_TMP}/brew-install.log" 2>&1
    install_status=$?
    rm -f "${installer}"
    [ "${install_status}" -eq 0 ] || fail "Homebrew install failed; see ${PROVISION_TMP}/brew-install.log"
    for prefix in /opt/homebrew /usr/local; do
        [ -x "${prefix}/bin/brew" ] && eval "$("${prefix}/bin/brew" shellenv)" && break
    done
fi

command -v brew >/dev/null 2>&1 || fail "brew not available after install attempt"
say "brew ready: $(brew --version | head -1)"

# Persist the environment for future interactive logins, once.
if ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
    printf '\neval "$(%s/bin/brew shellenv)"\n' "$(brew --prefix)" >> "${HOME}/.zprofile"
fi

# ---------------------------------------------------------------------------
# 2. git, and a Python the native install accepts
# ---------------------------------------------------------------------------
# The native path clones SearXNG with git and builds it inside a virtualenv. It accepts
# Python 3.11–3.13 and refuses 3.14, because SearXNG's Rust-backed dependencies publish no wheels
# for it yet — a node with only the system Python would fail deep inside pip, so it is checked
# here, where the fix is one brew command.
if ! command -v git >/dev/null 2>&1; then
    say "installing git"
    brew install git > "${PROVISION_TMP}/brew-pkgs.log" 2>&1 \
        || fail "could not install git; see ${PROVISION_TMP}/brew-pkgs.log"
fi
say "git: $(git --version)"

find_python() {
    local candidate
    for candidate in python3.13 python3.12 python3.11; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

PYTHON="$(find_python)" || PYTHON=""
if [ -z "${PYTHON}" ]; then
    say "installing python@3.13 (the native build needs 3.11-3.13 and the system python is not one)"
    brew install python@3.13 > "${PROVISION_TMP}/brew-pkgs.log" 2>&1 \
        || fail "could not install python@3.13; see ${PROVISION_TMP}/brew-pkgs.log"
    PYTHON="$(find_python)" || PYTHON=""
fi
[ -n "${PYTHON}" ] || fail "no Python 3.11-3.13 on PATH, and installing python@3.13 did not provide one"
say "python: $("${PYTHON}" --version 2>&1) (${PYTHON})"

# ---------------------------------------------------------------------------
# 3. The repository
# ---------------------------------------------------------------------------
# Fetched rather than embedded: the installer is the single implementation, and copying its steps
# in here is how the two drift apart — which is exactly the state this script was in.
if [ ! -d "${MCPS_REPO_DIR}" ]; then
    mkdir -p "${MCPS_REPO_DIR}" || fail "could not create ${MCPS_REPO_DIR}"
fi
if [ ! -d "${MCPS_REPO_DIR}/.git" ]; then
    git init -q "${MCPS_REPO_DIR}" || fail "could not initialise a repository in ${MCPS_REPO_DIR}"
fi
# set-url first: a checkout left by an earlier run may point at a different remote, and silently
# fetching from the old one would install something other than what was asked for.
git -C "${MCPS_REPO_DIR}" remote set-url origin "${MCPS_REPO}" 2>/dev/null \
    || git -C "${MCPS_REPO_DIR}" remote add origin "${MCPS_REPO}" \
    || fail "could not configure the origin remote"

say "fetching ${MCPS_REF} from ${MCPS_REPO}"
git -C "${MCPS_REPO_DIR}" fetch -q --depth 1 origin "${MCPS_REF}" \
    || fail "could not fetch ${MCPS_REF} — check the ref and the node's access to ${MCPS_REPO}"
git -C "${MCPS_REPO_DIR}" checkout -q --force FETCH_HEAD \
    || fail "could not check out ${MCPS_REF}"

INSTALLER="${MCPS_REPO_DIR}/deploy/install.sh"
[ -f "${INSTALLER}" ] \
    || fail "${INSTALLER} is missing after checkout; refusing to guess at an install"
chmod +x "${INSTALLER}" 2>/dev/null
[ -x "${INSTALLER}" ] || fail "${INSTALLER} is not executable"
say "source: $(git -C "${MCPS_REPO_DIR}" rev-parse --short HEAD) $(git -C "${MCPS_REPO_DIR}" log -1 --format=%s | cut -c1-58)"

# ---------------------------------------------------------------------------
# 4. Install
# ---------------------------------------------------------------------------
# A working instance on the target port is adopted rather than rebuilt, which is what makes this
# idempotent. FORCE is for when the point is to replace it.
if [ "${FORCE}" = "1" ]; then
    say "FORCE=1: stopping any running instance so the installer reinstalls rather than adopts it"
    launchctl unload "${HOME}/Library/LaunchAgents/local.mcps.searxng.plist" 2>/dev/null
fi

say "installing SearXNG natively on ${SEARXNG_BIND}:${SEARXNG_PORT}"
# --searxng-only because a node is search infrastructure: this needs neither a Swift toolchain nor
# a published release, and the installer's mandatory-SearXNG gate still applies.
"${INSTALLER}" --method native --port "${SEARXNG_PORT}" --bind "${SEARXNG_BIND}" --searxng-only \
    || fail "SearXNG did not install and verify; the node is not provisioned"

# ---------------------------------------------------------------------------
# 5. Report an address that exists
# ---------------------------------------------------------------------------
# Printing a hostname as if it were a URL sent operators hunting for a network fault that was
# really a missing Tailscale install.
#
# Resolve the CLI instead of assuming where it was installed. `command -v` is tried first because
# the Homebrew section above already applied this node's `shellenv`, so it finds the formula from
# whichever prefix the node actually uses — /opt/homebrew/bin on Apple Silicon, /usr/local/bin on
# Intel. The app bundle is not on PATH and its binary is named `Tailscale`, unlike the formula's
# `tailscale`, so those known paths are tried after `command -v`.
tailscale_cli() {
    local found candidate
    found="$(command -v tailscale 2>/dev/null)"
    if [ -n "${found}" ]; then
        printf '%s\n' "${found}"
        return 0
    fi
    for candidate in "$@"; do
        if [ -x "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

TAILSCALE_CLI="$(tailscale_cli \
    /opt/homebrew/bin/tailscale \
    /usr/local/bin/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale)"
TAILSCALE_IP=""
if [ -n "${TAILSCALE_CLI}" ]; then
    TAILSCALE_IP="$("${TAILSCALE_CLI}" ip -4 2>/dev/null | head -1)"
fi

say "runtime: native, launchd label local.mcps.searxng"
if [ -n "$TAILSCALE_IP" ]; then
    say "READY  searxng http://${TAILSCALE_IP}:${SEARXNG_PORT} (Tailscale)"
else
    LAN_IP="$(ipconfig getifaddr en0 2>/dev/null)"
    if [ -n "$LAN_IP" ]; then
        say "READY  searxng http://${LAN_IP}:${SEARXNG_PORT} (LAN fallback)"
        say "       tailscale was not found, so this address may change and is not how the"
        say "       monitor expects to reach the node"
    else
        say "searxng is listening on port ${SEARXNG_PORT}, but neither tailscale nor a LAN"
        say "address could be determined; set SEARXNG_BASE_URL to http://<node>:${SEARXNG_PORT}"
    fi
fi

# The installer verified a real query before this point, so this is a state report rather than a
# second check. It reads the launchd job because the job is what survives a reboot.
# Deliberately not `grep -q`: grep exits at the first match, SIGPIPEs the producer, and `pipefail` turns the
# pipeline into 141 — so a match reads as a failure.
# Reading all the input keeps the producer alive and the status honest.
if launchctl list 2>/dev/null | grep 'local\.mcps\.searxng' >/dev/null; then
    say "launchd: loaded (restarts on crash and at login)"
else
    say "WARNING launchd job local.mcps.searxng is not loaded; the instance will not survive a reboot"
fi
exit 0
