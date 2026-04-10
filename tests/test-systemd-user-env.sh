#!/usr/bin/env bash
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/systemd-user.sh"
PASS=0
FAIL=0
run_test() {
    local name="$1"; shift
    if "$@"; then echo "  PASS: $name"; PASS=$((PASS + 1))
    else echo "  FAIL: $name"; FAIL=$((FAIL + 1)); fi
}
test_clean_env() { (unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; source "$LIB"; [[ "$XDG_RUNTIME_DIR" == "/run/user/$(id -u)" ]] && [[ "$DBUS_SESSION_BUS_ADDRESS" == "unix:path=/run/user/$(id -u)/bus" ]]); }
test_preserve_existing() { (export XDG_RUNTIME_DIR="/custom/runtime"; export DBUS_SESSION_BUS_ADDRESS="unix:path=/custom/bus"; source "$LIB"; [[ "$XDG_RUNTIME_DIR" == "/custom/runtime" ]] && [[ "$DBUS_SESSION_BUS_ADDRESS" == "unix:path=/custom/bus" ]]); }
test_bus_references_xdg() { (unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; source "$LIB"; [[ "$DBUS_SESSION_BUS_ADDRESS" == *"$XDG_RUNTIME_DIR"* ]]); }
echo "Running systemd-user-env regression tests..."
run_test "sets vars from clean env" test_clean_env
run_test "preserves existing values" test_preserve_existing
run_test "bus path references XDG_RUNTIME_DIR" test_bus_references_xdg
echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
