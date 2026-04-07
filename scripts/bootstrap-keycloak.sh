#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Keycloak realms, clients, and test users for AEGIS platform
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Source .env so KEYCLOAK_ADMIN_PASSWORD, KEYCLOAK_HOST, etc. are available
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# KEYCLOAK_HOST is the pod-network address (aegis-iam:8180), not reachable from
# the host where this script runs. Always use localhost since Keycloak binds hostPort.
KEYCLOAK_URL="http://localhost:8180"
ADMIN_USER="${KEYCLOAK_ADMIN:-admin}"
ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="${KEYCLOAK_REALM:-zaru-consumer}"
SESSION_IDLE_TIMEOUT="${KEYCLOAK_SESSION_IDLE_TIMEOUT:-1800}"

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

# Create realm with registration, email verification, and password reset enabled
POSTMARK_FROM="${POSTMARK_FROM_EMAIL:-noreply@myzaru.com}"
curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"realm\": \"$REALM\",
        \"enabled\": true,
        \"registrationAllowed\": true,
        \"registrationEmailAsUsername\": true,
        \"verifyEmail\": true,
        \"resetPasswordAllowed\": true,
        \"loginWithEmailAllowed\": true,
        \"duplicateEmailsAllowed\": false,
        \"ssoSessionIdleTimeout\": $SESSION_IDLE_TIMEOUT,
        \"smtpServer\": {
            \"host\": \"smtp.postmarkapp.com\",
            \"port\": \"587\",
            \"auth\": true,
            \"starttls\": true,
            \"user\": \"${POSTMARK_SERVER_TOKEN}\",
            \"password\": \"${POSTMARK_SERVER_TOKEN}\",
            \"from\": \"$POSTMARK_FROM\",
            \"fromDisplayName\": \"Zaru by 100monkeys.ai\"
        }
    }" || true

# Update realm if it already exists (idempotent)
curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$REALM" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"registrationAllowed\": true,
        \"registrationEmailAsUsername\": true,
        \"verifyEmail\": true,
        \"resetPasswordAllowed\": true,
        \"loginWithEmailAllowed\": true,
        \"duplicateEmailsAllowed\": false,
        \"ssoSessionIdleTimeout\": $SESSION_IDLE_TIMEOUT,
        \"smtpServer\": {
            \"host\": \"smtp.postmarkapp.com\",
            \"port\": \"587\",
            \"auth\": true,
            \"starttls\": true,
            \"user\": \"${POSTMARK_SERVER_TOKEN}\",
            \"password\": \"${POSTMARK_SERVER_TOKEN}\",
            \"from\": \"$POSTMARK_FROM\",
            \"fromDisplayName\": \"Zaru by 100monkeys.ai\"
        }
    }" || true

# Create OIDC client
ZARU_REDIRECT_URL="${ZARU_PUBLIC_URL:-http://localhost:3000}"
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"clientId\": \"zaru-client\",
        \"enabled\": true,
        \"publicClient\": false,
        \"clientAuthenticatorType\": \"client-secret\",
        \"directAccessGrantsEnabled\": true,
        \"redirectUris\": [\"${ZARU_REDIRECT_URL}/*\"],
        \"webOrigins\": [\"${ZARU_REDIRECT_URL}\"],
        \"protocolMappers\": [{
            \"name\": \"zaru_tier\",
            \"protocol\": \"openid-connect\",
            \"protocolMapper\": \"oidc-usermodel-attribute-mapper\",
            \"config\": {
                \"user.attribute\": \"zaru_tier\",
                \"claim.name\": \"zaru_tier\",
                \"id.token.claim\": \"true\",
                \"access.token.claim\": \"true\",
                \"userinfo.token.claim\": \"true\"
            }
        }]
    }" || true

# Extract the Zaru client secret from Keycloak
ZARU_CLIENT_INTERNAL_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/clients?clientId=zaru-client" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')

# --- tenant_id protocol mapper (ADR-097: per-user tenant provisioning) ---
curl -sS -X POST "$KEYCLOAK_URL/admin/realms/$REALM/clients/$ZARU_CLIENT_INTERNAL_ID/protocol-mappers/models" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "tenant_id",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "config": {
      "user.attribute": "tenant_id",
      "claim.name": "tenant_id",
      "jsonType.label": "String",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "userinfo.token.claim": "true"
    }
  }' || true

