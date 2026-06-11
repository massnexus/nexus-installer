#!/usr/bin/env bash
# nexus installer — LEAN, public, launcher-only (Distribution v2 / NEX-27).
#
# Usage (consumers):
#   curl -fsSL https://get.massnexus.dev/install.sh | bash
#
# What it does, fail-closed at every step:
#   1. check prereqs (docker running, curl, tar, a sha256 tool);
#   2. prompt for a GitHub PAT (read:packages + contents:read) and VALIDATE it
#      (GET /user) — a missing/unauthorized PAT aborts with NO partial install;
#   3. `docker login ghcr.io` with the PAT (password via stdin, never argv);
#   4. resolve the target version from the public `latest` marker;
#   5. download the PRIVATE nexus-{VERSION}.tar.gz Release asset via the GitHub API
#      and sha256-VERIFY it BEFORE installing;
#   6. extract the lean launcher (bin/nexus + sibling VERSION) into ~/.nexus/bin;
#   7. persist the PAT to ~/.nexus/.pat (mode 0600, never logged) so `nexus upgrade` reuses it;
#   8. add ~/.nexus/bin to PATH (zsh + bash) and run `nexus setup`.
#
# This is the ONE public artifact: it carries NO secrets — it only prompts for /
# persists the developer's OWN PAT. The source tree is NOT cloned (contributors
# still clone + `nexus build`; see docs/distribution.md).
#
# The PAT is never placed on a command line: `docker login` reads it via
# --password-stdin and every GitHub API call injects the Authorization header via a
# curl --config read from stdin (so it never appears in argv / `ps`).
#
# Test seams (unset in the field — see tests/nexus/cases/install.sh):
#   NEXUS_HOME, NEXUS_INSTALL_BASE, NEXUS_GH_REPO, NEXUS_API, NEXUS_CURL, NEXUS_DOCKER,
#   NEXUS_INSTALL_VERSION, NEXUS_PAT, NEXUS_INSTALL_SKIP_SETUP, NEXUS_NONINTERACTIVE,
#   NEXUS_TTY, NEXUS_RESOLVE_VERSION_CMD, NEXUS_VALIDATE_PAT_CMD, NEXUS_DOWNLOAD_CMD,
#   NEXUS_INSTALL_LIB (source the pure helpers for unit tests, then stop).

set -euo pipefail

NEXUS_HOME="${NEXUS_HOME:-${HOME}/.nexus}"
NEXUS_BIN="${NEXUS_HOME}/bin"
NEXUS_INSTALL_BASE="${NEXUS_INSTALL_BASE:-https://get.massnexus.dev}"
NEXUS_GH_REPO="${NEXUS_GH_REPO:-massnexus/nexus}"
NEXUS_API="${NEXUS_API:-https://api.github.com}"
GHCR="${NEXUS_GHCR:-ghcr.io}"
# The interactive terminal to read prompts from. Under `curl … | bash` the script's
# own stdin is the pipe, so prompts (and `nexus setup`) must read the real TTY.
# Overridable so tests can point it at a non-existent path to exercise the no-TTY path.
TTY_DEV="${NEXUS_TTY:-/dev/tty}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${GREEN}▶${RESET} $*"; }
warn()    { echo -e "${YELLOW}!${RESET} $*" >&2; }
die()     { echo -e "${RED}✗${RESET} $*" >&2; exit 1; }
success() { echo -e "${GREEN}✓${RESET} $*"; }

_curl()   { "${NEXUS_CURL:-curl}" "$@"; }
_docker() { "${NEXUS_DOCKER:-docker}" "$@"; }

# Stable semver only (matches the marker contract — no leading v, no pre-release).
_is_stable_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# Pick a sha256 verifier: `shasum -a 256` (macOS) or `sha256sum` (Linux). Both read
# the same "<hash>  <file>" format the release workflow writes.
_sha256_check() {  # _sha256_check <sha-file>   (run from the dir containing it)
  if command -v shasum   >/dev/null 2>&1; then shasum -a 256 -c "$1"
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1"
  else return 2
  fi
}

