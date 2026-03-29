#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PROFILE="${1:-development}"

# Load profile
PROFILE_FILE="$ROOT_DIR/profiles/${PROFILE}.conf"
if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "ERROR: Profile '$PROFILE' not found"
    exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_FILE"

echo "Tearing down profile: $PROFILE"

# Reverse order teardown
PODS_REVERSED=""
for pod in $PODS; do
    PODS_REVERSED="$pod $PODS_REVERSED"
done

for pod in $PODS_REVERSED; do
    POD_NAME="aegis-${pod}"
    if podman pod exists "$POD_NAME" 2>/dev/null; then
        echo "  -> Stopping pod: $POD_NAME"
        podman pod stop "$POD_NAME" -t 30 || true
        podman pod rm "$POD_NAME" || true
    fi
done

echo "Teardown complete."
