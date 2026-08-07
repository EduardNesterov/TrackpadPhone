#!/bin/bash
# Builds dist/TrackpadPhone.app — the menu bar receiver.
#
# A bundled app rather than a bare binary because macOS ties the Accessibility grant to
# the code signature of whatever is running. Launched from a shell, the permission belongs
# to the terminal, so it silently follows whichever terminal you happened to use. Signed
# with a stable identity, the app is granted once and stays granted across rebuilds.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/dist/TrackpadPhone.app"

# SwiftPM caches the file list of a path dependency and does not notice a *new* source
# file appearing in it: the build fails with "cannot find X in scope" while the package
# itself compiles fine. Edits to existing files are picked up normally, so only a change
# in the file count needs the sledgehammer. This has already cost two confusing failures.
stamp="$root/Apps/TrackpadPhoneMac/.build/kit-file-count"
count="$(find "$root/TrackpadKit/Sources" -name '*.swift' | wc -l | tr -d ' ')"
if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$count" ]; then
    echo "==> TrackpadKit gained or lost a file — clearing the stale build plan"
    rm -rf "$root/Apps/TrackpadPhoneMac/.build"
fi

echo "==> building"
swift build -c release --package-path "$root/Apps/TrackpadPhoneMac"
binary="$(swift build -c release --package-path "$root/Apps/TrackpadPhoneMac" --show-bin-path)/TrackpadPhoneMac"

mkdir -p "$(dirname "$stamp")"
echo "$count" > "$stamp"

echo "==> assembling bundle"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/TrackpadPhone"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>TrackpadPhone</string>
    <key>CFBundleIdentifier</key>          <string>com.eduardnesterov.trackpadphone.mac</string>
    <key>CFBundleName</key>                <string>TrackpadPhone</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>0.1</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no window. -->
    <key>LSUIElement</key>                 <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>TrackpadPhone listens for your iPhone on this network. Nothing leaves it.</string>
    <!-- Core Audio taps ask for this one; without it the tap is refused silently. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>TrackpadPhone sends the Mac's audio to your iPhone.</string>
</dict>
</plist>
PLIST

echo "==> signing"
# Prefer the developer identity: its signature is stable, so the Accessibility grant
# survives rebuilds. Ad-hoc signing changes on every build and macOS then treats each
# build as a different program that has to be authorised again.
identity="$(security find-identity -v -p codesigning \
    | grep "Apple Development" | head -1 | awk '{print $2}')"

if [ -n "$identity" ]; then
    codesign --force --sign "$identity" --timestamp=none "$app"
    echo "    signed with $identity"
else
    codesign --force --sign - "$app"
    echo "    no developer identity found — ad-hoc signed."
    echo "    Accessibility will need re-granting after every rebuild."
fi

echo
echo "Ready: $app"
echo "Open it with:  open '$app'"
