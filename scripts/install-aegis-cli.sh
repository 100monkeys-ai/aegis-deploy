#!/usr/bin/env bash
# =============================================================================
# AEGIS Platform — Extract aegis CLI from container image
# =============================================================================
# Extracts the aegis binary from the already-pulled orchestrator image so the
# host-side FUSE daemon binary is always in sync with the running pod.
#
# Usage:
#   bash scripts/install-aegis-cli.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$ROOT_DIR/bin"
BIN_PATH="$BIN_DIR/aegis"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}[install-cli]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}[install-cli]${RESET} $*"; }
die()     { echo -e "${RED}${BOLD}[install-cli] ERROR:${RESET} $*" >&2; exit 1; }

# ── Load image tag from .env ─────────────────────────────────────────────────
if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

AEGIS_IMAGE_TAG="${AEGIS_IMAGE_TAG:-latest}"
IMAGE="ghcr.io/100monkeys-ai/aegis-runtime:${AEGIS_IMAGE_TAG}"

info "Extracting aegis binary from ${IMAGE}..."

# ── Pull image (no-op if already present) ────────────────────────────────────
podman pull "${IMAGE}"

# ── Extract binary via temp container (atomic rename) ────────────────────────
CONTAINER_NAME="aegis-cli-extract-$$"
podman create --name "${CONTAINER_NAME}" "${IMAGE}" >/dev/null

mkdir -p "${BIN_DIR}"

podman cp "${CONTAINER_NAME}:/usr/local/bin/aegis-runtime" "${BIN_PATH}.new"
podman rm "${CONTAINER_NAME}" >/dev/null

# Atomic swap — safe to do while old binary is running
mv "${BIN_PATH}.new" "${BIN_PATH}"
chmod 0755 "${BIN_PATH}"

# Symlink into /usr/local/bin so aegis is available system-wide
sudo ln -sf "${BIN_PATH}" /usr/local/bin/aegis

# Restart the FUSE daemon so it picks up the new binary
info "Restarting aegis-fuse-daemon..."
systemctl --user restart aegis-fuse-daemon
success "aegis-fuse-daemon restarted"

success "Installed aegis to ${BIN_PATH} and symlinked to /usr/local/bin/aegis (from ${IMAGE})"
