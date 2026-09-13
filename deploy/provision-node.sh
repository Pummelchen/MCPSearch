#!/bin/bash
# Provision one node with a container runtime and a SearXNG instance.
#
# Runs on the node. Idempotent: safe to re-run, which matters because Homebrew and
# Colima installs can fail partway on a headless machine.
#
# Docker Desktop is deliberately not used: it requires a GUI session. Colima is a
# headless container runtime for macOS with a docker-compatible CLI, which is what a
# screen-less Mac Mini needs.
set -uo pipefail

NODE_NAME="$(hostname -s)"
LOG_PREFIX="[$(date +%H:%M:%S) $NODE_NAME]"
say() { echo "$LOG_PREFIX $*"; }
fail() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 1; }

# Install the generated key into the rendered settings file, and prove it landed.
#
# Every other mutation in this script carries a `|| fail`, and this one did not: if `sed` failed,
# the container started with the literal, tracked, publicly known placeholder as its signing key
# and the canary still answered JSON, so the run reported success (ledger B17). Extracted as a
# function so the guard can be exercised without provisioning a node.
install_secret_key() {
    local settings_file="$1"
    local key="$2"
    # The settings file is created by a plain redirect, so under the default umask 022 it is
    # 0644, and the substitution below copies the same secret the 0600 key file holds into it.
    # BSD `sed -i` preserves the original file's mode rather than applying the umask (measured:
    # a 0600 input stays 0600, a 0644 input stays 0644), so the mode is corrected here after the
    # substitution and then asserted, rather than assumed from the umask (ledger B49).
    sed -i '' "s|__SECRET_KEY__|${key}|" "${settings_file}" \
        || fail "could not install the SearXNG secret key into ${settings_file}"
    chmod 600 "${settings_file}" \
        || fail "could not restrict the mode of ${settings_file}"
    if grep -qF '__SECRET_KEY__' "${settings_file}"; then
        fail "${settings_file} still contains the __SECRET_KEY__ placeholder; refusing to start a container that would sign with a known key"
    fi
    if ! grep -qF "secret_key: \"${key}\"" "${settings_file}"; then
        fail "${settings_file} does not contain the generated secret key; refusing to start"
    fi
}

# Keep the VM small: these machines have 8 GB of RAM and are also doing other work.
COLIMA_CPU="${COLIMA_CPU:-2}"
COLIMA_MEMORY="${COLIMA_MEMORY:-2}"
COLIMA_DISK="${COLIMA_DISK:-20}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
# Bound to the spare port while a new image is validated.
SEARXNG_CANARY_PORT="${SEARXNG_CANARY_PORT:-8899}"
# Pinned by digest rather than by tag: SearXNG changes engine definitions frequently, and
# that decides which engines contribute. This is the linux/arm64 image validated on this
# cluster (Apple Silicon nodes). To update: pull the new tag, exercise it, then replace the
# digest here and in deploy/docker-compose.yml.
SEARXNG_IMAGE="${SEARXNG_IMAGE:-searxng/searxng@sha256:e084201aa606fafce2151c8dc2844c9c3309025e90fbe7163b4f5e5183e474f0}"

# Used below. Failing here is clearer than failing half way through provisioning.
for tool in curl python3 openssl; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required but not installed"
done

# ---------------------------------------------------------------------------
# 0. sudo
# ---------------------------------------------------------------------------
# An ssh command runs a non-login, non-interactive shell: no TTY, so sudo cannot prompt.
# Cache the credential up front from SUDO_PASSWORD when the account has no passwordless
# sudo, then the rest of this script can use sudo normally.
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
# A non-login shell does not apply Homebrew's shellenv, so `command -v brew` reports
# "not found" even when Homebrew is installed. Check the known prefixes first, otherwise
# a working installation gets needlessly reinstalled.
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
    # nothing ties the bytes to a reviewed script. The digest below is the whole of that tie,
    # so when upstream changes this stops with instructions rather than running something new
    # (audit task A07).
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
    NONINTERACTIVE=1 /bin/bash "${installer}" >/tmp/brew-install.log 2>&1
    install_status=$?
    rm -f "${installer}"
    [ "${install_status}" -eq 0 ] || fail "Homebrew install failed; see /tmp/brew-install.log"
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
# 2. Colima + docker CLI
# ---------------------------------------------------------------------------
if ! command -v colima >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    say "installing colima and docker CLI"
    # Do not treat brew's exit status as the result. On a machine that once had Docker
    # Desktop, `brew install docker` still exits non-zero while successfully installing,
    # because it cannot create symlinks into an /Applications/Docker.app that is not
    # there. The binaries are what matter, so they are checked below.
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
        brew install colima docker docker-compose >/tmp/brew-pkgs.log 2>&1 \
        || say "brew reported a problem (see /tmp/brew-pkgs.log); verifying binaries"
