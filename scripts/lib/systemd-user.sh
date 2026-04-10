#!/usr/bin/env bash
# Ensure XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are set for
# systemctl --user commands. Required when running outside a full
# login session (SSH non-interactive, cron, make targets, etc.).
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
