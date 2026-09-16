#!/bin/bash
#
# Install MCPSearch, with a working local SearXNG as a hard requirement.
#
# Why SearXNG is mandatory
# ------------------------
# Every vendor provider is optional and most of them cost money or need an account, so an
# installation with no provider is a server that starts and answers every search with
# "no search provider is configured". A local SearXNG removes that: it needs no account, no
# key and no per-query billing, and it is the only provider that can be guaranteed present on
# the machine that runs the server. So this installer does not treat it as a nice-to-have.
# It installs one if there is none, and then *proves* it answers a real query before it will
# report success. If that proof fails, the installer exits non-zero and says what to fix.
#
# The gate is a real search, not a health check: an instance with `search.formats: [html]`
# answers `/healthz` happily and returns HTTP 403 for the JSON API the server actually uses.
#
# Usage:
#   deploy/install.sh [options]
#
# Options:
#   --prefix DIR        install root              (default ~/Library/Application Support/MCPSearch)
#   --port N            SearXNG port to use/install (default 8888)
#   --bind ADDRESS      interface SearXNG listens on (default 127.0.0.1). Use 0.0.0.0 to
#                       serve other machines, which is what the cluster nodes did before.
#   --searxng-url URL   use this instance instead of installing one
#   --method auto|docker|native                    (default auto)
#   --from-release      download the released arm64 binary instead of building from source
#   --dry-run           report what would happen and change nothing
#   --verify-only       change nothing; verify an existing install and exit
#   -h, --help          this text
#
# Exit status is 0 only when every gate passed.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PREFIX="${HOME}/Library/Application Support/MCPSearch"
PORT=8888
BIND="127.0.0.1"
BIND_EXPLICIT=0
SEARXNG_URL=""
METHOD="auto"
FROM_RELEASE=0
DRY_RUN=0
VERIFY_ONLY=0

# Pinned exactly, like deploy/docker-compose.yml and deploy/provision-node.sh. SearXNG changes
# engine definitions frequently, and that decides which engines contribute to a result.
SEARXNG_IMAGE="searxng/searxng@sha256:e084201aa606fafce2151c8dc2844c9c3309025e90fbe7163b4f5e5183e474f0"
# The native path clones this commit. It is the tree the container image above was built from,
# so the two methods install the same SearXNG.
SEARXNG_SRC_SHA="461f174b09fc151f49257aa5206417aca8930efa"   # full SHA: git cannot fetch a short one
SEARXNG_REPO="https://github.com/searxng/searxng"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONTAINER_NAME="mcps-searxng"

FAILURES=0

say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() {
    printf 'FAIL  %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
}
die() {
    printf 'ERROR %s\n' "$*" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --bind) BIND="${2:?--bind needs a value}"; BIND_EXPLICIT=1; shift 2 ;;
        --searxng-url) SEARXNG_URL="${2:?--searxng-url needs a value}"; shift 2 ;;
        --method) METHOD="${2:?--method needs a value}"; shift 2 ;;
        --from-release) FROM_RELEASE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

case "$METHOD" in
    auto | docker | native) ;;
    *) die "--method must be auto, docker or native" ;;
esac

run() {
    # Every mutation goes through here so --dry-run is honest rather than decorative.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf 'DRY   %s\n' "$*"
        return 0
    fi
    "$@"
}

# Docker Desktop keeps its CLI plugins and credential helpers inside the app bundle, and a
# non-interactive shell — ssh, launchd, CI — does not have that directory on PATH. The failure
# is misleading: `docker info` works, and then a pull of a *public* image dies with
# "error getting credentials - exec: docker-credential-desktop: executable file not found",
# because ~/.docker/config.json records `credsStore: desktop`. Restoring the path is better
# than bypassing the user's Docker configuration.
ensure_docker_env() {
    local desktop_bin="/Applications/Docker.app/Contents/Resources/bin"
    if [ -d "$desktop_bin" ] && ! command -v docker-credential-desktop >/dev/null 2>&1; then
        PATH="${desktop_bin}:${PATH}"
        export PATH
        say "added the Docker Desktop CLI directory to PATH (non-interactive shells lack it)"
    fi
}

