#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Keycloak realms and service accounts for AEGIS platform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

KEYCLOAK_URL="http://localhost:8180"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
SYSTEM_REALM="${KEYCLOAK_REALM:-aegis-system}"

echo "Waiting for Keycloak..."
until curl -sf "$KEYCLOAK_URL/health/ready" > /dev/null 2>&1; do
    sleep 2
done
echo "Keycloak is ready."

# Get admin token
TOKEN=$(curl -sf -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=$ADMIN_USER" \
    -d "password=$ADMIN_PASS" \
    -d "grant_type=password" | jq -r '.access_token')

# Create system realm
curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"realm\": \"$SYSTEM_REALM\", \"enabled\": true}" || true

# Create orchestrator service-account client
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "clientId": "aegis-orchestrator",
        "enabled": true,
        "publicClient": false,
        "serviceAccountsEnabled": true,
        "directAccessGrantsEnabled": false
    }' || true

echo "Keycloak bootstrap complete (system realm: $SYSTEM_REALM)."
