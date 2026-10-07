#!/bin/bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 - "$repo" "$scratch" <<'PY'
import pathlib, sys
repo, scratch = map(pathlib.Path, sys.argv[1:])
source = (repo/'macos/Sources/Features/SleepGuard/SleepGuard.swift').read_text()
backend = source[source.index('final class SleepGuardOwnership'):source.index('/// Keeps the Mac awake')]
stubs = 'import Foundation\nimport Darwin\nenum Ghostty { static let isDailyForkProfile = false }\nenum LidSleep { static func isBlocked() -> Bool? { fatalError("real pmset forbidden") }; static func setBlocked(_ b: Bool, allowPrompt: Bool, ownershipFD: Int32 = -1) -> String? { fatalError("real pmset forbidden") } }\n'
(scratch/'Ownership.swift').write_text(stubs + backend)
(scratch/'main.swift').write_text((repo/'fork/tests/sleep-ownership.swift').read_text())
PY
swiftc -module-cache-path "$scratch/module-cache" "$repo/macos/Sources/Ghostty/ForkBoundedProcess.swift" "$scratch/Ownership.swift" "$scratch/main.swift" -o "$scratch/check"
"$scratch/check"
python3 - "$repo" "$scratch" <<'PYENV'
import pathlib, sys
repo, scratch = map(pathlib.Path, sys.argv[1:])
source = (repo/'macos/Sources/Ghostty/Ghostty.AgentEnvironment.swift').read_text()
policy = source[source.index('    static let agentEnvironmentNames'):source.index('    static func stripAgentEnvironment')]
policy += source[source.index('    static func isolatedConfigPath'):source.index('    /// Debug and uniquely')]
(scratch/'Environment.swift').write_text('import Foundation\nenum Ghostty {\n' + policy + '\n}\n')
(scratch/'main.swift').write_text((repo/'fork/tests/agent-environment.swift').read_text())
PYENV
swiftc -module-cache-path "$scratch/module-cache" "$scratch/Environment.swift" "$scratch/main.swift" -o "$scratch/environment-check"
"$scratch/environment-check"
python3 - "$repo" "$scratch" <<'PYRELAUNCH'
import pathlib, sys
repo, scratch = map(pathlib.Path, sys.argv[1:])
source = (repo/'macos/Sources/Features/KeepAlive/KeepAliveRelaunchJob.swift').read_text()
helper = source[source.index('final class RelaunchReconciler'):source.index('/// The launchd job')]
(scratch/'Reconciler.swift').write_text('import Foundation\n' + helper)
(scratch/'main.swift').write_text((repo/'fork/tests/relaunch-reconciler.swift').read_text())
PYRELAUNCH
swiftc -module-cache-path "$scratch/module-cache" "$scratch/Reconciler.swift" "$scratch/main.swift" -o "$scratch/relaunch-check"
"$scratch/relaunch-check"
cp "$repo/fork/tests/bounded-process.swift" "$scratch/main.swift"
swiftc -module-cache-path "$scratch/module-cache" "$repo/macos/Sources/Ghostty/ForkBoundedProcess.swift" "$scratch/main.swift" -o "$scratch/bounded-check"
cp "$repo/fork/tests/sleep-owner-process.swift" "$scratch/main.swift"
swiftc -module-cache-path "$scratch/module-cache" "$repo/macos/Sources/Ghostty/ForkBoundedProcess.swift" "$scratch/Ownership.swift" "$scratch/main.swift" -o "$scratch/owner-process"
python3 "$repo/fork/tests/watcher-checks.py" "$repo" "$scratch/bounded-check" "$scratch/owner-process"
python3 "$repo/fork/tests/staging-checks.py" "$repo"
python3 "$repo/fork/tests/migration-seed-checks.py" "$repo"
bash -n "$repo/fork/scripts/test-app.sh" "$repo/fork/scripts/stage-daily.sh" "$repo/fork/scripts/build-daily.sh" "$repo/fork/scripts/capture-migration.sh"
