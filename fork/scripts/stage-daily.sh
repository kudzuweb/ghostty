#!/bin/bash
# Preflight/prepare only. Does not stop or launch apps, or replace /Applications.
set -euo pipefail
mode=${1:-dry-run}
source_app=${2:-}
destination=${3:-}
active_app=${4:-${GHOSTTY_STAGE_ACTIVE_APP:-}}
# Test fixtures can replace read-only inputs; destination remains explicit and new.
installed_app=${GHOSTTY_STAGE_INSTALLED_APP:-/Applications/Ghostty.app}
snapshot_home=${GHOSTTY_STAGE_SNAPSHOT_HOME:-$HOME}
case "$mode" in dry-run|prepare) ;; *) echo 'Usage: stage-daily.sh dry-run|prepare /path/Ghostty.app /path/staging-directory /path/current-active/Ghostty.app' >&2; exit 2 ;; esac
[[ -n "$source_app" && -d "$source_app/Contents" && -n "$destination" ]] || { echo 'Provide source app and a new staging directory.' >&2; exit 2; }
[[ -n "$active_app" && -d "$active_app/Contents" ]] || { echo 'Explicit current active bundle is required; never infer it from /Applications.' >&2; exit 2; }
[[ ! -e "$destination" ]] || { echo 'Staging directory already exists; preserve it and choose a new one.' >&2; exit 1; }
info="$source_app/Contents/Info.plist"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")
[[ "$identifier" == com.mitchellh.ghostty ]] || { echo 'Daily staging requires canonical com.mitchellh.ghostty identity.' >&2; exit 1; }
revision=$(/usr/libexec/PlistBuddy -c 'Print :GhosttyForkRevision' "$info")
[[ -n "$revision" ]] || { echo 'Missing embedded source revision.' >&2; exit 1; }
/usr/bin/codesign --verify --strict "$source_app"
[[ -d "$installed_app" ]] || { echo 'Missing existing installed bundle to back up.' >&2; exit 1; }
active_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$active_app/Contents/Info.plist")
[[ "$active_identifier" == com.mitchellh.ghostty ]] || { echo 'Active backup must have canonical daily identity.' >&2; exit 1; }
printf 'Candidate: %s\nRevision: %s\nStage: %s\nInstalled backup source: %s\nActive backup source: %s\n' "$source_app" "$revision" "$destination" "$installed_app" "$active_app"
if [[ "$mode" == dry-run ]]; then exit; fi
mkdir -p "$destination/candidate" "$destination/previous-installed" "$destination/previous-active" "$destination/state" "$destination/receipts"
/usr/bin/ditto "$source_app" "$destination/candidate/Ghostty.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$installed_app" "$destination/previous-installed/Ghostty.app.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$active_app" "$destination/previous-active/Ghostty.app.zip"
python3 - "$source_app" "$active_app" "$installed_app" "$revision" "$destination" <<'MANIFEST'
import datetime, hashlib, json, pathlib, sys
candidate, active, installed, revision, destination = sys.argv[1:]
def identity(path):
    executable = pathlib.Path(path)/'Contents/MacOS/ghostty'
    return {'source_path': path, 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
manifest = {'prepared_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'candidate': dict(identity(candidate), revision=revision, backup='candidate/Ghostty.app'),
            'previous_active': dict(identity(active), backup='previous-active/Ghostty.app.zip', archive_format='ditto-zip'),
            'previous_installed': dict(identity(installed), backup='previous-installed/Ghostty.app.zip', archive_format='ditto-zip'),
            'canonical_target': '/Applications/Ghostty.app',
            'rollback_launch_path': active, 'preliminary_state_only': True}
(pathlib.Path(destination)/'transaction.json').write_text(json.dumps(manifest, indent=2) + '\n')
MANIFEST
/usr/bin/codesign -d -r- --verbose=2 "$active_app" 2> "$destination/receipts/previous-active-signature.txt"
/usr/bin/codesign -d -r- --verbose=2 "$installed_app" 2> "$destination/receipts/previous-installed-signature.txt"
/usr/bin/codesign -d -r- --verbose=2 "$source_app" 2> "$destination/receipts/candidate-signature.txt"
for item in "$snapshot_home/Library/Application Support/com.mitchellh.ghostty" \
    "$snapshot_home/Library/Saved Application State/com.mitchellh.ghostty.savedState" \
    "$snapshot_home/.local/state/ghostty" "$snapshot_home/.config/ghostty" \
    "$snapshot_home/Library/Preferences/com.mitchellh.ghostty.plist" \
    "$snapshot_home/Library/LaunchAgents/com.mauria.ghostty-relaunch.plist" \
    "$snapshot_home/Library/LaunchAgents/com.mauria.ghostty-relaunch.com.mitchellh.ghostty.plist" \
    "$snapshot_home/Library/LaunchAgents/com.mauria.ghostty-sleep-recovery.plist"; do
    if [[ -e "$item" ]]; then
        name=$(printf '%s' "$item" | /usr/bin/sed 's|/|_|g')
        /usr/bin/ditto "$item" "$destination/state/$name"
    fi
done
/usr/bin/codesign --verify --strict "$destination/candidate/Ghostty.app"
cat > "$destination/INSTALL-AND-ROLLBACK.txt" <<'PLAN'
Prepared only; no installation or app/process/job/permission changes have occurred.
Read transaction.json: previous-active and previous-installed are distinct ZIP archives.
Extract with ditto -x -k ARCHIVE NEW_DIRECTORY; the preserved bundle keeps its original
basename. Verify its executable hash against transaction.json and codesign --verify
--deep before restoration. Finder custom-icon metadata added after launch can fail strict
verification; preserve that metadata. Strict verification still applies to the unlaunched
candidate. Keep extracted rollback apps temporary and unregister their
exact paths after use; runnable production-ID backups can confuse permission relaunch.
1. Obtain authorization for the controlled daily quit/relaunch. Capture actual active
   executable/PID/birth, window/surface/session/cwd mapping and recovery receipt. Confirm
   this matches previous_active.source_path, not merely a matching bundle ID. Pause
   automated actions and preserve the exact prior config/preferences/job definitions.
2. Quit the actual active app gracefully by absolute path. Verify every canonical-ID
   Ghostty process stopped, not only that /Applications has no process. Inspect original
   relaunch job; unload only the exact daily watcher labels if necessary to prevent an old
   watcher reopening the original path. Do not unload a sleep recovery watcher while its
   lease or in-flight mutation remains. Verify sleep ownership released to its initial
   state. Refresh config/preferences/saved-state/recovery backups AFTER quit into a new
   post-quit snapshot; never overwrite preliminary evidence.
3. Copy candidate/Ghostty.app to /Applications/.Ghostty-staged.app on that same volume;
   verify canonical ID, signature, source stamp and hash. Rename existing installed bundle
   aside only for the atomic exchange, then staged to /Applications/Ghostty.app. Archive
   the inactive displaced bundle with ditto -c -k --sequesterRsrc --keepParent and verify
   an independent extraction before removing that runnable copy. Preserve both ZIP
   backups. Preserve the original active artifact in a verified archive before removing
   its inactive runnable duplicate. Repository source files remain untouched.
4. Narrow LaunchServices operations: unregister the now-inactive original active bundle
   path if it differs from the canonical target and each exact inactive production-ID
   candidate/backup path, then force-register the new canonical target. Verify bundle-ID
   resolution selects /Applications/Ghostty.app. Archive inactive candidate copies after
   successful installation so they cannot be rediscovered as competing applications.
   Do not reset LaunchServices or TCC. Redirect inspected login/Dock/automation references
   to canonical /Applications path only when they currently target the original bundle.
   Keep a before/after reference manifest so rollback can restore those exact entries.
5. Open canonical /Applications/Ghostty.app once, without open -n. Re-enumerate actual
   executable paths and require exactly one daily instance with the candidate stamp/hash.
   Verify restored surface/session/cwd mapping and no duplicate sessions before resuming
   automatic actions. New relaunch watcher must name canonical bundle and current birth.
   After every permission-driven relaunch, repeat path/revision/mapping checks.
6. Ad-hoc signatures may have code-hash-based designated requirements. Retaining the ID
   and path does not guarantee permission continuity. Record old/candidate requirements;
   permit explicit user grants if requested, and stop for an unexpected bundle identity.
   Do not clear permission databases or silently change signing requirements. A stable
   trusted signing identity is a separate provisioned setup, not an ad-hoc promise.
7. On failure: quit new canonical app gracefully, verify no daily process/late mutation,
   preserve new diagnostics/state, unload only new relaunch watcher, restore previous-
   installed artifact to /Applications, restore the changed launch reference registrations,
   then restore the previous-active archive to previous_active.source_path if that path
   was removed: extract into a new directory, verify its recorded hash and deep signature,
   and preserve any newer artifact at that path before restoring. Register/open that exact
   recorded path once. This is the rollback runtime; the older installed app is NOT
   assumed to be the app that was running. Verify its hash and session associations.
   Restore old config/preferences/state only after reviewing newer work and authorization;
   never overwrite fresh session activity automatically.
PLAN
printf 'Prepared. Read %s/INSTALL-AND-ROLLBACK.txt before any daily changes.\n' "$destination"
