#!/usr/bin/env bash
set -euo pipefail

NETWORK_BACKEND="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || echo "cni")"

create_network() {
    local name="$1"
    if podman network exists "$name"; then
        echo "Network $name already exists, skipping."
        return
    fi
    echo "Creating $name (backend: ${NETWORK_BACKEND})..."
    podman network create "$name"
}

create_network aegis-network

echo "Networks ready."
