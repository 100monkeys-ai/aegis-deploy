#!/usr/bin/env bash
# =============================================================================
# AEGIS Platform — Ubuntu Setup Script
# =============================================================================
# Bootstraps rootless Podman (>= 4.0) on Ubuntu 22.04 / 24.04.
#
# Usage:
#   bash scripts/setup-ubuntu.sh
#
# Run as a regular (non-root) user with sudo privileges.
# =============================================================================
set -euo pipefail

# ---- Colours ----------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# =============================================================================
# PHASE 1 — Preflight
# =============================================================================
info "Phase 1: Preflight checks"

[[ "$(id -u)" -eq 0 ]] && die "Do not run this script as root. Run as a regular user with sudo privileges."
command -v sudo &>/dev/null || die "'sudo' is not available. Install it and grant yourself sudo access first."

if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
else
    die "/etc/os-release not found — cannot determine OS."
fi

[[ "${ID:-}" == "ubuntu" ]] || die "This script only supports Ubuntu (detected: ${ID:-unknown})."

UBUNTU_VERSION="${VERSION_ID:-}"
case "$UBUNTU_VERSION" in
    22.04) UBUNTU_CODENAME="jammy" ;;
    24.04) UBUNTU_CODENAME="noble" ;;
    *) die "Unsupported Ubuntu version: ${UBUNTU_VERSION}. This script supports 22.04 (Jammy) and 24.04 (Noble)." ;;
esac

success "Detected Ubuntu ${UBUNTU_VERSION} (${UBUNTU_CODENAME})"

# =============================================================================
# PHASE 2 — Install Podman & runtime dependencies
# =============================================================================
info "Phase 2: Installing Podman and dependencies"

sudo apt-get update -qq

COMMON_DEPS=(uidmap slirp4netns fuse-overlayfs gettext-base make curl jq)

if [[ "$UBUNTU_VERSION" == "24.04" ]]; then
    info "Ubuntu 24.04: using native repository for Podman"
    sudo apt-get install -y podman "${COMMON_DEPS[@]}"

elif [[ "$UBUNTU_VERSION" == "22.04" ]]; then
    info "Ubuntu 22.04: adding Kubic OBS repository for Podman 4.x+"

    KUBIC_URL="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_22.04"
    KUBIC_KEY="/etc/apt/trusted.gpg.d/kubic-libcontainers.gpg"
    KUBIC_LIST="/etc/apt/sources.list.d/kubic-libcontainers.list"

    if [[ ! -f "$KUBIC_KEY" ]]; then
        curl -fsSL "${KUBIC_URL}/Release.key" \
            | gpg --dearmor \
            | sudo tee "$KUBIC_KEY" > /dev/null
        success "Kubic GPG key installed at $KUBIC_KEY"
    else
        info "Kubic GPG key already present, skipping"
    fi

    if [[ ! -f "$KUBIC_LIST" ]]; then
        echo "deb ${KUBIC_URL}/ /" \
            | sudo tee "$KUBIC_LIST" > /dev/null
        success "Kubic apt source added at $KUBIC_LIST"
    else
        info "Kubic apt source already present, skipping"
    fi

    sudo apt-get update -qq
    sudo apt-get install -y podman "${COMMON_DEPS[@]}"

    if ! dpkg -l aardvark-dns &>/dev/null 2>&1; then
        sudo apt-get install -y aardvark-dns || warn "aardvark-dns not available; DNS inside pods may not resolve service names"
    fi
fi

PODMAN_VERSION="$(podman --version | awk '{print $3}')"
PODMAN_MAJOR="${PODMAN_VERSION%%.*}"
(( PODMAN_MAJOR >= 4 )) || die "Podman ${PODMAN_VERSION} installed but >= 4.0 is required."
success "Podman ${PODMAN_VERSION} installed"

# =============================================================================
# PHASE 3 — Configure rootless storage
# =============================================================================
info "Phase 3: Configuring rootless Podman"

