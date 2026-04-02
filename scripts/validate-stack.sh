#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

check() {
    local name="$1" url="$2"
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} $name"
    else
        echo -e "  ${RED}✗${NC} $name ($url)"
    fi
}

echo "Validating AEGIS platform services..."
echo ""

echo "Database:"
check "PostgreSQL" "localhost:5432"

echo "Core:"
check "AEGIS Runtime" "http://localhost:8088/health"

echo "Temporal:"
check "Temporal Server" "http://localhost:7233"
check "Temporal UI" "http://localhost:8233"

echo "Gateways:"
check "SEAL Gateway" "http://localhost:8089"

echo "IAM & Secrets:"
check "Keycloak" "http://localhost:8180/health/ready"
check "OpenBao" "http://localhost:8200/v1/sys/health"

echo "Observability:"
check "Jaeger UI" "http://localhost:16686"
check "Prometheus" "http://localhost:9090/-/ready"
check "Grafana" "http://localhost:3300/api/health"
check "Loki" "http://localhost:3100/ready"

echo "Storage:"
check "SeaweedFS Master" "http://localhost:9333"
check "SeaweedFS Filer" "http://localhost:8888"

echo ""
echo "Run 'make status' for pod-level status."