# Set only when the default credential store cannot be used for this run.
DOCKER_CONFIG_DIR=""

# Fetch the pinned image, and cope with the two ways Docker Desktop's credential store fails
# in a non-interactive session (ssh, launchd, CI): the helper missing from PATH, handled
# above, and then the login keychain refusing to unlock. The image is public and needs no
# credentials at all, so a private config with no `credsStore` is the correct fallback —
# bypassing an interactive keychain prompt rather than the user's configuration.
prepare_image() {
    local image="$1"
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi
    if docker pull "$image" >/dev/null 2>&1; then
        return 0
    fi
    DOCKER_CONFIG_DIR="${PREFIX}/docker"
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$DOCKER_CONFIG_DIR" || return 1
        printf '{}' > "${DOCKER_CONFIG_DIR}/config.json" || return 1
    fi
    say "the default Docker credential store needs the login keychain, which this session"
    say "cannot unlock; retrying with a private config — the image is public, so no"
    say "credentials are involved."
    DOCKER_CONFIG="$DOCKER_CONFIG_DIR" docker pull "$image" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------

step "preflight"

[ "$(uname -s)" = "Darwin" ] || die "this installer targets macOS"
[ "$(uname -m)" = "arm64" ] || die "MCPSearch ships arm64 only (M1 and later); found $(uname -m)"
[ "$(id -u)" -ne 0 ] || die "do not run this as root; it installs into your own home directory"
command -v curl >/dev/null || die "curl is required"
ensure_docker_env

free_kb="$(df -k "$HOME" | tail -1 | awk '{print $4}')"
if [ "$free_kb" -gt 3145728 ]; then
    pass "macOS on arm64, $((free_kb / 1024 / 1024)) GiB free in \$HOME"
else
    die "need about 3 GiB free in \$HOME; found $((free_kb / 1024)) MiB"
fi

if command -v python3 >/dev/null; then
    pass "python3 present ($(python3 --version 2>&1)) — used to verify the install"
    HAVE_PYTHON=1
else
    HAVE_PYTHON=0
    fail "python3 is required: it is how this installer proves a search works end to end"
fi

APP_DIR="${PREFIX}/app"
ETC_DIR="${PREFIX}/etc"
SEARXNG_DIR="${PREFIX}/searxng"

# ---------------------------------------------------------------------------
# 1. SearXNG — install or adopt, then prove it answers
# ---------------------------------------------------------------------------

searxng_answers() {
    # A real query through the JSON API. `jq` is not assumed to exist, so this uses python3.
    local base="$1" body
    body="$(curl -sS --max-time 25 "${base}/search?q=mcps-install-check&format=json" 2>/dev/null)" || return 1
    [ -n "$body" ] || return 1
    printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(data.get("results"), list):
    sys.exit(1)
print(len(data["results"]))
' 2>/dev/null
}

install_searxng_docker() {
    step "installing SearXNG (docker)"
    command -v docker >/dev/null || return 1
    docker info >/dev/null 2>&1 || return 1

    run mkdir -p "${SEARXNG_DIR}" || return 1
    if [ -f "${SEARXNG_DIR}/settings.yml" ]; then
        say "keeping the existing ${SEARXNG_DIR}/settings.yml"
    else
        run cp "${REPO_ROOT}/deploy/searxng/settings.yml" "${SEARXNG_DIR}/settings.yml" || return 1
    fi

    local secret_file="${SEARXNG_DIR}/secret_key"
    if [ ! -f "$secret_file" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "DRY   generate a per-install secret key"
        else
            # Generated, never tracked: a placeholder in git would be the key that signs sessions.
            umask 077
            python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$secret_file" || return 1
            chmod 600 "$secret_file"
        fi
    fi
    local secret
    secret="$(cat "$secret_file" 2>/dev/null)"

    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
        say "removing the previous ${CONTAINER_NAME} container"
        run docker rm -f "$CONTAINER_NAME" >/dev/null || return 1
    fi

    prepare_image "$SEARXNG_IMAGE" || return 1

    run env ${DOCKER_CONFIG_DIR:+DOCKER_CONFIG="$DOCKER_CONFIG_DIR"} docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "127.0.0.1:${PORT}:8080" \
        -v "${SEARXNG_DIR}/settings.yml:/etc/searxng/settings.yml:ro" \
        -e "SEARXNG_BASE_URL=http://localhost:8080/" \
        -e "SEARXNG_SECRET=${secret}" \
        "$SEARXNG_IMAGE" >/dev/null || return 1

    say "started ${CONTAINER_NAME} on 127.0.0.1:${PORT} (pinned by digest, restart unless-stopped)"
}

install_searxng_native() {
    step "installing SearXNG (native, no container runtime)"
    command -v git >/dev/null || return 1
    local py=""
    for candidate in python3.13 python3.12 python3.11 python3; do
        command -v "$candidate" >/dev/null || continue
        # The Rust-backed dependencies (msgspec) publish wheels for these; 3.14 does not yet.
        case "$("$candidate" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" in
            3.11 | 3.12 | 3.13) py="$candidate"; break ;;
        esac
    done
    [ -n "$py" ] || {
        warn "no Python 3.11-3.13 found (3.14 lacks wheels for SearXNG's Rust dependencies)"
        return 1
    }

    mkdir -p "${SEARXNG_DIR}" || return 1
    # Guard on the checkout's content, not on `.git`: an interrupted run leaves a valid empty
    # repository behind, and treating that as done fails later with "does not appear to be a
    # Python project".
    if [ ! -f "${SEARXNG_DIR}/src/pyproject.toml" ]; then
        run mkdir -p "${SEARXNG_DIR}/src" || return 1
        run git -C "${SEARXNG_DIR}/src" init -q || return 1
        run git -C "${SEARXNG_DIR}/src" remote add origin "$SEARXNG_REPO" 2>/dev/null || true
        run git -C "${SEARXNG_DIR}/src" fetch -q --depth 1 origin "$SEARXNG_SRC_SHA" || return 1
        run git -C "${SEARXNG_DIR}/src" checkout -q FETCH_HEAD || return 1
    fi

    run mkdir -p "${SEARXNG_DIR}/etc" || return 1
    if [ ! -f "${SEARXNG_DIR}/etc/settings.yml" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "DRY   write ${SEARXNG_DIR}/etc/settings.yml"
        else
            umask 077
            secret="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')" || return 1
            # The checked-in settings.yml deliberately omits `secret_key`, because the container
            # receives it as SEARXNG_SECRET and an environment variable wins. A launchd job has no
            # such environment, so the key is written here — generated per install, never tracked —
            # and the bind narrows to loopback, which the container gets from its port mapping.
            python3 - "${REPO_ROOT}/deploy/searxng/settings.yml" "${SEARXNG_DIR}/etc/settings.yml" "$PORT" "$secret" "$BIND" <<'PY' || return 1
import pathlib, sys
src, dst, port, secret, bind = sys.argv[1:6]
text = pathlib.Path(src).read_text(encoding="utf-8")
text = text.replace("  port: 8080", f"  port: {port}")
text = text.replace('  bind_address: "0.0.0.0"', f'  bind_address: "{bind}"')
text = text.replace("server:\n", f'server:\n  secret_key: "{secret}"\n', 1)
pathlib.Path(dst).write_text(text, encoding="utf-8")
PY
            chmod 600 "${SEARXNG_DIR}/etc/settings.yml"
        fi
    fi

    # Converge the listener on every run. The file above is only written once, so without this a
    # re-run with a different --port would leave the old one in place and the verification would
    # then probe a port nothing had ever bound.
    if [ "$DRY_RUN" -eq 0 ]; then
        python3 - "${SEARXNG_DIR}/etc/settings.yml" "$PORT" "$BIND" <<'PY' || return 1
import pathlib, sys
path, port, bind = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
seen_port = seen_bind = False
for index, line in enumerate(lines):
    if not seen_port and line.lstrip().startswith("port:"):
        lines[index] = f"  port: {port}\n"
        seen_port = True
    elif not seen_bind and line.lstrip().startswith("bind_address:"):
        lines[index] = f'  bind_address: "{bind}"\n'
        seen_bind = True
    if seen_port and seen_bind:
        break
path.write_text("".join(lines), encoding="utf-8")
PY
    fi

    # Guard on the import, not on the venv existing. An interrupted run leaves a valid virtualenv
    # holding the dependencies but not the package; skipping the install then fails at launch with
    # `No module named 'searx'`, long after the step that should have caught it.
    if ! "${SEARXNG_DIR}/pyenv/bin/python" -c 'import searx' >/dev/null 2>&1; then
        [ -x "${SEARXNG_DIR}/pyenv/bin/python" ] || run "$py" -m venv "${SEARXNG_DIR}/pyenv" || return 1
        run "${SEARXNG_DIR}/pyenv/bin/pip" install -q -U pip setuptools wheel || return 1
        run "${SEARXNG_DIR}/pyenv/bin/pip" install -q -U pyyaml msgspec typing-extensions pybind11 || return 1
        run "${SEARXNG_DIR}/pyenv/bin/pip" install -q --use-pep517 --no-build-isolation -e "${SEARXNG_DIR}/src" || return 1
    fi

    local plist="${HOME}/Library/LaunchAgents/local.mcps.searxng.plist"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "DRY   write ${plist} and load it"
    else
        mkdir -p "$(dirname "$plist")" || return 1
        cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.mcps.searxng</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SEARXNG_DIR}/pyenv/bin/python</string>
    <string>-m</string><string>searx.webapp</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>SEARXNG_SETTINGS_PATH</key><string>${SEARXNG_DIR}/etc/settings.yml</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${PREFIX}/searxng.log</string>
  <key>StandardErrorPath</key><string>${PREFIX}/searxng.log</string>
</dict>
</plist>
PLIST
        launchctl unload "$plist" >/dev/null 2>&1
        launchctl load "$plist" >/dev/null 2>&1 || return 1
    fi
    say "started SearXNG natively on ${BIND}:${PORT} (launchd, KeepAlive, label local.mcps.searxng)"
    if [ "$BIND" != "127.0.0.1" ]; then
        say "note: ${BIND} serves other machines too. The launchd label is fixed, so one native"
        say "      SearXNG per machine is what this supports — a second prefix replaces the first."
    fi
}

step "SearXNG"

if [ -n "$SEARXNG_URL" ]; then
    BASE="${SEARXNG_URL%/}"
    say "using the instance you named: ${BASE}"
else
    BASE="http://127.0.0.1:${PORT}"
    existing="$(searxng_answers "$BASE" || true)"
    if [ -n "$existing" ]; then
        pass "a working SearXNG is already listening on ${BASE} (${existing} results)"
        # An instance that is already serving is left alone, which also means its listener is
        # left alone — it may be a container, or another install with its own settings. Saying so
        # matters because --bind would otherwise look like it had been applied.
        if [ "$BIND_EXPLICIT" -eq 1 ]; then
            warn "--bind ${BIND} was not applied: this instance was already running and is adopted as-is"
            say "      To move it: stop that instance, then re-run this installer."
        fi
    elif [ "$VERIFY_ONLY" -eq 1 ]; then
        fail "no working SearXNG on ${BASE} (--verify-only changes nothing)"
    else
        method="$METHOD"
        if [ "$method" = "auto" ]; then
            if docker info >/dev/null 2>&1; then method="docker"; else method="native"; fi
        fi
        say "no instance on ${BASE}; installing one with method=${method}"
        installed=1
        if [ "$method" = "docker" ]; then
            install_searxng_docker || installed=0
        else
            install_searxng_native || installed=0
        fi
        if [ "$installed" -eq 0 ]; then
            fail "could not install SearXNG with method=${method}"
            if [ "$method" = "docker" ]; then
                # The common case on a Mac: Docker Desktop's credential store is backed by the
                # login keychain, and a non-interactive session cannot unlock it, so even a pull
                # of a public image fails. The native method needs none of that.
                say "      If the failure mentions credentials or the keychain, this session cannot"
                say "      unlock the login keychain that Docker Desktop uses. Re-run with"
                say "      --method native to install SearXNG without a container runtime."
            fi
        fi
    fi
fi

# The gate. /healthz is not enough: an instance without the json format answers health checks
# and returns 403 to the API the server uses.
if [ "$DRY_RUN" -eq 0 ]; then
    say "waiting for ${BASE} to answer a real query"
    results=""
    i=0
    while [ "$i" -lt 30 ]; do
        results="$(searxng_answers "$BASE" || true)"
        [ -n "$results" ] && break
        i=$((i + 1))
        sleep 2
    done
    if [ -n "$results" ]; then
        pass "SearXNG answered a real query: ${results} results from ${BASE}"
    else
        fail "SearXNG at ${BASE} did not return usable JSON results — MCPSearch would have no provider"
        say "      /healthz may still answer 200. Check that settings.yml enables 'json':"
        say "      curl -s '${BASE}/search?q=test&format=json' | head -c 200"
    fi
else
    say "DRY   would verify a real query against ${BASE}"
fi

if [ "$FAILURES" -ne 0 ]; then
    printf '\n%d check(s) FAILED — SearXNG is mandatory, so stopping before installing MCPSearch.\n' "$FAILURES" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. The MCPSearch binary
# ---------------------------------------------------------------------------

step "MCPSearch binary"
BIN="${APP_DIR}/SwiftWebSearchMCP"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    run mkdir -p "$APP_DIR" "$ETC_DIR" || die "could not create ${PREFIX}"
    if [ "$FROM_RELEASE" -eq 1 ]; then
        version="$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "")"
        [ -n "$version" ] || die "cannot tell the version: ${REPO_ROOT}/VERSION is missing"
        url="https://github.com/Pummelchen/MCPSearch/releases/download/v${version}/mcps-${version}-macos-arm64.tar.gz"
        if [ "$DRY_RUN" -eq 1 ]; then
            say "DRY   download ${url}, verify SHA256SUMS, install to ${BIN}"
        else
            say "downloading ${url}"
            tmp="$(mktemp -d)"
            # Keep the published filename: SHA256SUMS names it, and `--ignore-missing` against a
            # renamed file verifies nothing while still looking like it ran.
            archive="${tmp}/$(basename "$url")"
            curl -fsSL "$url" -o "$archive" || die "download failed"
            curl -fsSL "${url%/*}/SHA256SUMS" -o "${tmp}/SHA256SUMS" || die "checksum download failed"
            ( cd "$tmp" && shasum -a 256 -c SHA256SUMS >/dev/null ) || die "checksum mismatch"
            tar -xzf "$archive" -C "$tmp" || die "could not unpack the archive"
            cp "${tmp}/mcps-${version}-macos-arm64/SwiftWebSearchMCP" "$BIN" || die "could not install the binary"
            chmod +x "$BIN"
            rm -rf "$tmp"
            say "installed the released binary for ${version}"
        fi
    else
        command -v swift >/dev/null || die "swift not found; pass --from-release to use the published binary"
        if [ "$DRY_RUN" -eq 1 ]; then
            say "DRY   swift build -c release in ${REPO_ROOT}, then install to ${BIN}"
        else
            say "building from source at ${REPO_ROOT}"
            swift build -c release --package-path "$REPO_ROOT" -Xswiftc -warnings-as-errors || die "build failed"
            built="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)/SwiftWebSearchMCP"
            cp "$built" "$BIN" || die "could not install the built binary"
            chmod +x "$BIN"
            say "installed the locally built binary"
        fi
    fi
fi

if [ -x "$BIN" ]; then
    archs="$(lipo -archs "$BIN" 2>/dev/null)"
    [ "$archs" = "arm64" ] && pass "binary is native arm64" || fail "binary is '$archs', expected arm64"
else
    [ "$DRY_RUN" -eq 1 ] || fail "no binary at ${BIN}"
fi

# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------

step "configuration"
CFG="${ETC_DIR}/config.env"
if [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    umask 077
    {
        printf '# Written by deploy/install.sh. Read by SwiftWebSearchMCP via SEARCH_CONFIG_FILE.\n'
        printf '# Environment variables override this file.\n\n'
        printf '# The local SearXNG this install requires. No key, no account, no per-query cost.\n'
        printf 'SEARXNG_BASE_URL=%s\n' "$BASE"
    } > "$CFG" || die "could not write ${CFG}"
    chmod 600 "$CFG"
    pass "wrote ${CFG} (mode 600, SEARXNG_BASE_URL=${BASE})"
else
    say "DRY   would write ${CFG} with SEARXNG_BASE_URL=${BASE}"
fi

# ---------------------------------------------------------------------------
# 4. Prove the server searches through it
# ---------------------------------------------------------------------------

step "end-to-end verification"
if [ "$DRY_RUN" -eq 1 ]; then
    say "DRY   would start the server and require a real search result"
elif [ "$HAVE_PYTHON" -eq 0 ]; then
    fail "python3 is missing, so the end-to-end search could not be verified"
else
    outcome="$(python3 - "$BIN" "$CFG" <<'PY' 2>/dev/null || true
import json, os, subprocess, sys, threading
binpath, cfg = sys.argv[1], sys.argv[2]
env = {k: v for k, v in os.environ.items() if not k.startswith("SEARCH_") and not k.endswith("_KEY")}
env["SEARCH_CONFIG_FILE"] = cfg
proc = subprocess.Popen([binpath], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
def send(obj):
    proc.stdin.write(json.dumps(obj) + "\n"); proc.stdin.flush()
def read(timeout=120):
    box = {}
    def run():
        line = proc.stdout.readline()
        box["v"] = json.loads(line) if line.strip() else None
    t = threading.Thread(target=run, daemon=True); t.start(); t.join(timeout)
    return box.get("v")
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                 "clientInfo": {"name": "installer", "version": "1"}}})
read()
send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
      "params": {"name": "web_search", "arguments": {"query": "model context protocol", "mode": "fast"}}})
