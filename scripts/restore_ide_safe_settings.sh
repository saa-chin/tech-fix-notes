#!/usr/bin/env bash
#
# restore_ide_safe_settings.sh
#
# Restores the most recent backups created by apply_ide_safe_settings.sh.
# Pass a specific stamp to restore a particular backup:
#   ./restore_ide_safe_settings.sh 20260101_120000

set -u

STAMP="${1:-}"
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
JETBRAINS_DIR="$HOME/Library/Application Support/JetBrains"

restore_one() {
  local target="$1"
  local backup
  if [[ -n "$STAMP" ]]; then
    backup="$target.bak-$STAMP"
  else
    backup="$(ls -1t "$target".bak-* 2>/dev/null | head -n 1)"
  fi

  if [[ -n "$backup" && -f "$backup" ]]; then
    cp "$backup" "$target"
    echo "Restored $target from $(basename "$backup")"
  else
    echo "No backup found for $target - skipping."
  fi
}

restore_one "$CURSOR_SETTINGS"

if [[ -d "$JETBRAINS_DIR" ]]; then
  while IFS= read -r dir; do
    restore_one "$dir/idea.vmoptions"
  done < <(find "$JETBRAINS_DIR" -maxdepth 1 -type d -name 'IntelliJIdea*')
fi

echo "Restore complete. Fully quit and reopen the IDEs."