fi

# The docker *client* formula installs its binary but can fail to link it when a
# `docker.lima` symlink from lima already occupies the name. Link it explicitly; this is
# idempotent and is exactly what was missing on the first three nodes.
if ! command -v docker >/dev/null 2>&1; then
    say "linking the docker CLI"
    brew link --overwrite docker >/tmp/brew-link.log 2>&1 \
        || say "brew link reported a problem (see /tmp/brew-link.log)"
fi

command -v colima >/dev/null 2>&1 || fail "colima not installed"
# `docker` may resolve to a broken Docker Desktop symlink; `docker --version` is the
# only check that proves the client actually runs.
docker --version >/dev/null 2>&1 || fail "docker CLI is present but not runnable"
say "colima ready: $(colima version 2>/dev/null | head -1)"
say "docker client: $(docker --version 2>/dev/null)"

# ---------------------------------------------------------------------------
# 2b. Container client configuration
# ---------------------------------------------------------------------------
# A machine that once had Docker Desktop can carry a ~/.docker/config.json pointing at
# its credential helper. Without the app installed, every registry operation dies with
# `exec: "docker-credential-desktop": executable file not found`, including pulls of
# public images that need no credentials at all. Strip that key rather than requiring
# the helper.
if [ -f "${HOME}/.docker/config.json" ]; then
    if grep -q '"credsStore"' "${HOME}/.docker/config.json" 2>/dev/null; then
        say "removing the stale Docker Desktop credential store from ~/.docker/config.json"
        python3 - <<'PYEOF'
import json, pathlib
path = pathlib.Path.home() / ".docker" / "config.json"
try:
    config = json.loads(path.read_text())
except (OSError, ValueError):
    raise SystemExit(0)
if config.pop("credsStore", None) is not None:
    path.write_text(json.dumps(config, indent=2))
PYEOF
    fi
fi

# ---------------------------------------------------------------------------
# 3. Start the VM
# ---------------------------------------------------------------------------
if ! colima status >/dev/null 2>&1; then
    say "starting colima VM (cpu=$COLIMA_CPU mem=${COLIMA_MEMORY}GB disk=${COLIMA_DISK}GB)"
    colima start \
        --cpu "$COLIMA_CPU" \
        --memory "$COLIMA_MEMORY" \
        --disk "$COLIMA_DISK" \
        --vm-type vz \
        --mount-type virtiofs \
        >/tmp/colima-start.log 2>&1 \
        || fail "colima start failed; see /tmp/colima-start.log"
fi
colima status >/dev/null 2>&1 || fail "colima is not running"

# Make the docker CLI find the Colima socket for this shell and for future logins.
DOCKER_SOCK="unix://${HOME}/.colima/default/docker.sock"
export DOCKER_HOST="$DOCKER_SOCK"
if ! grep -q 'DOCKER_HOST' "${HOME}/.zshrc" 2>/dev/null; then
    printf '\nexport DOCKER_HOST="%s"\n' "$DOCKER_SOCK" >> "${HOME}/.zshrc"
fi

for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done
docker info >/dev/null 2>&1 || fail "docker daemon not reachable after colima start"
say "docker daemon ready: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"

# Poll a SearXNG instance until it answers JSON, or give up. Used for the canary and for
# the instance that replaces it.
wait_for_json() {
    local port="$1" code=000
    for _ in $(seq 1 30); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
            "http://127.0.0.1:${port}/search?q=health&format=json" 2>/dev/null)"
        [ "$code" = "200" ] && return 0
        sleep 2
    done
    say "last HTTP response on port ${port}: ${code}"
    return 1
}

# ---------------------------------------------------------------------------
# 4. SearXNG
# ---------------------------------------------------------------------------
INSTALL_DIR="${HOME}/mcps-searxng"
mkdir -p "${INSTALL_DIR}/searxng"

# A per-node key, generated once and reused, so the tracked placeholder is never the key
# that signs a running instance's data.
SECRET_KEY_FILE="${INSTALL_DIR}/searxng/secret_key"
if [ ! -s "$SECRET_KEY_FILE" ]; then
    openssl rand -hex 32 > "$SECRET_KEY_FILE" 2>/dev/null \
        || fail "could not generate a SearXNG secret key in ${SECRET_KEY_FILE}"
    chmod 600 "$SECRET_KEY_FILE"
    say "generated a per-node SearXNG secret key"
fi
SECRET_KEY="$(cat "$SECRET_KEY_FILE")"

# Written here rather than copied so the node is self-contained and re-provisioning
# needs nothing but this script.
cat > "${INSTALL_DIR}/searxng/settings.yml" <<'SETTINGS'
# Local SearXNG for SwiftWebSearchMCP on a cluster node.
use_default_settings: true

