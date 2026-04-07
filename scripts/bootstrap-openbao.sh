#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env so OIDC_CLIENT_SECRET and other env vars are available
ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

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

# --- Configure OIDC Auth Method for human admin access (ADR-041, idempotent) ---
KEYCLOAK_URL="${KEYCLOAK_URL:-${KEYCLOAK_PUBLIC_URL:-https://auth.aegis.local}}"
AEGIS_REALM="${AEGIS_REALM:-aegis-system}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-aegis-openbao}"
# OIDC_CLIENT_SECRET must be set in the calling environment — no safe default
if [[ -z "${OIDC_CLIENT_SECRET:-}" ]]; then
    echo "Error: OIDC_CLIENT_SECRET must be set in the calling environment"
    echo "  Set it in .env or export it before running make bootstrap-secrets"
    exit 1
fi

bao auth enable oidc 2>/dev/null || true

bao write auth/oidc/config \
    oidc_discovery_url="${KEYCLOAK_URL}/realms/${AEGIS_REALM}" \
    oidc_client_id="${OIDC_CLIENT_ID}" \
    oidc_client_secret="${OIDC_CLIENT_SECRET}" \
    default_role="platform-admin"

bao write auth/oidc/role/platform-admin \
    role_type="oidc" \
    bound_audiences="${OIDC_CLIENT_ID}" \
    user_claim="sub" \
    policies="aegis-platform-admin" \
    allowed_redirect_uris="${BAO_ADDR}/ui/vault/auth/oidc/oidc/callback"

bao policy write aegis-platform-admin - <<'POLICY'
path "secret/data/*" { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/*" { capabilities = ["list","read","delete"] }
path "pki/*" { capabilities = ["create","read","update","delete","list"] }
path "auth/*" { capabilities = ["read","list"] }
path "sys/policies/*" { capabilities = ["read","list"] }
POLICY

echo "OIDC auth configured (realm: ${AEGIS_REALM})"

# Get or generate AppRole credentials (idempotent: validate before generating)
APPROLE_ENV="${ROOT_DIR}/generated/openbao-approle.env"
CREDENTIALS_VALID=false

if [[ -f "$APPROLE_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$APPROLE_ENV"
    if [[ -n "${OPENBAO_ROLE_ID:-}" && -n "${OPENBAO_SECRET_ID:-}" ]]; then
        if bao write -field=client_token auth/approle/login \
            role_id="${OPENBAO_ROLE_ID}" \
            secret_id="${OPENBAO_SECRET_ID}" >/dev/null 2>&1; then
            ROLE_ID="$OPENBAO_ROLE_ID"
            SECRET_ID="$OPENBAO_SECRET_ID"
            CREDENTIALS_VALID=true
            echo "AppRole credentials are valid, skipping generation"
        fi
    fi
fi

if [[ "$CREDENTIALS_VALID" == "false" ]]; then
    ROLE_ID=$(bao read -field=role_id auth/approle/role/aegis-platform/role-id)
    SECRET_ID=$(bao write -field=secret_id -f auth/approle/role/aegis-platform/secret-id)

    mkdir -p "${ROOT_DIR}/generated"
    cat > "$APPROLE_ENV" <<EOL
OPENBAO_ROLE_ID=$ROLE_ID
OPENBAO_SECRET_ID=$SECRET_ID
EOL
    chmod 600 "$APPROLE_ENV"
    echo "AppRole credentials generated. Written to generated/openbao-approle.env"

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
fi

# Multi-Tenant Secret Namespacing (ADR-056, idempotent: skip if already provisioned)
for tenant_slug in zaru-consumer aegis-system; do
    if ! bao kv get "secret/aegis/tenants/${tenant_slug}/_meta" >/dev/null 2>&1; then
        bao kv put "secret/aegis/tenants/${tenant_slug}/_meta" \
            provisioned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            >/dev/null
        echo "Provisioned secret namespace for tenant: ${tenant_slug}"
    else
        echo "Secret namespace already exists for tenant: ${tenant_slug}, skipping"
    fi
done

echo "OpenBao bootstrap complete"
