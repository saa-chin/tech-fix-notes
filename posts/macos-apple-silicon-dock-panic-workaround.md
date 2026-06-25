# Fixing macOS Kernel Panics With Thunderbolt Docks, IntelliJ Indexing, Cursor, and External Displays

I recently chased down a repeatable macOS kernel panic on an Apple silicon MacBook Pro connected to a Thunderbolt dock and multiple external displays.

The machine did not crash under ordinary use. It also did not crash from simple CPU, memory, or disk stress. The panic showed up when several high-activity developer tools were open at the same time, especially when one IDE was indexing a project while another editor was already running. A video call could also trigger it, but the call turned out not to be required.

This post describes the debugging process, the clues in the panic logs, and the Cursor and IntelliJ IDEA settings that reduced the crashes for me.

No serial numbers, account names, paths, MAC addresses, or incident identifiers are included here.

## The Setup

The relevant ingredients were:

- Apple silicon MacBook Pro
- Thunderbolt dock
- Multiple external displays
- Cursor
- IntelliJ IDEA
- Large projects with indexing and file watchers
- Sometimes Chrome or a browser-based video call

At first, the dock looked suspicious because it was recently added. That was a reasonable hypothesis, but the evidence did not point to malware or a malicious device.

The dock appeared as a normal Thunderbolt/USB4 dock with ordinary internal components such as USB hubs, display adapters, Ethernet, and controller devices. The Mac did not show new configuration profiles, non-Apple kernel extensions, or suspicious system extensions.

## The Panic Clues

The repeated panic string looked like this:

```text
AppleEventLogHandler: Register is locked down
```

The fresh panic from the successful repro included these important clues:

```text
Panicked task: Google Chrome Helper

Kernel Extensions in backtrace:
  com.apple.driver.AppleEventLogHandler
  com.apple.driver.AppleM2ScalerCSCDriver
  com.apple.driver.AppleInterruptControllerV2

last started kext:
  com.apple.macos.driver.AppleUSBEthernetHost
```

The most interesting item was:

```text
AppleM2ScalerCSCDriver
```

That points toward Apple silicon display scaling/color/display processing, not an ordinary user-space app crash.

## What Did Not Reproduce It

I built a staged stress test so each phase wrote a marker before running. That way, if the machine panicked and rebooted, the last marker identified the active phase.

The following phases passed:

```text
Idle with dock connected
Repeated Thunderbolt/USB/display enumeration
CPU-only stress
Memory pressure
Disk I/O
CPU plus device enumeration
```

The crash happened during the real workload:

```text
Cursor open
IntelliJ IDEA open
Project indexing active
External displays active through the dock setup
```

That shifted the theory from "video call problem" to:

```text
Heavy developer workload + external display/dock graphics path
```

## The Repro Harness

Here is a simplified version of the test structure.

```bash
#!/usr/bin/env bash
set -u

RUN_DIR="./panic-repro-$(date '+%Y%m%d_%H%M%S')"
STATUS_FILE="./LAST_STATUS.txt"
mkdir -p "$RUN_DIR"

mark() {
  local id="$1"
  local name="$2"
  {
    echo "test_id=$id"
    echo "test_name=$name"
    echo "started_at=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$STATUS_FILE"
  sync
  echo "START $id - $name"
}

finish() {
  local id="$1"
  local name="$2"
  echo "DONE $id - $name"
  {
    echo "last_completed_test_id=$id"
    echo "last_completed_test_name=$name"
    echo "completed_at=$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$STATUS_FILE"
  sync
}

countdown() {
  local seconds="$1"
  sleep "$seconds"
}

cpu_stress() {
  local seconds="$1"
  local workers
  workers="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
  local pids=()

  for _ in $(seq 1 "$workers"); do
    yes > /dev/null &
    pids+=("$!")
  done

  sleep "$seconds"
  kill "${pids[@]}" 2>/dev/null || true
}

mark "T01" "idle baseline"
countdown 180
finish "T01" "idle baseline"

mark "T02" "cpu stress"
cpu_stress 180
finish "T02" "cpu stress"

mark "T03" "manual real workload"
echo "Open Cursor and IntelliJ, then trigger indexing."
read -r _
countdown 900
finish "T03" "manual real workload"
```