if ! grep -q "^${USER}:" /etc/subuid 2>/dev/null; then
    echo "${USER}:100000:65536" | sudo tee -a /etc/subuid > /dev/null
    success "Added ${USER} to /etc/subuid"
else
    info "/etc/subuid entry for ${USER} already present"
fi

if ! grep -q "^${USER}:" /etc/subgid 2>/dev/null; then
    echo "${USER}:100000:65536" | sudo tee -a /etc/subgid > /dev/null
    success "Added ${USER} to /etc/subgid"
else
    info "/etc/subgid entry for ${USER} already present"
fi

podman pod stop --all 2>/dev/null || true
podman stop --all 2>/dev/null || true
podman system migrate 2>/dev/null || true
success "Rootless storage initialised"

# Ensure FUSE kernel module is loaded (required for FSAL FUSE transport)
if ! lsmod | grep -q '^fuse\b'; then
    sudo modprobe fuse
    success "Loaded FUSE kernel module"
else
    info "FUSE kernel module already loaded"
fi
echo "fuse" | sudo tee /etc/modules-load.d/aegis-fuse.conf > /dev/null
success "Persisted FUSE kernel module across reboots"

# Enable user_allow_other in /etc/fuse.conf (required for AllowOther mount option)
if grep -q '^#user_allow_other' /etc/fuse.conf 2>/dev/null; then
    sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
    success "Enabled user_allow_other in /etc/fuse.conf"
elif grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null; then
    info "user_allow_other already enabled in /etc/fuse.conf"
else
    echo "user_allow_other" | sudo tee -a /etc/fuse.conf > /dev/null
    success "Added user_allow_other to /etc/fuse.conf"
fi

SYSCTL_KEY="net.ipv4.ip_unprivileged_port_start"
SYSCTL_VALUE="80"
SYSCTL_CONF="/etc/sysctl.conf"
if grep -q "^${SYSCTL_KEY}" "${SYSCTL_CONF}" 2>/dev/null; then
    sudo sed -i "s|^${SYSCTL_KEY}.*|${SYSCTL_KEY}=${SYSCTL_VALUE}|" "${SYSCTL_CONF}"
else
    echo "${SYSCTL_KEY}=${SYSCTL_VALUE}" | sudo tee -a "${SYSCTL_CONF}" > /dev/null
fi
sudo sysctl -w "${SYSCTL_KEY}=${SYSCTL_VALUE}" > /dev/null
success "Set ${SYSCTL_KEY}=${SYSCTL_VALUE} (rootless ports 80/443 enabled)"

# =============================================================================
# PHASE 4 — Enable systemd user socket
# =============================================================================
info "Phase 4: Enabling Podman systemd user socket"

loginctl enable-linger "${USER}"
success "Linger enabled for ${USER}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

systemctl --user daemon-reload
systemctl --user enable --now podman.socket
success "podman.socket enabled and started"

# Install FUSE daemon systemd service (ADR-107)
mkdir -p ~/.config/systemd/user
cp "$ROOT_DIR/systemd/aegis-fuse-daemon.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable aegis-fuse-daemon
# Ensure FUSE mount prefix directory exists and is owned by this user (ADR-107)
mkdir -p /tmp/aegis-fuse-mounts
chmod 755 /tmp/aegis-fuse-mounts
success "FUSE mount prefix directory ready at /tmp/aegis-fuse-mounts"
success "FUSE daemon systemd service installed and enabled"

# ── Registry login (needed to pull image for binary extraction) ───────────────
if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi
if [[ -n "${GHCR_TOKEN:-}" ]]; then
    echo "${GHCR_TOKEN}" | podman login ghcr.io --username "${GHCR_USERNAME}" --password-stdin
    success "Logged in to ghcr.io"
else
    warn "GHCR_TOKEN not set in .env — skipping registry login (binary extract will fail if image is not cached)"
fi

# Extract aegis binary from image (single source of truth, ADR-107)
info "Extracting aegis CLI from container image..."
bash "$SCRIPT_DIR/install-aegis-cli.sh"

# Start FUSE daemon now that binary is in place
systemctl --user start aegis-fuse-daemon || true
success "FUSE daemon started"