reply = read()
proc.stdin.close()
if not reply:
    print("timeout"); sys.exit(0)
res = reply.get("result", {})
text = (res.get("content") or [{}])[0].get("text", "")
if res.get("isError"):
    print("error: " + text[:200].replace("\n", " ")); sys.exit(0)
print("ok: " + str(text.count("\n[")) + " result blocks")
PY
)"
    case "$outcome" in
        ok:*) pass "MCPSearch returned a real search result (${outcome#ok: })" ;;
        error:*) fail "MCPSearch could not search: ${outcome#error: }" ;;
        *) fail "MCPSearch did not answer the end-to-end check" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

step "summary"
say "install root : ${PREFIX}"
say "binary       : ${BIN}"
say "config       : ${CFG}"
say "SEARXNG_BASE_URL=${BASE}"

if [ "$FAILURES" -ne 0 ]; then
    printf '\n%d check(s) FAILED — the install is not usable.\n' "$FAILURES" >&2
    exit 1
fi

cat <<EOF

Installed and verified. Point an MCP client at the binary:

  {
    "mcpServers": {
      "web-search": {
        "command": "${BIN}",
        "env": { "SEARCH_CONFIG_FILE": "${CFG}" }
      }
    }
  }

Re-verify at any time without changing anything:

  ${REPO_ROOT}/deploy/install.sh --verify-only

EOF
exit 0
