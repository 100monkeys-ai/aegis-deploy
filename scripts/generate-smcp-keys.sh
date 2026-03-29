#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"
KEYS_DIR="$SCRIPT_DIR/../generated/smcp"
mkdir -p "$KEYS_DIR"

# --- SMCP RSA Keypair ---
if [[ -f "$KEYS_DIR/private.pem" ]]; then
    echo "SMCP keys already exist at $KEYS_DIR — skipping generation."
else
    echo "Generating SMCP RSA keypair..."
    openssl genpkey -algorithm RSA -out "$KEYS_DIR/private.pem" -pkeyopt rsa_keygen_bits:2048
    openssl rsa -in "$KEYS_DIR/private.pem" -pubout -out "$KEYS_DIR/public.pem"
    echo "SMCP keys generated:"
    echo "  Private: $KEYS_DIR/private.pem"
    echo "  Public:  $KEYS_DIR/public.pem"
fi

# Append AEGIS_SMCP_PRIVATE_KEY to .env (raw PEM with \n escapes)
if [[ -f "$ENV_FILE" ]] && grep -q '^AEGIS_SMCP_PRIVATE_KEY=' "$ENV_FILE"; then
    echo "AEGIS_SMCP_PRIVATE_KEY already set in .env — skipping."
else
    ESCAPED_KEY=$(awk 'NF {printf "%s\\n", $0}' "$KEYS_DIR/private.pem")
    if [[ -f "$ENV_FILE" ]]; then
        echo "AEGIS_SMCP_PRIVATE_KEY=\"$ESCAPED_KEY\"" >> "$ENV_FILE"
        echo "Appended AEGIS_SMCP_PRIVATE_KEY to .env"
    else
        echo "No .env file found — copy .env.example to .env first."
        exit 1
    fi
fi
