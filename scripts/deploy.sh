#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE="${1:-development}"
PODS_DIR="$ROOT_DIR/podman/pods"

# shellcheck source=lib/systemd-user.sh
source "$SCRIPT_DIR/lib/systemd-user.sh"

# Load environment
if [[ -f "$ROOT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

# Load profile
PROFILE_FILE="$ROOT_DIR/profiles/${PROFILE}.conf"
if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "ERROR: Profile '$PROFILE' not found at $PROFILE_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_FILE"

echo "Deploying profile: $PROFILE"
echo "Pods: $PODS"

# Ensure networks exist
bash "$ROOT_DIR/podman/networks/create-networks.sh"

# Start FUSE daemon before pods (host-side, ADR-107)
echo "  -> Starting FUSE daemon..."
systemctl --user restart aegis-fuse-daemon || true
echo "  -> FUSE daemon started"

# Deploy each pod in order
for pod in $PODS; do
    POD_DIR="$PODS_DIR/$pod"

    # Find the primary pod YAML
    POD_FILE=$(find "$POD_DIR" -name "pod-*.yaml" -type f | head -1)
    if [[ -z "$POD_FILE" ]]; then
        echo "WARNING: No pod YAML found in $POD_DIR, skipping."
        continue
    fi

    echo "  -> Deploying pod: $pod ($POD_FILE)"

    # Substitute environment variables and deploy
    envsubst < "$POD_FILE" | podman play kube --network aegis-network --replace -

    echo "  -> Pod $pod deployed."

    # Post-deploy hooks
    if [[ "$pod" == "secrets" ]]; then
        echo "  -> Bootstrapping OpenBao..."
        bash "$ROOT_DIR/scripts/bootstrap-openbao.sh"
        # Re-source .env to pick up AppRole credentials for subsequent pods
        set -a
        # shellcheck source=/dev/null
        source "$ROOT_DIR/.env"
        set +a
        echo "  -> OpenBao bootstrapped and .env reloaded"
    fi
done

echo ""
echo "Deployment complete. Run 'make status' to verify."
