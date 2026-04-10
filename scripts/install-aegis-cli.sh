#!/usr/bin/env bash
# =============================================================================
# AEGIS Platform — Install aegis CLI Binary
# =============================================================================
# Downloads the latest aegis CLI binary from GitHub releases and installs it
# to bin/aegis. Skips download if the installed version already matches.
#
# Usage:
#   bash scripts/install-aegis-cli.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

REPO="100monkeys-ai/aegis-orchestrator"
ASSET="aegis-linux-x86_64.tar.gz"
BIN_DIR="$ROOT_DIR/bin"
BIN_PATH="$BIN_DIR/aegis"

# Load .env for optional GHCR_TOKEN auth
if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

# ---- Resolve latest version ------------------------------------------------

API_URL="https://api.github.com/repos/${REPO}/releases?per_page=1"

AUTH_HEADER=()
if [[ -n "${GHCR_TOKEN:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: token ${GHCR_TOKEN}")
fi

RELEASE_JSON=$(curl -fsSL "${AUTH_HEADER[@]}" "$API_URL")

if command -v jq &>/dev/null; then
    VERSION=$(echo "$RELEASE_JSON" | jq -r '.[0].tag_name // empty')
else
    VERSION=$(echo "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

if [[ -z "${VERSION:-}" ]]; then
    echo "ERROR: Could not determine latest release version"
    exit 1
fi

echo "Latest aegis CLI version: $VERSION"

# ---- Check if already installed --------------------------------------------

if [[ -x "$BIN_PATH" ]]; then
    INSTALLED_VERSION=$("$BIN_PATH" --version 2>/dev/null | awk '{print $NF}' || true)
    # Strip leading 'v' for comparison
    VERSION_BARE="${VERSION#v}"
    if [[ "$INSTALLED_VERSION" == "$VERSION_BARE" || "$INSTALLED_VERSION" == "$VERSION" ]]; then
        echo "aegis CLI $VERSION already installed, skipping download."
        exit 0
    fi
fi

# ---- Download and install --------------------------------------------------

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading $DOWNLOAD_URL ..."
curl -fsSL "${AUTH_HEADER[@]}" -o "$TMPDIR/$ASSET" "$DOWNLOAD_URL"

echo "Extracting..."
tar -xzf "$TMPDIR/$ASSET" -C "$TMPDIR"

# Find the binary in the extracted contents
EXTRACTED_BIN=$(find "$TMPDIR" -name "aegis" -type f -executable | head -1)
if [[ -z "$EXTRACTED_BIN" ]]; then
    # Fallback: look for any file named aegis
    EXTRACTED_BIN=$(find "$TMPDIR" -name "aegis" -type f | head -1)
fi

if [[ -z "${EXTRACTED_BIN:-}" ]]; then
    echo "ERROR: Could not find aegis binary in extracted archive"
    exit 1
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$EXTRACTED_BIN" "$BIN_PATH"

echo "Installed aegis CLI $VERSION to $BIN_PATH"
