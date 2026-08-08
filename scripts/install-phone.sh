#!/bin/bash
# Builds the phone app and puts it on the connected iPhone.
#
# Exists so that handing this to someone else is one command rather than a paragraph.
# The device is looked up rather than written down: a UDID in a script is a UDID that is
# wrong on every machine but the one it was written on.
#
# What the person running it needs, once:
#   * Xcode, and a free Apple ID signed in under Settings → Accounts
#   * Developer Mode on the iPhone (Settings → Privacy & Security → Developer Mode)
#   * the phone plugged in, or paired to this Mac over the network
#
# On a free Apple ID the installed app stops launching after seven days. Running this
# again fixes it; nothing is lost, because the pairing lives in the Keychain.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/.build-ios"

# To a file, not to stdout: `--json-output /dev/stdout` mixes the JSON in with the
# human-readable table it also prints, and nothing can parse the result.
listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
xcrun devicectl list devices --json-output "$listing" >/dev/null 2>&1 || true

device="$(python3 - "$listing" <<'PYTHON'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
# Paired is the property that matters. A phone can be paired and its tunnel asleep;
# devicectl wakes it when asked to install.
for d in devices:
    if d.get("connectionProperties", {}).get("pairingState") != "paired":
        continue
    print(d["identifier"], d.get("deviceProperties", {}).get("name", "iPhone"), sep="\t")
    break
PYTHON
)"

if [ -z "$device" ]; then
    echo "No iPhone found. Plug one in, unlock it, and trust this Mac."
    echo "Then check it is seen:  xcrun devicectl list devices"
    exit 1
fi

id="$(echo "$device" | cut -f1)"
name="$(echo "$device" | cut -f2)"
echo "==> building for $name"

xcodebuild -project "$root/TrackpadPhone.xcodeproj" \
    -scheme TrackpadPhoneiOS \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived" \
    -allowProvisioningUpdates \
    build >/dev/null

app="$derived/Build/Products/Debug-iphoneos/TrackpadPhone.app"
[ -d "$app" ] || { echo "Build produced no app at $app"; exit 1; }

echo "==> installing"
xcrun devicectl device install app --device "$id" "$app" >/dev/null

echo
echo "Done. Open TrackpadPhone on $name."
echo "First time only: on the Mac, menu bar icon → “Show pairing code…”, then “Scan code” on the phone."
