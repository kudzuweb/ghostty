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
[[ -d "$installed_app" ]] || { echo 'Missing existing installed bundle.' >&2; exit 1; }
active_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$active_app/Contents/Info.plist")
[[ "$active_identifier" == com.mitchellh.ghostty ]] || { echo 'Active bundle must have canonical daily identity.' >&2; exit 1; }
printf 'Candidate: %s\nRevision: %s\nStage: %s\nInstalled bundle: %s\nActive bundle: %s\n' "$source_app" "$revision" "$destination" "$installed_app" "$active_app"
if [[ "$mode" == dry-run ]]; then exit; fi
mkdir -p "$destination/state" "$destination/receipts"
python3 - "$source_app" "$active_app" "$installed_app" "$revision" "$destination" <<'MANIFEST'
import datetime, hashlib, json, pathlib, sys
candidate, active, installed, revision, destination = sys.argv[1:]
def identity(path):
    executable = pathlib.Path(path)/'Contents/MacOS/ghostty'
    return {'source_path': path, 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
manifest = {'prepared_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'candidate': dict(identity(candidate), revision=revision),
            'previous_active': identity(active),
            'previous_installed': identity(installed),
            'canonical_target': '/Applications/Ghostty.app',
            'preliminary_state_only': True}
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
cat > "$destination/INSTALL.txt" <<'PLAN'
Prepared only; no application copies, installation, process, job or permission changes.
transaction.json records the one build output and the existing active/installed identities.
Git preserves source versions. This directory contains receipts and preliminary state,
not application backups. Do not retain candidates or rollback bundles here.
1. Obtain authorization for the daily quit/relaunch. Capture actual executable/PID/birth,
   window/surface/session/cwd mapping and recovery receipt. Match previous_active.source_path.
   Require the active runtime to be /Applications/Ghostty.app and match previous_installed
   before this canonical exchange. If it differs, stop and resolve that path explicitly;
   the displaced installed app is not assumed to be the previous runtime.
   Pause automated actions; inspect exact relaunch and sleep-recovery watcher ownership.
2. Quit gracefully and verify all production-ID Ghostty processes stopped and sleep
   ownership released. Stop only the exact relevant watcher labels when safe. Refresh
   config/preferences/saved-state/recovery snapshots after quit; retain preliminary evidence.
3. Reverify candidate.source_path against its recorded stamp/hash and strict signature.
   Copy that single build output to a newly created temporary directory on /Applications
   volume. Verify the copied bundle's ID, strict signature, stamp and executable hash.
   Rename /Applications/Ghostty.app aside temporarily for the same-volume exchange, then
   move the verified bundle to /Applications/Ghostty.app. If exchange fails, restore the
   displaced bundle immediately. Never overwrite an unexpected path or newer artifact.
4. Force-register canonical /Applications/Ghostty.app and launch that exact path once.
   Verify exactly one daily process, stamp/hash and restored surface/session associations.
   If acceptance fails, quit the new app gracefully, preserve diagnostics and fresh state,
   verify no late mutation, restore the displaced bundle and its exact launch references,
   register/open the prior runtime once, and verify identity and associations.
5. On success or failure, unregister each exact inactive temporary/displaced app path and
   remove its owned temporary copy/directory after the required restore or acceptance.
   Never leave runnable app copies or ZIP backups. Remove the inactive build output after
   successful installation. Do not remove an active runtime or reset LaunchServices/TCC.
   Redirect only inspected references that pointed to the previous active path. Verify
   bundle-ID resolution and permission-driven relaunch select /Applications/Ghostty.app.
6. After the temporary exchange has finished, returning to older code means checking out
   its Git revision and rebuilding the single build output, then repeating this procedure.
   Review newer config/session changes before restoring any state snapshot. Ad-hoc signing
   cannot promise permission continuity; record requirements and allow explicit user grants.
PLAN
printf 'Prepared. Read %s/INSTALL.txt before any daily changes.\n' "$destination"
