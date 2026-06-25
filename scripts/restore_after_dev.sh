#!/usr/bin/env bash
#
# restore_after_dev.sh
#
# Stops dev_safe_mode.sh and re-enables the network services it disabled.

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/dev_safe_state"
LOG_FILE="$STATE_DIR/dev_safe_mode.log"
PID_FILE="$STATE_DIR/monitor.pid"

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

enable_service_if_present() {
  local service="$1"
  if networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$service"; then
    log "Re-enabling network service: $service"
    networksetup -setnetworkserviceenabled "$service" on >> "$LOG_FILE" 2>&1 || true
  fi
}

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    log "Stopping dev safe monitor pid $pid"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
fi

enable_service_if_present "USB ACM"
enable_service_if_present "USB 10/100 LAN"
enable_service_if_present "Thunderbolt Bridge"
enable_service_if_present "iPhone USB"

rm -f "$STATE_DIR/ACTIVE_DEV_SAFE_MODE.txt"
log "Restore complete"
