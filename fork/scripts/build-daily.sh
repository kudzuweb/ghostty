#!/bin/bash
# Build a stamped daily candidate. This never installs or launches it.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
build_dir="$repo/macos/build/DailyCandidate"
zig_tool=${GHOSTTY_ZIG:-$(command -v zig || true)}
if [[ -z "$zig_tool" ]]; then zig_tool="$HOME/.local/opt/zig-aarch64-macos-0.15.2/zig"; fi
[[ -x "$zig_tool" ]] || { echo 'Zig 0.15.2 is required; set GHOSTTY_ZIG to its absolute executable.' >&2; exit 1; }
mkdir -p "$build_dir/zig-global-cache"
# fork/scripts/toolchain-shims goes first in PATH. Its libtool re-archives Zig's .a inputs so
# Xcode 26.5's libtool stops dropping members. Its xcrun, when GHOSTTY_ZIG_SDK is set, answers
# Zig's `xcrun --sdk macosx --show-sdk-path` with that SDK: Xcode 26.5's SDK lists only
# arm64e-macos in libSystem.tbd, so against it every libc symbol comes back undefined, starting
# with the build runner itself. GHOSTTY_ZIG_SDK names an SDK that still lists arm64-macos
# (the Command Line Tools keep MacOSX15.4.sdk).
zig_path="$repo/fork/scripts/toolchain-shims:/usr/bin:/bin:/usr/sbin:/sbin"
# The core build runs msgfmt (gettext) for translations, which macOS does not ship. Take it
# from the caller's PATH (Homebrew puts it in /opt/homebrew/bin) rather than widening PATH.
msgfmt_tool=$(command -v msgfmt || true)
[[ -n "$msgfmt_tool" ]] || { echo 'msgfmt (gettext) is required: brew install gettext' >&2; exit 1; }
zig_path="$zig_path:$(dirname "$msgfmt_tool")"
if [[ -n "${GHOSTTY_ZIG_SDK:-}" ]]; then
    grep -q 'arm64-macos' "$GHOSTTY_ZIG_SDK/usr/lib/libSystem.tbd" || { echo "GHOSTTY_ZIG_SDK=$GHOSTTY_ZIG_SDK has no arm64-macos libSystem stub." >&2; exit 1; }
else
    sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
    grep -q 'arm64-macos' "$sdk/usr/lib/libSystem.tbd" || { echo "The Xcode SDK at $sdk has no arm64-macos libSystem stub, so Zig cannot link. Set GHOSTTY_ZIG_SDK to one that does, e.g. /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk." >&2; exit 1; }
fi
# Same sanitized xcodebuild invocation as macos/build.nu; Nushell is unavailable here.
revision=$(python3 "$repo/fork/scripts/build-stamp.py")
# Always rebuild the optimized core in this clone. A pre-existing Debug xcframework
# is not proof of daily readiness. Cache writes stay inside the candidate build root.
(cd "$repo" && env -i HOME="$HOME" PATH="$zig_path" GHOSTTY_ZIG_SDK="${GHOSTTY_ZIG_SDK:-}" \
    ZIG_GLOBAL_CACHE_DIR="$build_dir/zig-global-cache" \
    "$zig_tool" build -Doptimize=ReleaseFast -Demit-macos-app=false)
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild \
    -project "$repo/macos/Ghostty.xcodeproj" -scheme Ghostty -configuration ReleaseLocal \
    -derivedDataPath "$repo/macos/build/DailyCandidate/DerivedData" \
    "SYMROOT=$repo/macos/build/DailyCandidate" PRODUCT_BUNDLE_IDENTIFIER=com.mitchellh.ghostty \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
app="$repo/macos/build/DailyCandidate/ReleaseLocal/Ghostty.app"
[[ "$revision" == "$(python3 "$repo/fork/scripts/build-stamp.py")" ]] || { echo 'Source changed during build; rebuild before stamping.' >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :GhosttyForkRevision $revision" "$app/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :GhosttyForkRevision string $revision" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :GhosttyForkProfile daily' "$app/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c 'Add :GhosttyForkProfile string daily' "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --preserve-metadata=entitlements,requirements,flags "$app"
/usr/bin/codesign --verify --strict "$app"
printf 'Daily candidate (not installed): %s\nRevision: %s\n' "$app" "$revision"