The exact details matter less than the markers. Without the markers, every reboot feels ambiguous. With markers, the failing phase becomes obvious.

## The Settings That Helped

The fix was not a kernel patch. It was a pressure reduction strategy:

- reduce Cursor background indexing and file watching
- reduce IntelliJ indexing parallelism
- disable Java2D Metal/OpenGL rendering paths for IntelliJ
- exclude large generated directories from watchers/search

### Cursor Settings

In Cursor's user `settings.json`, I changed the noisy background settings:

```json
{
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
}
```

The key setting here is:

```json
"cursor.general.gitGraphIndexing": "disabled"
```

That does not disable Git. It only stops Cursor from pre-indexing the repository graph/history in the background. Normal Git operations still work.

### IntelliJ IDEA VM Options

For IntelliJ IDEA, I adjusted user-level VM options:

```text
-Dsun.java2d.metal=false
-Dsun.java2d.opengl=false
-Dide.mac.message.dialogs.as.sheets=false
-Didea.max.intellisense.filesize=2500
-Didea.indexing.threads=2
-Djava.util.concurrent.ForkJoinPool.common.parallelism=4
```

The most relevant settings are:

```text
-Dsun.java2d.metal=false
-Didea.indexing.threads=2
```

The first avoids one macOS rendering path for the IntelliJ UI. The second reduces the number of indexing threads IntelliJ can run at once.

This may make initial indexing slower. That tradeoff is fine if it prevents a full machine reboot.

## Ready-to-Run Scripts

