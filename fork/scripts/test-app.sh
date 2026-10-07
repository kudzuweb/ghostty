#!/bin/bash
# One profile per bundle identity. No launch occurs unless explicitly requested.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
action=${1:-build}
profile=${2:-reliability}
[[ "$profile" =~ ^[a-z][a-z0-9-]{0,40}$ ]] || { echo 'Profile must be lowercase letters, digits and hyphens.' >&2; exit 2; }
case "$action" in build|run|path) ;; *) echo 'Usage: test-app.sh build|run|path [profile]' >&2; exit 2 ;; esac
bundle_id="com.mauria.ghostty.test.$profile"
build_dir="$repo/macos/build/Test-$profile"
app="$build_dir/Debug/Ghostty.app"
if [[ "$action" == path ]]; then printf '%s\n' "$app"; exit; fi
if [[ "$action" == build ]]; then
    [[ -d "$repo/macos/GhosttyKit.xcframework" ]] || { echo 'Build core first: zig build -Demit-macos-app=false' >&2; exit 1; }
    revision=$(python3 "$repo/fork/scripts/build-stamp.py")
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
        -project "$repo/macos/Ghostty.xcodeproj" -scheme Ghostty -configuration Debug \
        -derivedDataPath "$build_dir/DerivedData" \
        "SYMROOT=$build_dir" "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" \
        CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
    [[ "$revision" == "$(python3 "$repo/fork/scripts/build-stamp.py")" ]] || { echo 'Source changed during build; rebuild before stamping.' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :GhosttyForkRevision $revision" "$app/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :GhosttyForkRevision string $revision" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :GhosttyForkProfile $profile" "$app/Contents/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :GhosttyForkProfile string $profile" "$app/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$app"
    /usr/bin/codesign --verify --strict "$app"
    printf 'Built isolated app: %s\nRevision: %s\n' "$app" "$revision"
else
    [[ -d "$app" ]] || { echo 'Build this profile first.' >&2; exit 1; }
    actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
    [[ "$actual" == "$bundle_id" ]] || { echo 'Refusing unexpected bundle identity.' >&2; exit 1; }
    /usr/bin/codesign --verify --strict "$app"
    # Startup creates its own effective config/state. No daily path is passed here.
    exec /usr/bin/open "$app"
fi