ZARU_OIDC_CLIENT_SECRET=$(curl -sf "$KEYCLOAK_URL/admin/realms/$REALM/clients/$ZARU_CLIENT_INTERNAL_ID/client-secret" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.value')

export ZARU_OIDC_CLIENT_SECRET
echo "Zaru OIDC client secret exported as ZARU_OIDC_CLIENT_SECRET"

# Write the secret to the .env file so it persists across sessions
if grep -q '^ZARU_OIDC_CLIENT_SECRET=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^ZARU_OIDC_CLIENT_SECRET=.*|ZARU_OIDC_CLIENT_SECRET=$ZARU_OIDC_CLIENT_SECRET|" "$ENV_FILE"
    echo "Updated ZARU_OIDC_CLIENT_SECRET in $ENV_FILE"
else
    echo "ZARU_OIDC_CLIENT_SECRET=$ZARU_OIDC_CLIENT_SECRET" >> "$ENV_FILE"
    echo "Appended ZARU_OIDC_CLIENT_SECRET to $ENV_FILE"
fi

# Create test users
for tier in free pro business enterprise; do
    PASS_VAR="TEST_USER_${tier^^}_PASSWORD"
    PASS="${!PASS_VAR:-${tier}123}"
    curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"$tier\",
            \"enabled\": true,
            \"attributes\": {\"zaru_tier\": [\"$tier\"]},
            \"credentials\": [{\"type\": \"password\", \"value\": \"$PASS\", \"temporary\": false}]
        }" || true
done

# ---------------------------------------------------------------------------
# Multi-Tenant Bootstrap (ADR-056)
# Ensure the aegis-system realm exists for platform service-accounts.
# ---------------------------------------------------------------------------
SYSTEM_REALM="${KEYCLOAK_SYSTEM_REALM:-aegis-system}"

curl -sf -X POST "$KEYCLOAK_URL/admin/realms" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"realm\": \"$SYSTEM_REALM\", \"enabled\": true}" || true

# Create orchestrator service-account client in the system realm
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

# Create temporal-worker service-account client in the system realm
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "clientId": "aegis-temporal-worker",
        "enabled": true,
        "publicClient": false,
        "serviceAccountsEnabled": true,
        "directAccessGrantsEnabled": false
    }' || true

TEMPORAL_WORKER_INTERNAL_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients?clientId=aegis-temporal-worker" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')

# Add audience protocol mapper so tokens carry aud=aegis-orchestrator (required by gRPC JWT validation)
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients/$TEMPORAL_WORKER_INTERNAL_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "aegis-orchestrator-audience",
        "protocol": "openid-connect",
        "protocolMapper": "oidc-audience-mapper",
        "config": {
            "included.client.audience": "aegis-orchestrator",
            "id.token.claim": "false",
            "access.token.claim": "true"
        }
    }' || true

KEYCLOAK_TEMPORAL_WORKER_SECRET=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients/$TEMPORAL_WORKER_INTERNAL_ID/client-secret" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.value')

if grep -q '^KEYCLOAK_TEMPORAL_WORKER_SECRET=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^KEYCLOAK_TEMPORAL_WORKER_SECRET=.*|KEYCLOAK_TEMPORAL_WORKER_SECRET=$KEYCLOAK_TEMPORAL_WORKER_SECRET|" "$ENV_FILE"
    echo "Updated KEYCLOAK_TEMPORAL_WORKER_SECRET in $ENV_FILE"
else
    echo "KEYCLOAK_TEMPORAL_WORKER_SECRET=$KEYCLOAK_TEMPORAL_WORKER_SECRET" >> "$ENV_FILE"
    echo "Appended KEYCLOAK_TEMPORAL_WORKER_SECRET to $ENV_FILE"
fi

# Create aegis-openbao OIDC client in the system realm (ADR-041)
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "clientId": "aegis-openbao",
        "enabled": true,
        "publicClient": false,
        "clientAuthenticatorType": "client-secret",
        "directAccessGrantsEnabled": false,
        "standardFlowEnabled": true
    }' || true

OPENBAO_CLIENT_INTERNAL_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients?clientId=aegis-openbao" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')

OIDC_CLIENT_SECRET=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients/$OPENBAO_CLIENT_INTERNAL_ID/client-secret" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.value')