general:
  instance_name: "MCPSearch node"

server:
  bind_address: "0.0.0.0"
  port: 8080
  # No Redis/Valkey here; the instance is private to the LAN.
  limiter: false
  public_instance: false
  secret_key: "__SECRET_KEY__"
  image_proxy: false

search:
  # Required: the stock image enables html only, so format=json returns HTTP 403.
  formats:
    - html
    - json
  safe_search: 0
  max_page: 1

outgoing:
  request_timeout: 6.0
  max_request_timeout: 10.0
  pool_connections: 20
  pool_maxsize: 20
SETTINGS

# The heredoc is quoted, so the key is substituted afterwards rather than expanded inline. The
# substitution is checked and verified, never assumed (ledger B17). The mode is set before the
# key is written, not only after: `chmod` here means the secret is never briefly readable, and
# because `sed -i` preserves the mode it survives the substitution (ledger B49).
chmod 600 "${INSTALL_DIR}/searxng/settings.yml" \
    || fail "could not restrict the mode of the SearXNG settings file"
install_secret_key "${INSTALL_DIR}/searxng/settings.yml" "${SECRET_KEY}"

# Prefer a locally-loaded image (transferred over the LAN) so each node does not
# re-download ~200 MB from the internet.
if docker image inspect "${SEARXNG_IMAGE}" >/dev/null 2>&1; then
    say "searxng image already present"
elif [ -f /tmp/searxng-image.tar ]; then
    say "loading searxng image from /tmp/searxng-image.tar"
    docker load -i /tmp/searxng-image.tar >/tmp/docker-load.log 2>&1 \
        || fail "docker load failed; see /tmp/docker-load.log"
else
    say "pulling searxng image from the internet"
    docker pull "${SEARXNG_IMAGE}" >/tmp/docker-pull.log 2>&1 \
        || fail "docker pull failed; see /tmp/docker-pull.log"
fi

# Validate the image before touching the running instance. The previous behaviour removed
# the working container first, so a bad pull or an incompatible image left the node serving
# nothing with no way back. The canary takes a spare loopback port, answers JSON, and is
# discarded; only then is the real container replaced.
docker rm -f mcps-searxng-canary >/dev/null 2>&1
say "validating ${SEARXNG_IMAGE} in a canary container"
docker run -d \
    --name mcps-searxng-canary \
    -p "127.0.0.1:${SEARXNG_CANARY_PORT}:8080" \
    -v "${INSTALL_DIR}/searxng/settings.yml:/etc/searxng/settings.yml:ro" \
    "${SEARXNG_IMAGE}" >/tmp/docker-canary.log 2>&1 \
    || fail "canary container failed to start; see /tmp/docker-canary.log"
if ! wait_for_json "${SEARXNG_CANARY_PORT}"; then
    docker rm -f mcps-searxng-canary >/dev/null 2>&1
    fail "the new image does not answer JSON; the running instance was left untouched"
fi
docker rm -f mcps-searxng-canary >/dev/null 2>&1
say "canary answered JSON; replacing the running instance"

docker rm -f mcps-searxng >/dev/null 2>&1

# Bound to all interfaces on the node so the main machine can reach it over the LAN.
# The node itself is on a private network and the instance has no authentication, so
# this is a LAN-only exposure by design: no port forwarding, no public DNS.
docker run -d \
    --name mcps-searxng \
    --restart unless-stopped \
    -p "${SEARXNG_PORT}:8080" \
    -v "${INSTALL_DIR}/searxng/settings.yml:/etc/searxng/settings.yml:ro" \
    "${SEARXNG_IMAGE}" >/tmp/docker-run.log 2>&1 \
    || fail "docker run failed; see /tmp/docker-run.log"

say "waiting for searxng to answer JSON"
wait_for_json "${SEARXNG_PORT}" || fail "searxng did not answer JSON on port ${SEARXNG_PORT}"

# Survive a reboot. The container has `--restart unless-stopped`, but that only helps
# once the Docker daemon is running, and the Colima VM does not start itself.
if brew services list 2>/dev/null | grep -q '^colima'; then
    brew services start colima >/tmp/brew-services.log 2>&1 \
        && say "colima registered to start at login" \
        || say "could not register colima as a service (see /tmp/brew-services.log)"
fi

# Report an address that exists. Printing a hostname as if it were a URL sent operators
# hunting for a network fault that was really a missing Tailscale install.
TAILSCALE_IP="$(/usr/local/bin/tailscale ip -4 2>/dev/null | head -1)"
[ -n "$TAILSCALE_IP" ] || TAILSCALE_IP="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null | head -1)"

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
say "container: $(docker ps --filter name=mcps-searxng --format '{{.Status}}')"
