import ApplicationServices
import Foundation
import TrackpadInput

// stdout is block-buffered when it is not a terminal, which silently swallows every
// diagnostic the moment you pipe or redirect this. Line buffering costs nothing here.
setvbuf(stdout, nil, _IOLBF, 0)

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func flag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

let port = UInt16(argument("--port") ?? "") ?? 51888
let sensitivity = Double(argument("--sensitivity") ?? "") ?? 1.0
let scrollGain = Double(argument("--scroll-gain") ?? "")

// Posting CGEvents requires Accessibility. For a binary launched from a shell, macOS
// attributes the permission to the *terminal*, not to this executable — so the entry to
// tick is Terminal (or iTerm), and it must be restarted after granting.
let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(prompt) {
    print("""

    ⚠️  No Accessibility permission — nothing will move.

        System Settings → Privacy & Security → Accessibility
        Add and enable your terminal app, then quit it fully (⌘Q) and run this again.

        Still listening, so you can check that packets arrive.

    """)
}

var config = GestureConfig()
if let scrollGain { config.scrollGain = scrollGain }

let queue = DispatchQueue(label: "trackpadphone.receiver")
let synthesizer = EventSynthesizer(queue: queue, config: config)
synthesizer.acceleration.sensitivity = sensitivity
if flag("--invert-scroll") {
    synthesizer.naturalScrolling.toggle()
}

let recognizer = GestureRecognizer(config: config)
let session = Session(recognizer: recognizer, synthesizer: synthesizer)
let receiver = Receiver(session: session, port: port, queue: queue)

print("""
TrackpadPhone receiver — sensitivity \(sensitivity), \
scroll \(config.scrollGain), \
\(synthesizer.naturalScrolling ? "natural" : "reversed") scrolling

  one finger      move          ·  tap        click
  two fingers     scroll        ·  two-tap    right click
  pinch           zoom          ·  tap+drag   drag
  three fingers   ↑ Mission Control  ↓ App Windows  ←→ spaces
""")
for address in LocalAddresses.wifi() {
    print("  enter this on the phone:  \(address)")
}

do {
    try receiver.start()
} catch {
    print("could not start: \(error)")
    exit(1)
}

dispatchMain()