# Extract the "login" value from a GitHub /user JSON response (stdin).
_extract_login() {
  grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
    | sed -E 's/.*"login"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Resolve a private Release asset's numeric id by name from a release JSON (no jq).
# GitHub serializes each asset's "url" (…/releases/assets/<id>) before its "name";
# restricting the url match to releases/assets/<id> skips the uploader/html urls.
_asset_id() {  # _asset_id <release-json> <asset-name>
  printf '%s' "$1" \
  | grep -oE '"(url|name)":[[:space:]]*"[^"]*"' \
  | awk -v want="$2" '
      /"url":/  { if ($0 ~ /releases\/assets\/[0-9]+/) { match($0, /assets\/[0-9]+/); id = substr($0, RSTART+7, RLENGTH-7) } }
      /"name":/ { if (index($0, "\"" want "\"")) { print id; exit } }'
}

# Run a GitHub API call with the PAT injected via a curl --config read from STDIN, so
# the token never appears in argv. <accept> is the Accept header; remaining args + <url>
# pass through to curl. Requires $PAT in scope.
_gh_api() {  # _gh_api <accept> <url> [extra curl args...]
  local accept="$1" url="$2"; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$PAT" \
    | _curl -fsSL --config - -H "Accept: ${accept}" "$@" "$url"
}

# Unit-test seam: when sourced with NEXUS_INSTALL_LIB=1, expose the pure helpers above
# and STOP before running the installer (mirrors bin/nexus's NEXUS_SELFTEST guard).
if [[ -n "${NEXUS_INSTALL_LIB:-}" ]]; then return 0 2>/dev/null || exit 0; fi

echo ""
echo -e "${BOLD}nexus installer${RESET}"
echo "────────────────────────────────────"
echo ""

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
info "Checking prerequisites..."
command -v "${NEXUS_CURL:-curl}" >/dev/null 2>&1 || die "curl is not installed."
command -v tar  >/dev/null 2>&1 || die "tar is not installed."
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
  || die "no sha256 tool found (need 'shasum' or 'sha256sum') — cannot verify the download."
command -v "${NEXUS_DOCKER:-docker}" >/dev/null 2>&1 \
  || die "Docker is not installed. Install it from https://docs.docker.com/get-docker/"
_docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop and try again."
success "Prerequisites satisfied"

# ── 2. GitHub PAT (prompt + validate) ─────────────────────────────────────────
# A persisted PAT (from a prior install) is reused; otherwise prompt on the TTY.
# The PAT needs read:packages (ghcr pull) + contents:read (private Release download).
PAT="${NEXUS_PAT:-}"
if [[ -z "$PAT" && -f "${NEXUS_HOME}/.pat" ]]; then
  PAT="$(tr -d '[:space:]' < "${NEXUS_HOME}/.pat" 2>/dev/null || true)"
fi
if [[ -z "$PAT" && "${NEXUS_NONINTERACTIVE:-}" != "1" && -r "$TTY_DEV" ]]; then
  echo -e "${BOLD}?${RESET} GitHub PAT (read:packages + contents:read) — https://github.com/settings/tokens:"
  read -rs PAT < "$TTY_DEV" || true; echo ""
fi
[[ -n "$PAT" ]] || die "A GitHub PAT is required (read:packages + contents:read). Aborting — nothing was installed."

info "Validating GitHub credentials..."
GH_USER=""
if [[ -n "${NEXUS_VALIDATE_PAT_CMD:-}" ]]; then
  GH_USER="$(NEXUS_PAT="$PAT" ${NEXUS_VALIDATE_PAT_CMD} 2>/dev/null || true)"
else
  GH_USER="$(_gh_api 'application/vnd.github+json' "${NEXUS_API}/user" 2>/dev/null | _extract_login || true)"
fi
[[ -n "$GH_USER" ]] || die "GitHub PAT is missing or unauthorized — could not authenticate. Aborting — nothing was installed."
success "Authenticated as ${GH_USER}"

# ── 3. docker login ghcr.io (password via stdin, never argv) ───────────────────
info "Logging Docker in to ${GHCR}..."
printf '%s' "$PAT" | _docker login "${GHCR}" -u "$GH_USER" --password-stdin >/dev/null 2>&1 \
  || die "docker login ${GHCR} failed — the PAT needs the read:packages scope. Aborting — nothing was installed."
success "Docker authenticated to ${GHCR}"

# ── 4. Resolve target version (public marker) ──────────────────────────────────
if [[ -n "${NEXUS_INSTALL_VERSION:-}" ]]; then
  VERSION="$NEXUS_INSTALL_VERSION"
elif [[ -n "${NEXUS_RESOLVE_VERSION_CMD:-}" ]]; then
  VERSION="$(${NEXUS_RESOLVE_VERSION_CMD} 2>/dev/null || true)"
else
  VERSION="$(_curl -fsSL "${NEXUS_INSTALL_BASE}/latest" 2>/dev/null || true)"
fi
VERSION="$(printf '%s' "${VERSION:-}" | tr -d '[:space:]')"
[[ -n "$VERSION" ]] || die "Could not resolve the latest nexus version from ${NEXUS_INSTALL_BASE}/latest. Aborting."
_is_stable_semver "$VERSION" || die "Resolved version '${VERSION}' is not a stable semver — refusing to install. Aborting."
info "Installing nexus ${VERSION} (launcher-only)..."

# ── 5. Download + sha256-verify (BEFORE installing) ────────────────────────────
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

TARBALL="nexus-${VERSION}.tar.gz"
SHAFILE="nexus-${VERSION}.sha256"

download_asset() {  # download_asset <asset-name> <dest-path> ; rc 1=lookup/asset miss
  local name="$1" dest="$2"
  local rel; rel="$(_gh_api 'application/vnd.github+json' \
                      "${NEXUS_API}/repos/${NEXUS_GH_REPO}/releases/tags/v${VERSION}" 2>/dev/null)" \
    || return 1
  local id; id="$(_asset_id "$rel" "$name")"
  [[ -n "$id" ]] || return 1
  _gh_api 'application/octet-stream' \
    "${NEXUS_API}/repos/${NEXUS_GH_REPO}/releases/assets/${id}" -o "$dest" 2>/dev/null
}

info "Downloading ${TARBALL}..."
if [[ -n "${NEXUS_DOWNLOAD_CMD:-}" ]]; then
  # Test seam: the hook drops ${TARBALL} + ${SHAFILE} into $WORK (or fails).
  NEXUS_PAT="$PAT" ${NEXUS_DOWNLOAD_CMD} "$WORK" "$VERSION" \
    || die "Could not download the ${VERSION} release assets (missing asset / unauthorized / network). Aborting — nothing was installed."
else
  download_asset "$TARBALL" "${WORK}/${TARBALL}" \
    || die "Could not download ${TARBALL} for v${VERSION} (asset missing, or the PAT lacks contents:read). Aborting — nothing was installed."
  download_asset "$SHAFILE" "${WORK}/${SHAFILE}" \
    || die "Could not download the ${SHAFILE} checksum for v${VERSION}. Aborting — nothing was installed."
fi
[[ -s "${WORK}/${TARBALL}" ]] || die "Downloaded tarball is missing/empty. Aborting — nothing was installed."
[[ -s "${WORK}/${SHAFILE}" ]] || die "Downloaded checksum is missing/empty. Aborting — nothing was installed."

info "Verifying sha256 checksum..."
( cd "$WORK" && _sha256_check "$SHAFILE" ) >/dev/null 2>&1 \
  || die "sha256 verification FAILED for ${TARBALL} — the download is corrupt or tampered. Aborting — nothing was installed."
success "Checksum verified"

# ── 6. Extract the lean launcher + install atomically ──────────────────────────
STAGE="${WORK}/stage"; mkdir -p "$STAGE"
tar xzf "${WORK}/${TARBALL}" -C "$STAGE" \
  || die "Failed to extract ${TARBALL}. Aborting — nothing was installed."
[[ -f "${STAGE}/bin/nexus" && -f "${STAGE}/VERSION" ]] \
  || die "Tarball is missing bin/nexus or VERSION — not a valid lean launcher. Aborting — nothing was installed."

mkdir -p "$NEXUS_BIN"
install -m 0755 "${STAGE}/bin/nexus" "${NEXUS_BIN}/nexus"
cp "${STAGE}/VERSION" "${NEXUS_HOME}/VERSION"
success "Installed nexus ${VERSION} to ${NEXUS_BIN}"

# ── 7. Persist the PAT for `nexus upgrade` (0600, never logged) ────────────────
( umask 077; printf '%s\n' "$PAT" > "${NEXUS_HOME}/.pat" )
chmod 600 "${NEXUS_HOME}/.pat"
success "Saved credentials to ${NEXUS_HOME}/.pat (mode 0600)"

# ── 8. PATH (zsh + bash) ───────────────────────────────────────────────────────
PATH_LINE="export PATH=\"\$PATH:${NEXUS_BIN}\""
add_to_shell() {
  local rc="$1"
  [[ -e "$rc" || -w "$(dirname "$rc")" ]] || return 0
  if [[ -f "$rc" ]] && grep -qF "${NEXUS_BIN}" "$rc" 2>/dev/null; then return 0; fi
  { echo ""; echo "# nexus"; echo "${PATH_LINE}"; } >> "$rc" \
    && success "Added nexus to PATH in ${rc}"
}
add_to_shell "${HOME}/.zshrc"  || true
add_to_shell "${HOME}/.bashrc" || true
export PATH="${PATH}:${NEXUS_BIN}"

# ── 9. First-time setup ────────────────────────────────────────────────────────
if [[ "${NEXUS_INSTALL_SKIP_SETUP:-}" == "1" ]]; then
  echo ""; success "Install complete (setup skipped)."
  exit 0
fi

echo ""
echo -e "${BOLD}Running first-time setup...${RESET}"
echo ""
# `nexus setup` prompts interactively. Under `curl … | bash` this script's stdin is
# the (now-EOF) pipe, so redirect setup's stdin to the real TTY. With no TTY (CI,
# non-interactive), install is complete — point the user at `nexus setup` and stop
# cleanly rather than letting setup die on an empty read.
if [[ -r "$TTY_DEV" ]]; then
  "${NEXUS_BIN}/nexus" setup < "$TTY_DEV"
else
  warn "No interactive terminal available — skipping first-time setup."
  echo "The nexus launcher is installed. Open a new terminal and run:"
  echo "  nexus setup"
  exit 0
fi

echo ""
echo -e "${BOLD}Installation complete!${RESET}"
echo ""
echo "Reload your shell (or open a new terminal):"
echo "  source ~/.zshrc"
echo ""
echo "Then start a session:"
echo "  cd ~/dev/myproject"
echo "  nexus tmux"
echo ""
