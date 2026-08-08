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

# Substituted by `git archive`, so a copy that has been handed on knows its own version.
# In the working tree it stays a literal placeholder, which is the honest answer there.
version='$Format:%h, %cs$'
case "$version" in
    \$Format*) version="working copy" ;;
esac
echo "TrackpadPhone install ($version)"

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
# Whose Mac is this?
#
# The project carries the author's team and bundle identifier, and neither travels. A free
# Apple ID cannot register a bundle identifier that another team already claimed, so on
# anybody else's machine the build fails with "failed to register bundle identifier" —
# which points at nothing useful.
#
# The team comes out of the certificate's OU field, not from the name in brackets after
# the email: that one is a different identifier entirely, and mistaking them produces
# "No Account for Team", which points somewhere else again.
project_team="$(grep -m1 'DEVELOPMENT_TEAM = ' "$root/TrackpadPhone.xcodeproj/project.pbxproj" \
    | sed 's/.*= *//; s/;.*//')"

# Every signing identity on this Mac, and the team each one belongs to.
#
# Not `security find-certificate -c "Apple Development"`: that matches one exact name, and
# the name depends on what kind of account was added and when Apple last renamed the
# certificates. Asking the identity list instead means anything that can actually sign is
# found, whatever it is called.
local_team="$(python3 <<'PYTHON'
import re, subprocess

def run(cmd, stdin=None):
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True).stdout

listed = run(["security", "find-identity", "-v", "-p", "codesigning"])
teams = []
for name in re.findall(r'"([^"]+)"', listed):
    pem = run(["security", "find-certificate", "-c", name, "-p"])
    subject = run(["openssl", "x509", "-noout", "-subject"], stdin=pem)
    found = re.search(r"OU\s*=\s*([A-Z0-9]{8,12})", subject)
    if found:
        teams.append(found.group(1))
print(teams[0] if teams else "")
PYTHON
)"

# macOS still ships bash 3.2, where expanding an empty array under `set -u` is an error
# rather than nothing — hence the guard at the use site below.
overrides=()
if [ -n "$local_team" ] && [ "$local_team" != "$project_team" ]; then
    # Derived from the team, which is globally unique, so two people can never collide.
    # Only when the teams differ: on the machine this was written on, nothing changes, and
    # the app keeps its identity — and with it everything stored under that identity.
    own_id="com.$(echo "$local_team" | tr '[:upper:]' '[:lower:]').trackpadphone"
    overrides=(DEVELOPMENT_TEAM="$local_team" PRODUCT_BUNDLE_IDENTIFIER="$own_id")
    echo "==> your team is $local_team, so building as $own_id"
elif [ -z "$local_team" ]; then
    # No team could be read from any certificate.
    #
    # An empty DEVELOPMENT_TEAM is not a way out — tested, and xcodebuild answers "Signing
    # requires a development team" and stops. Neither is guessing. So: stop here, show what
    # is actually on this Mac, and point at the one place that can fix it for good. Opening
    # the project once and choosing an account makes Xcode create the certificate, and every
    # run after that finds it.
    echo "Could not work out which Apple developer team to build under."
    echo
    echo "Signing identities found on this Mac:"
    security find-identity -v -p codesigning | sed 's/^/    /' || true
    echo
    echo "Fix it once, in the app that owns this:"
    echo "    open $root/TrackpadPhone.xcodeproj"
    echo "    target TrackpadPhoneiOS → Signing & Capabilities → Team → your Apple ID"
    echo "    change Bundle Identifier to something of your own, then press ▶"
    echo
    echo "After that this script works on its own."
    exit 1
fi

echo "==> building for $name"

xcodebuild -project "$root/TrackpadPhone.xcodeproj" \
    -scheme TrackpadPhoneiOS \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$derived" \
    -allowProvisioningUpdates \
    ${overrides[@]+"${overrides[@]}"} \
    build >/dev/null

app="$derived/Build/Products/Debug-iphoneos/TrackpadPhone.app"
[ -d "$app" ] || { echo "Build produced no app at $app"; exit 1; }

echo "==> installing"
xcrun devicectl device install app --device "$id" "$app" >/dev/null

echo
echo "Done. Open TrackpadPhone on $name."
echo "First time only: on the Mac, menu bar icon → “Show pairing code…”, then “Scan code” on the phone."
