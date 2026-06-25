#!/usr/bin/env bash
#
# check_dev_safe_state.sh
#
# Shows whether dev safe mode is active, the monitor status, the niceness of
# relevant processes, and current network services.

set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/dev_safe_state"

echo "=== Dev safe marker ==="
if [[ -f "$STATE_DIR/ACTIVE_DEV_SAFE_MODE.txt" ]]; then
  cat "$STATE_DIR/ACTIVE_DEV_SAFE_MODE.txt"
else
  echo "Not active"
fi

echo
echo "=== Monitor ==="
if [[ -f "$STATE_DIR/monitor.pid" ]] && kill -0 "$(cat "$STATE_DIR/monitor.pid")" 2>/dev/null; then
  echo "Running pid $(cat "$STATE_DIR/monitor.pid")"
else
  echo "Not running"
fi

echo
echo "=== Relevant processes ==="
ps ax -o pid=,ni=,stat=,comm=,args= | awk '
  /IntelliJ IDEA|idea|fsnotifier|jetbrains|java|Cursor|Electron/ &&
  !/check_dev_safe_state.sh/ &&
  !/awk/ {print}
'

echo
echo "=== Network services ==="
networksetup -listallnetworkservices
