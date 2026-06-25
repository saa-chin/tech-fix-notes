#!/usr/bin/env bash
#
# apply_ide_safe_settings.sh
#
# Applies the "lower the pressure" IDE settings that stabilized an Apple
# silicon Mac that kernel-panicked under heavy Cursor + IntelliJ workloads
# on an external-display / Thunderbolt-dock setup.
#
# It is reversible: every file it touches is backed up with a timestamp
# suffix before any change. See restore_ide_safe_settings.sh to roll back.
#
# Safe to re-run. Requires: bash, and jq for the Cursor part.

set -u

STAMP="$(date '+%Y%m%d_%H%M%S')"
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
JETBRAINS_DIR="$HOME/Library/Application Support/JetBrains"

INTELLIJ_OPTS=(
  "-Dsun.java2d.metal=false"
  "-Dsun.java2d.opengl=false"
  "-Dide.mac.message.dialogs.as.sheets=false"
  "-Didea.max.intellisense.filesize=2500"
  "-Didea.indexing.threads=2"
  "-Djava.util.concurrent.ForkJoinPool.common.parallelism=4"
)

apply_cursor() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found - skipping Cursor settings. Install jq, or edit settings.json by hand."
    return
  fi

  mkdir -p "$(dirname "$CURSOR_SETTINGS")"
  [[ -f "$CURSOR_SETTINGS" ]] || echo '{}' > "$CURSOR_SETTINGS"
  cp "$CURSOR_SETTINGS" "$CURSOR_SETTINGS.bak-$STAMP"

  local tmp
  tmp="$(mktemp)"
  jq '. * {
    "cursor.general.gitGraphIndexing": "disabled",
    "search.followSymlinks": false,
    "search.useIgnoreFiles": true,
    "search.useGlobalIgnoreFiles": true,
    "files.watcherExclude": {
      "**/.git/**": true,
      "**/node_modules/**": true,
      "**/.next/**": true,
      "**/dist/**": true,
      "**/build/**": true,
      "**/target/**": true,
      "**/.idea/**": true,
      "**/.gradle/**": true,
      "**/out/**": true,
      "**/coverage/**": true,
      "**/.turbo/**": true,
      "**/.cache/**": true
    },
    "search.exclude": {
      "**/node_modules": true,
      "**/.git": true,
      "**/.next": true,
      "**/dist": true,
      "**/build": true,
      "**/target": true,
      "**/.idea": true,
      "**/.gradle": true,
      "**/out": true,
      "**/coverage": true,
      "**/.turbo": true,
      "**/.cache": true
    },
    "typescript.tsserver.maxTsServerMemory": 2048,
    "typescript.disableAutomaticTypeAcquisition": true,
    "extensions.autoUpdate": false,
    "extensions.autoCheckUpdates": false
  }' "$CURSOR_SETTINGS" > "$tmp" && mv "$tmp" "$CURSOR_SETTINGS"

  echo "Updated Cursor settings (backup: $CURSOR_SETTINGS.bak-$STAMP)"
}

apply_intellij() {
  if [[ ! -d "$JETBRAINS_DIR" ]]; then
    echo "No JetBrains config dir found - skipping IntelliJ."
    return
  fi

  local found=0
  while IFS= read -r dir; do
    found=1
    local vmopts="$dir/idea.vmoptions"
    if [[ -f "$vmopts" ]]; then
      cp "$vmopts" "$vmopts.bak-$STAMP"
    else
      : > "$vmopts"
    fi

    for opt in "${INTELLIJ_OPTS[@]}"; do
      local key="${opt%%=*}"
      grep -v -F "$key" "$vmopts" > "$vmopts.tmp" 2>/dev/null || true
      mv "$vmopts.tmp" "$vmopts"
      echo "$opt" >> "$vmopts"
    done

    echo "Updated $vmopts (backup: $vmopts.bak-$STAMP)"
  done < <(find "$JETBRAINS_DIR" -maxdepth 1 -type d -name 'IntelliJIdea*')

  if [[ "$found" -eq 0 ]]; then
    echo "No IntelliJIdea* config folders found - skipping IntelliJ."
  fi
}

echo "Applying IDE safe settings (stamp: $STAMP)"
apply_cursor
apply_intellij
echo
echo "Done. Fully quit and reopen Cursor and IntelliJ for changes to take effect."
echo "To undo: ./restore_ide_safe_settings.sh"
