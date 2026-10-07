#!/bin/bash
# Read-only PID-addressed capture; creates staging files only, never a live journal.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
[[ $# == 3 ]] || { echo 'Usage: capture-migration.sh PID /exact/active/Ghostty.app /new/staging-output' >&2; exit 2; }
pid=$1
app=$2
output=$3
[[ "$pid" =~ ^[1-9][0-9]*$ && -d "$app/Contents" && ! -e "$output" ]] || { echo 'Provide live PID, exact app path, and NEW staging output directory.' >&2; exit 2; }
case "$output" in /*) ;; *) echo 'Staging output must be absolute.' >&2; exit 2 ;; esac
mkdir -p "$output/work"
revision=$(python3 "$repo/fork/scripts/build-stamp.py")
cp "$repo/fork/tools/capture-migration.swift" "$output/work/main.swift"
swiftc -module-cache-path "$output/work/module-cache" \
    "$repo/macos/Sources/Features/Terminal/AgentSessionRecoveryState.swift" \
    "$repo/macos/Sources/Features/Terminal/AgentSessionResume.swift" \
    "$repo/macos/Sources/Features/KeepAlive/KeepAliveLogic.swift" \
    "$output/work/main.swift" -o "$output/work/capture"
[[ "$revision" == "$(python3 "$repo/fork/scripts/build-stamp.py")" ]] || { echo 'Resolver source changed during compile; discard stage and retry.' >&2; exit 1; }
printf '%s\n' "$revision" > "$output/resolver-source.txt"
# Outer deadline also bounds the many small AppleEvent/property calls.
python3 - "$output/work/capture" "$pid" "$app" "$output" <<'RUN'
import subprocess, sys
try:
    subprocess.run(sys.argv[1:], timeout=45, check=True)
except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
    print('Capture did not complete; no migration may be seeded from this stage.', file=sys.stderr)
    raise SystemExit(1) from error
RUN