if grep -q '^OIDC_CLIENT_SECRET=' "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^OIDC_CLIENT_SECRET=.*|OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET|" "$ENV_FILE"
    echo "Updated OIDC_CLIENT_SECRET in $ENV_FILE"
else
    echo "OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET" >> "$ENV_FILE"
    echo "Appended OIDC_CLIENT_SECRET to $ENV_FILE"
fi

# ---------------------------------------------------------------------------
# aegis-cli OIDC Client (ADR-093: AEGIS CLI Authentication Flow)
# Public client with Device Authorization Grant for interactive CLI login.
# ---------------------------------------------------------------------------

# Create realm roles for the system realm (aegis:admin, aegis:operator, aegis:readonly)
for role in "aegis:admin" "aegis:operator" "aegis:readonly"; do
    curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/roles" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$role\", \"description\": \"AEGIS $role role\"}" || true
done

# Create aegis-cli public OIDC client with Device Authorization Grant enabled
curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{
        "clientId": "aegis-cli",
        "enabled": true,
        "publicClient": true,
        "standardFlowEnabled": false,
        "implicitFlowEnabled": false,
        "directAccessGrantsEnabled": false,
        "serviceAccountsEnabled": false,
        "attributes": {
            "oauth2.device.authorization.grant.enabled": "true"
        },
        "defaultClientScopes": ["openid", "profile", "offline_access"],
        "optionalClientScopes": ["aegis:admin", "aegis:operator", "aegis:readonly"]
    }' || true

# ---------------------------------------------------------------------------
# resource:action Client Scopes (ADR-093 §Sub-Decision 8)
# Register all 68 fine-grained scopes in the system realm and attach them
# to the aegis-cli client as optional scopes.
# ---------------------------------------------------------------------------

AEGIS_CLI_INTERNAL_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients?clientId=aegis-cli" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[0].id')

RESOURCE_ACTION_SCOPES=(
    "agent:deploy" "agent:read" "agent:list" "agent:execute" "agent:generate" "agent:logs" "agent:delete"
    "workflow:deploy" "workflow:read" "workflow:list" "workflow:run" "workflow:validate" "workflow:generate"
    "workflow:logs" "workflow:signal" "workflow:cancel" "workflow:delete"
    "execution:read" "execution:list" "execution:stream" "execution:logs" "execution:cancel" "execution:remove"
    "swarm:read" "swarm:list" "swarm:cancel"
    "secret:read" "secret:write" "secret:list" "secret:delete" "secret:rotate"
    "credential:read" "credential:list" "credential:create" "credential:delete" "credential:rotate" "credential:grant"
    "approval:read" "approval:list" "approval:approve" "approval:reject"
    "stimulus:ingest"
    "node:read" "node:list" "node:register" "node:deregister" "node:drain" "node:shutdown"
    "stack:read" "stack:up" "stack:down" "stack:restart" "stack:update" "stack:uninstall"
    "key:read" "key:list" "key:create" "key:revoke"
    "tenant:read" "tenant:list" "tenant:onboard" "tenant:provision"
)

for scope in "${RESOURCE_ACTION_SCOPES[@]}"; do
    # Create the client scope
    SCOPE_ID=$(curl -sf -X POST "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/client-scopes" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"$scope\",
            \"description\": \"Fine-grained scope: $scope\",
            \"protocol\": \"openid-connect\",
            \"attributes\": {
                \"include.in.token.scope\": \"true\",
                \"display.on.consent.screen\": \"false\"
            }
        }" 2>/dev/null | jq -r '.id // empty' || true)

    # If scope already exists, fetch its ID
    if [[ -z "$SCOPE_ID" ]]; then
        SCOPE_ID=$(curl -sf "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/client-scopes" \
            -H "Authorization: Bearer $TOKEN" | jq -r --arg name "$scope" '.[] | select(.name == $name) | .id' || true)
    fi

    # Attach the scope to aegis-cli as an optional scope
    if [[ -n "$SCOPE_ID" && -n "$AEGIS_CLI_INTERNAL_ID" ]]; then
        curl -sf -X PUT "$KEYCLOAK_URL/admin/realms/$SYSTEM_REALM/clients/$AEGIS_CLI_INTERNAL_ID/optional-client-scopes/$SCOPE_ID" \
            -H "Authorization: Bearer $TOKEN" || true
    fi
done

echo "Keycloak bootstrap complete (consumer realm: $REALM, system realm: $SYSTEM_REALM)."