SOCKET_PATH="${XDG_RUNTIME_DIR}/podman/podman.sock"
WAITED=0
until [[ -S "$SOCKET_PATH" ]]; do
    (( WAITED >= 10 )) && die "Timed out waiting for Podman socket at ${SOCKET_PATH}"
    sleep 1
    (( WAITED++ ))
done
success "Podman socket ready at ${SOCKET_PATH}"

export CONTAINER_SOCK="$SOCKET_PATH"

# =============================================================================
# PHASE 5 — Install OpenBao CLI
# =============================================================================
info "Phase 5: Installing OpenBao CLI"

if command -v bao &>/dev/null; then
    success "bao CLI already installed: $(bao version 2>/dev/null || echo 'unknown')"
else
    info "Installing OpenBao CLI..."
    BAO_VERSION="${BAO_VERSION:-2.1.0}"
    BAO_ARCH="$(dpkg --print-architecture)"
    BAO_URL="https://github.com/openbao/openbao/releases/download/v${BAO_VERSION}/bao_${BAO_VERSION}_linux_${BAO_ARCH}.deb"
    TMP_DEB="$(mktemp)"
    curl -fsSL "$BAO_URL" -o "$TMP_DEB"
    sudo dpkg -i "$TMP_DEB"
    rm -f "$TMP_DEB"
    success "bao CLI installed: $(bao version)"
fi

# =============================================================================
# PHASE 6 — Create Podman networks
# =============================================================================
info "Phase 6: Creating Podman networks"

bash "${ROOT_DIR}/podman/networks/create-networks.sh"
success "Networks created"

# =============================================================================
# PHASE 7 — Populate .env
# =============================================================================
info "Phase 7: Populating .env"

ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -f "${ROOT_DIR}/.env.example" ]]; then
        cp "${ROOT_DIR}/.env.example" "$ENV_FILE"
        success "Created .env from .env.example"
    else
        die ".env.example not found at ${ROOT_DIR}/.env.example"
    fi
fi

if grep -q '^AEGIS_ROOT=$' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^AEGIS_ROOT=$|AEGIS_ROOT=${ROOT_DIR}|" "$ENV_FILE"
    success "Set AEGIS_ROOT=${ROOT_DIR} in .env"
elif grep -q '^AEGIS_ROOT=' "$ENV_FILE" 2>/dev/null; then
    info "AEGIS_ROOT already set in .env — skipping"
else
    echo "AEGIS_ROOT=${ROOT_DIR}" >> "$ENV_FILE"
    success "Appended AEGIS_ROOT=${ROOT_DIR} to .env"
fi

if grep -q '^CONTAINER_SOCK=$' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^CONTAINER_SOCK=$|CONTAINER_SOCK=${SOCKET_PATH}|" "$ENV_FILE"
    success "Set CONTAINER_SOCK=${SOCKET_PATH} in .env"
elif grep -q '^CONTAINER_SOCK=' "$ENV_FILE" 2>/dev/null; then
    info "CONTAINER_SOCK already set in .env — skipping"
else
    echo "CONTAINER_SOCK=${SOCKET_PATH}" >> "$ENV_FILE"
    success "Appended CONTAINER_SOCK=${SOCKET_PATH} to .env"
fi

# =============================================================================
# PHASE 8 — Post-install summary
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  AEGIS Platform — Setup Complete${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo ""
echo -e "  ${BOLD}Podman version:${RESET}     ${PODMAN_VERSION}"
echo -e "  ${BOLD}Socket path:${RESET}        ${SOCKET_PATH}"
echo ""
echo -e "${BOLD}Next steps:${RESET}"
echo ""
echo -e "  1. Review your ${BOLD}.env${RESET} file (auto-populated with AEGIS_ROOT and CONTAINER_SOCK):"
echo -e "     ${CYAN}\$EDITOR .env${RESET}"
echo ""
echo -e "  2. Deploy the platform:"
echo -e "     ${CYAN}make deploy PROFILE=development${RESET}"
echo ""