You do not have to edit any of this by hand. All of the scripts live in the [`scripts/`](https://github.com/saa-chin/tech-fix-notes/tree/main/scripts) folder of this repo. They are written for macOS (Apple silicon), are reversible, and back up every file they touch before changing it.

These scripts are provided as-is, with no guarantee. They worked on the setup described here, but they do not patch any OS, driver, firmware, or hardware bug. Read each one before running it, prefer a non-critical machine, and use them at your own risk.

Grab them by cloning the repo (see GitHub's [Cloning a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository) guide):

```bash
git clone https://github.com/saa-chin/tech-fix-notes.git
cd tech-fix-notes/scripts
chmod +x *.sh
```

The scripts come in two layers:

| Script | Purpose |
| --- | --- |
| [`apply_ide_safe_settings.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/apply_ide_safe_settings.sh) | Back up and apply the lower-pressure Cursor + IntelliJ settings. |
| [`restore_ide_safe_settings.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/restore_ide_safe_settings.sh) | Roll the IDE settings back to a previous backup. |
| [`dev_safe_mode.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/dev_safe_mode.sh) | Toggle on a runtime "dev safe mode" that throttles IDE processes and disables dock network paths. |
| [`restore_after_dev.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/restore_after_dev.sh) | Turn dev safe mode off and re-enable networking. |
| [`check_dev_safe_state.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/check_dev_safe_state.sh) | Inspect what dev safe mode changed. |

### 1. Apply the IDE settings

This backs up and updates your Cursor `settings.json` and every `IntelliJIdea*` `idea.vmoptions` file. It needs `jq` for the Cursor part. The full script is [`apply_ide_safe_settings.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/apply_ide_safe_settings.sh).

```bash
chmod +x apply_ide_safe_settings.sh
./apply_ide_safe_settings.sh
# fully quit and reopen Cursor and IntelliJ afterwards
```

```bash
#!/usr/bin/env bash
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
    echo "jq not found - skipping Cursor settings."
    return
  fi
  mkdir -p "$(dirname "$CURSOR_SETTINGS")"
  [[ -f "$CURSOR_SETTINGS" ]] || echo '{}' > "$CURSOR_SETTINGS"
  cp "$CURSOR_SETTINGS" "$CURSOR_SETTINGS.bak-$STAMP"
  local tmp; tmp="$(mktemp)"
  jq '. * {
    "cursor.general.gitGraphIndexing": "disabled",
    "search.followSymlinks": false,
    "files.watcherExclude": {
      "**/.git/**": true, "**/node_modules/**": true, "**/.next/**": true,
      "**/dist/**": true, "**/build/**": true, "**/target/**": true,
      "**/.idea/**": true, "**/.gradle/**": true, "**/out/**": true,
      "**/coverage/**": true, "**/.turbo/**": true, "**/.cache/**": true
    },
    "typescript.tsserver.maxTsServerMemory": 2048,
    "typescript.disableAutomaticTypeAcquisition": true,
    "extensions.autoUpdate": false,
    "extensions.autoCheckUpdates": false
  }' "$CURSOR_SETTINGS" > "$tmp" && mv "$tmp" "$CURSOR_SETTINGS"
  echo "Updated Cursor settings (backup: $CURSOR_SETTINGS.bak-$STAMP)"
}

apply_intellij() {
  [[ -d "$JETBRAINS_DIR" ]] || { echo "No JetBrains dir - skipping."; return; }
  while IFS= read -r dir; do
    local vmopts="$dir/idea.vmoptions"
    [[ -f "$vmopts" ]] && cp "$vmopts" "$vmopts.bak-$STAMP" || : > "$vmopts"
    for opt in "${INTELLIJ_OPTS[@]}"; do
      local key="${opt%%=*}"
      grep -v -F "$key" "$vmopts" > "$vmopts.tmp" 2>/dev/null || true
      mv "$vmopts.tmp" "$vmopts"
      echo "$opt" >> "$vmopts"
    done
    echo "Updated $vmopts (backup: $vmopts.bak-$STAMP)"
  done < <(find "$JETBRAINS_DIR" -maxdepth 1 -type d -name 'IntelliJIdea*')
}

apply_cursor
apply_intellij
echo "Done. Quit and reopen Cursor and IntelliJ. Undo with restore_ide_safe_settings.sh"
```

To roll back to the most recent backup:

```bash
./restore_ide_safe_settings.sh
# or restore a specific stamp:
./restore_ide_safe_settings.sh 20260101_120000
```

### 2. Toggle dev safe mode during heavy work

Run [`dev_safe_mode.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/dev_safe_mode.sh) before opening Cursor and IntelliJ together. It disables dock network/serial services (keeping Wi-Fi as the route) and continuously throttles IDE/indexing processes with `renice` and `taskpolicy -b`. It writes a marker so that if the machine still panics, you know safe mode was active. Pair it with [`restore_after_dev.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/restore_after_dev.sh) and [`check_dev_safe_state.sh`](https://github.com/saa-chin/tech-fix-notes/blob/main/scripts/check_dev_safe_state.sh).

```bash
chmod +x dev_safe_mode.sh restore_after_dev.sh check_dev_safe_state.sh
./dev_safe_mode.sh        # turn it on
./check_dev_safe_state.sh # inspect what it changed
./restore_after_dev.sh    # turn it off and re-enable networking
```

The core of the runtime script:

```bash
#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$ROOT_DIR/dev_safe_state"
PID_FILE="$STATE_DIR/monitor.pid"
INTERVAL="${INTERVAL:-10}"
NICE_VALUE="${NICE_VALUE:-15}"
mkdir -p "$STATE_DIR"

disable_service_if_present() {
  local service="$1"
  if networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$service"; then
    networksetup -setnetworkserviceenabled "$service" off 2>/dev/null || true
  fi
}

throttle_matching_processes() {
  ps ax -o pid=,comm=,args= | awk '
    /IntelliJ IDEA|idea|fsnotifier|jetbrains|java|Cursor|Electron/ &&
    !/dev_safe_mode.sh/ && !/awk/ {print}
  ' | while read -r pid comm rest; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    renice "$NICE_VALUE" -p "$pid" >/dev/null 2>&1 || true
    taskpolicy -b -p "$pid" >/dev/null 2>&1 || true
  done
}

disable_service_if_present "USB ACM"
disable_service_if_present "USB 10/100 LAN"
disable_service_if_present "Thunderbolt Bridge"
disable_service_if_present "iPhone USB"

throttle_matching_processes
( while true; do throttle_matching_processes; sleep "$INTERVAL"; done ) &
echo "$!" > "$PID_FILE"
echo "Dev safe mode active. Stop it with restore_after_dev.sh"
```

And the matching restore:

```bash
#!/usr/bin/env bash
set -u
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$ROOT_DIR/dev_safe_state/monitor.pid"

enable_service_if_present() {
  local service="$1"
  if networksetup -listallnetworkservices 2>/dev/null | sed 's/^\*//' | grep -Fxq "$service"; then
    networksetup -setnetworkserviceenabled "$service" on 2>/dev/null || true
  fi
}

[[ -f "$PID_FILE" ]] && kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"
enable_service_if_present "USB ACM"
enable_service_if_present "USB 10/100 LAN"
enable_service_if_present "Thunderbolt Bridge"
enable_service_if_present "iPhone USB"
echo "Restore complete"
```

None of these patch the kernel. They reduce the burst of indexing, file watching, and display/GPU work that appears to trip the panic, and they are all reversible.

## What I Would Try First

If you are debugging a similar panic, I would test in this order:

1. Run with one external display instead of two.
2. Disable dock Ethernet and use Wi-Fi.
3. Exclude generated directories from Cursor and IntelliJ.
4. Reduce IntelliJ indexing parallelism.
5. Disable Java2D Metal for IntelliJ.
6. Re-test the exact workload that previously panicked.

## What This Does Not Prove

This does not prove the dock is defective.

It also does not prove Cursor, IntelliJ, or Chrome are the root cause.

The panic is in Apple kernel/display-related code, and the apps appear to be triggers. The practical workaround is to reduce the pressure on the workload that triggers the kernel bug.

## The Fix That Actually Worked

After all the testing, the thing that made the machine stable was not the dock, the network, or the video call. It came down to the **IntelliJ IDEA settings**, specifically reducing the GPU/rendering and indexing pressure.

These two VM options did the heavy lifting:

```text
-Dsun.java2d.metal=false
-Didea.indexing.threads=2
```

The first stops IntelliJ from using the Metal rendering path on macOS. The second caps how many indexing threads run at once. Together they keep IntelliJ from hammering the same Apple display/scaler path that the panic backtrace pointed at (`AppleM2ScalerCSCDriver`) while external displays are active.

The full set of IntelliJ VM options I settled on:

```text
-Dsun.java2d.metal=false
-Dsun.java2d.opengl=false
-Dide.mac.message.dialogs.as.sheets=false
-Didea.max.intellisense.filesize=2500
-Didea.indexing.threads=2
-Djava.util.concurrent.ForkJoinPool.common.parallelism=4
```

The Cursor `settings.json` changes (disabling Git graph indexing and excluding heavy folders from watchers/search) reduced the background pressure further, but the IntelliJ flags were what stopped the crashes.

With those in place, the exact workload that used to reliably panic the machine — Cursor open, IntelliJ open, full project indexing running, multiple external displays through the dock — ran without a single panic.

If you only do one thing, set `-Dsun.java2d.metal=false` and `-Didea.indexing.threads=2` in IntelliJ, then fully quit and reopen it.

## Versions Tested

This was reproduced and fixed on:

```text
Apple silicon MacBook Pro (M2-class)
macOS (Apple silicon build current at the time of testing)
IntelliJ IDEA 2026.1 and 2025.3
Cursor (current stable at the time of testing)
A generic Thunderbolt / USB4 dock with multiple external displays
```

No serial numbers, account names, hostnames, paths, MAC addresses, or incident identifiers are included.

## Final Takeaway

When a Mac panics only during a real developer workload, synthetic CPU and memory tests may not be enough. The failing condition can be a combination of:

```text
IDE indexing
file watching
GPU/display scaling
external displays
dock peripherals
browser or editor rendering
```

In this case, limiting IntelliJ indexing and disabling its Metal rendering path — backed up by lighter Cursor background indexing — made the setup stable enough to keep working while waiting for a proper OS, driver, firmware, or hardware fix.

## References

- [JetBrains: Advanced configuration and JVM (VM) options](https://www.jetbrains.com/help/idea/tuning-the-ide.html)
- [Apple: If your Mac restarted because of a problem](https://support.apple.com/en-us/102649)
- [Apple: Keep your Mac up to date](https://support.apple.com/en-us/108382)
- [GitHub Docs: Cloning a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository)
- [GitHub Docs: Creating gists](https://docs.github.com/en/get-started/writing-on-github/editing-and-sharing-content-with-gists/creating-gists)
- [All scripts from this post](https://github.com/saa-chin/tech-fix-notes/tree/main/scripts)
