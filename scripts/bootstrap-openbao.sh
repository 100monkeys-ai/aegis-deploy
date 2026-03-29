#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

BAO_ADDR="${BAO_ADDR:-http://localhost:8200}"
INIT_FILE="${ROOT_DIR}/generated/openbao-init.json"

export BAO_ADDR

echo "Waiting for OpenBao to start..."
until curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null | grep -qE '^(200|429|472|473|501|503)$'; do
    sleep 2
done

# Get health status code
HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")

echo "OpenBao health status: ${HEALTH_CODE}"

# --- Initialize if needed (501 = not initialized) ---
if [[ "$HEALTH_CODE" == "501" ]]; then
    echo "Initializing OpenBao..."

    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is required for initialization. Run 'sudo apt-get install -y jq'."
        exit 1
    fi

    INIT_RESPONSE=$(curl -s "${BAO_ADDR}/v1/sys/init" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d '{"secret_shares": 1, "secret_threshold": 1}')

    mkdir -p "$(dirname "$INIT_FILE")"
    echo "$INIT_RESPONSE" > "$INIT_FILE"
    chmod 600 "$INIT_FILE"

    UNSEAL_KEY=$(echo "$INIT_RESPONSE" | jq -r '.keys[0]')
    ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')

    echo "OpenBao initialized. Init data saved to ${INIT_FILE}"

    # Re-check health after init
    HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
fi

# --- Unseal if needed (503 = sealed) ---
if [[ "$HEALTH_CODE" == "503" ]]; then
    echo "Unsealing OpenBao..."

    if [[ ! -f "$INIT_FILE" ]]; then
        echo "Error: OpenBao is sealed but no init file found at ${INIT_FILE}"
        echo "If this is a fresh install, delete the openbao-data volume and redeploy."
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is required. Run 'sudo apt-get install -y jq'."
        exit 1
    fi

    UNSEAL_KEY=$(jq -r '.keys[0]' "$INIT_FILE")
    ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")

    curl -s "${BAO_ADDR}/v1/sys/unseal" \
        -X PUT \
        -H "Content-Type: application/json" \
        -d "{\"key\": \"${UNSEAL_KEY}\"}" > /dev/null

    echo "OpenBao unsealed"

    # Re-check health
    HEALTH_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
fi

# --- Verify we're healthy (200 = initialized, unsealed, active) ---
if [[ "$HEALTH_CODE" != "200" ]]; then
    echo "Error: OpenBao is not healthy after init/unseal (status: ${HEALTH_CODE})"
    exit 1
fi

echo "OpenBao is healthy"

# Load root token
if [[ -z "${ROOT_TOKEN:-}" ]]; then
    if [[ ! -f "$INIT_FILE" ]]; then
        echo "Error: No root token and no init file at ${INIT_FILE}"
        exit 1
    fi
    ROOT_TOKEN=$(jq -r '.root_token' "$INIT_FILE")
fi

export BAO_TOKEN="$ROOT_TOKEN"

# --- Configure AppRole (idempotent) ---
bao auth enable approle 2>/dev/null || true

bao policy write aegis-platform - <<'EOF'
path "secret/data/aegis/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/aegis/*" {
  capabilities = ["list", "read", "delete"]
}
EOF

bao write auth/approle/role/aegis-platform \
    token_policies="aegis-platform" \
    token_ttl=1h \
    token_max_ttl=4h

# Enable KV v2 secrets engine (idempotent)
bao secrets enable -path=secret -version=2 kv 2>/dev/null || true

# Get credentials
ROLE_ID=$(bao read -field=role_id auth/approle/role/aegis-platform/role-id)
SECRET_ID=$(bao write -field=secret_id -f auth/approle/role/aegis-platform/secret-id)

mkdir -p "${ROOT_DIR}/generated"
cat > "${ROOT_DIR}/generated/openbao-approle.env" <<EOL
OPENBAO_ROLE_ID=$ROLE_ID
OPENBAO_SECRET_ID=$SECRET_ID
EOL

echo "AppRole configured. Credentials written to generated/openbao-approle.env"

# Update .env
ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    for kv in "OPENBAO_ROLE_ID=${ROLE_ID}" "OPENBAO_SECRET_ID=${SECRET_ID}"; do
        key="${kv%%=*}"
        if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
            sed -i "s|^${key}=.*|${kv}|" "$ENV_FILE"
        else
            echo "$kv" >> "$ENV_FILE"
        fi
    done
    echo "Updated .env with AppRole credentials"
fi

# Multi-Tenant Secret Namespacing (ADR-056)
for tenant_slug in aegis-system; do
    bao kv put "secret/aegis/tenants/${tenant_slug}/_meta" \
        provisioned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >/dev/null 2>&1 || true
    echo "Provisioned secret namespace for tenant: ${tenant_slug}"
done

echo "OpenBao bootstrap complete"
