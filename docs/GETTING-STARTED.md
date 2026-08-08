# TrackpadPhone — setting it up

Your iPhone becomes a trackpad and keyboard for a Mac, over your own Wi-Fi. Nothing leaves
the network and there is no account to make.

You need a Mac and an iPhone on the same Wi-Fi, and — for the phone half — **Xcode**, which
is free from the App Store. Xcode is the awkward part, and there is no way around it: Apple
only lets an iPhone run an app that somebody built for it. See *Why Xcode* at the end.

---

## 1. The Mac half

From a Terminal, in the project folder:

```sh
./scripts/build-mac-app.sh && open dist/TrackpadPhone.app
```

An icon appears in the menu bar; there is no window. Two things to do from that icon:

- **Allow control of this Mac…** — opens System Settings. Tick TrackpadPhone under
  Accessibility. Without it the pointer will not move, and nothing will say why.
- **Start at login** — worth turning on. The phone cannot start this app: until it is
  running there is nothing listening for the phone to reach.

## 2. The phone half

Once, on the iPhone: **Settings → Privacy & Security → Developer Mode → on**, and restart
the phone when it asks. The switch only appears after a Mac has tried to install something,
so if you cannot find it, do the next step first and come back.

**Add your Apple ID to Xcode first** — open Xcode, then Settings (⌘,) → Accounts → “+” →
Apple ID, and sign in. Nothing can install an app on an iPhone without this; it is Apple's
rule, not this project's. A free Apple ID is enough.

Plug the phone in, unlock it, tap **Trust** if asked, then from the same Terminal:

```sh
./scripts/install-phone.sh
```

It finds the phone, builds, and installs. The first build takes a few minutes.

The script notices whose Mac it is running on: the project carries its author's Apple team
and app identifier, and neither of those can be reused by anybody else, so on your machine
it quietly builds under your own. You do not have to change anything in Xcode.

If signing fails, the message comes from Xcode and names the real problem. The usual one is
the Apple ID above. If you would rather do it by hand: open `TrackpadPhone.xcodeproj`,
select the **TrackpadPhoneiOS** target → *Signing & Capabilities*, pick your account under
*Team*, change *Bundle Identifier* to something of your own (anything, e.g.
`com.yourname.trackpadphone`), and press ▶. That path always works and shows you exactly
what it is unhappy about.

If the install ends in a *transport error*, the phone's connection dropped — unlock it,
leave it on, and run the script again. It is safe to run any number of times.

## 3. Pairing — once

Open TrackpadPhone on the phone. It will say it is not paired.

On the Mac: menu bar icon → **Show pairing code…**. On the phone: **Scan code**, and point
the camera at the Mac's screen.

That is the whole of it. The phone remembers the Mac and finds it again by itself, even
after the router hands out different addresses. You should never have to scan again unless
you deliberately make a new code.

Once you have seen it work, turn on **Accept only the paired phone** in the Mac's menu.
Until you do, anything on your network can move the pointer and type — the setting starts
off so that a failed pairing cannot leave you with no way to click.

---

## Using it

- One finger moves the pointer, tap to click, two fingers scroll and pinch.
- Three fingers pick something up and carry it — drag into the edge of the pad and it keeps
  travelling, faster the longer you hold. Four fingers swipe.
- The keyboard button is at the top left. Hold ⌫ to delete quickly, keep holding for whole
  words.
- Speeds are all on sliders in the Mac's menu. Change them while using it; they apply live.

## Why Xcode, and the seven days

Apple lets a free Apple ID install your own builds on your own phone, and that permission
lasts **seven days**. After that the app refuses to open until you run
`./scripts/install-phone.sh` again — which takes a few seconds and loses nothing, because
the pairing lives in the phone's Keychain rather than in the app.

A paid Apple Developer account ($99 a year) replaces this with TestFlight, where the person
using it taps a link and never sees Xcode at all, and builds last ninety days. That is the
only way to make this genuinely easy for someone who does not want a developer's Mac.

## When something is not working

The Mac writes a line a second to `/tmp/trackpadphone.log` while the phone is being touched:

```sh
tail -f /tmp/trackpadphone.log
```

- **Nothing at all** — the Mac is not hearing the phone. Check both are on the same Wi-Fi.
- **`refused a packet`** — the two ends disagree about the secret. Show the code again and
  re-scan.
- **The pointer does not move but frames arrive** — Accessibility permission.
- The phone's own indicator: yellow means it opened a socket but the Mac has not answered;
  green means the Mac answered. It reconnects on its own, so yellow should not last.
