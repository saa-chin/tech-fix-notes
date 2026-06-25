#!/usr/bin/env bash
#
# dev_safe_mode.sh
#
# Runtime workaround for an Apple silicon kernel panic that only triggered
# under a heavy developer workload (IntelliJ indexing while Cursor is open)
# on an external-display / Thunderbolt-dock setup.
#
# It does two things while active:
#   1. Disables dock-related network/serial services (kept off Wi-Fi route).
#   2. Continuously throttles IDE/indexing processes (renice + taskpolicy -b).
#
# This is NOT a kernel fix. It reduces the burst that appears to trip the bug.
# Reverse it with restore_after_dev.sh.

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/dev_safe_state"
LOG_FILE="$STATE_DIR/dev_safe_mode.log"
PID_FILE="$STATE_DIR/monitor.pid"
INTERVAL="${INTERVAL:-10}"
NICE_VALUE="${NICE_VALUE:-15}"

mkdir -p "$STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

disable_service_if_present() {
  local service="$1"
  if networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$service"; then
    log "Disabling network service: $service"
    networksetup -setnetworkserviceenabled "$service" off >> "$LOG_FILE" 2>&1 || true
  fi
}

throttle_pid() {
  local pid="$1"
  local name="$2"
  if [[ -z "$pid" || "$pid" == "$$" ]]; then
    return
  fi
  renice "$NICE_VALUE" -p "$pid" >> "$LOG_FILE" 2>&1 || true
  taskpolicy -b -p "$pid" >> "$LOG_FILE" 2>&1 || true
  log "Throttled pid=$pid name=$name"
}

throttle_matching_processes() {
  ps ax -o pid=,comm=,args= | awk '
    /IntelliJ IDEA|idea|fsnotifier|jetbrains|java|Cursor|Electron/ &&
    !/dev_safe_mode.sh/ &&
    !/awk/ {print}
  ' | while read -r pid comm rest; do
    throttle_pid "$pid" "$comm"
  done
}

write_marker() {
  {
    echo "dev_safe_mode_started_at=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "interval_seconds=$INTERVAL"
    echo "nice_value=$NICE_VALUE"
    echo "disabled_services=USB ACM, USB 10/100 LAN, Thunderbolt Bridge, iPhone USB"
    echo "throttled_process_patterns=IntelliJ IDEA, idea, fsnotifier, jetbrains, java, Cursor, Electron"
  } > "$STATE_DIR/ACTIVE_DEV_SAFE_MODE.txt"
}

monitor_loop() {
  log "Monitor loop started"
  while true; do
    throttle_matching_processes
    sleep "$INTERVAL"
  done
}

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  log "Dev safe mode already running with pid $(cat "$PID_FILE")"
  exit 0
fi

log "Starting dev safe mode"
networksetup -listallnetworkservices > "$STATE_DIR/network_services_before.txt" 2>&1
ifconfig -a > "$STATE_DIR/ifconfig_before.txt" 2>&1
write_marker

disable_service_if_present "USB ACM"
disable_service_if_present "USB 10/100 LAN"
disable_service_if_present "Thunderbolt Bridge"
disable_service_if_present "iPhone USB"

throttle_matching_processes
monitor_loop &
echo "$!" > "$PID_FILE"

log "Dev safe mode active. Monitor pid $(cat "$PID_FILE")"
log "When done, run: $ROOT_DIR/restore_after_dev.sh"
