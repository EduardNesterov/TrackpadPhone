import AppKit
import ApplicationServices
import ServiceManagement
import TrackpadInput
import TrackpadMac

/// Menu bar app. No window, no Dock icon — it is a receiver that needs to be reachable
/// and quittable, which is exactly what a status item is for.
///
/// Being a real bundled app matters beyond convenience: macOS ties the Accessibility
/// grant to the running program's code signature. Run from a terminal and the permission
/// belongs to the *terminal*, so it silently follows whichever one you happened to use.
/// Signed with a stable identity, the app is granted once and stays granted.
/// Written from the event-tap callback, which is a C function pointer and cannot
/// capture context.
nonisolated(unsafe) var observedKeyEvents = 0
nonisolated(unsafe) var observedKeyDetail = ""

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let queue = DispatchQueue(label: "trackpadphone.receiver")
    private var receiver: Receiver!
    private var synthesizer: EventSynthesizer!
    /// Held so the gesture thresholds can be changed while the receiver runs, the same way
    /// the sliders change the synthesiser's.
    private var recognizer: GestureRecognizer!

    private var status: Receiver.Status = .starting {
        didSet { refreshMenu() }
    }

    private var settings = Settings.load()
    static let logPath = "/tmp/trackpadphone.log"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: "TrackpadPhone"
        )
        statusItem.button?.image?.isTemplate = true

        var config = GestureConfig()
        config.scrollGain = settings.scrollGain
        config.threeFingerDrag = settings.threeFingerDrag
        config.dragEdgePushMaxMMPerS = settings.edgePushSpeed
        config.pinchStepMM = Settings.pinchStep(forZoomSpeed: settings.zoomSpeed)

        synthesizer = EventSynthesizer(queue: queue, config: config)
        synthesizer.acceleration.sensitivity = settings.sensitivity

        // Development diagnostics. A menu bar app has nowhere to print, and "the gesture
        // did nothing" is unanswerable without seeing what was recognised — so mirror the
        // receiver's debug output into a file, truncated each launch.
        freopen(Self.logPath, "w", stdout)
        setvbuf(stdout, nil, _IOLBF, 0)

        recognizer = GestureRecognizer(config: config)
        let session = Session(recognizer: recognizer, synthesizer: synthesizer)
        session.debug = true

        receiver = Receiver(session: session, port: 51888, queue: queue)
        receiver.logsStatistics = true
        receiver.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.status = status }
        }

        do {
            try receiver.start()
        } catch {
            status = .failed(error.localizedDescription)
        }

        // Lets the probe be triggered from a script, so the experiment can be run and
        // read back without a person in the loop.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("TrackpadPhone.probe"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.runModifierProbe()
        }

        refreshMenu()
        // Ask on first launch. Afterwards the menu carries the reminder, because a modal
        // prompt on every launch would be worse than useless.
        _ = isTrusted(prompting: !settings.hasPromptedForAccessibility)
        settings.hasPromptedForAccessibility = true
        settings.save()
    }

    /// Nothing we hold down may outlive us.
    ///
    /// Both the drag's button and the zoom's ⌘ are real presses, and the WindowServer goes
    /// on believing they are down until something says otherwise — quitting mid-gesture
    /// would leave the Mac with a stuck button or a stuck modifier and no way to tell why.
    func applicationWillTerminate(_ notification: Notification) {
        synthesizer?.releaseZoomCommand()
        synthesizer?.releaseDrag()
    }

    // MARK: - Menu

    private func refreshMenu() {
        let menu = NSMenu()

        menu.addItem(disabled(statusTitle))
        for address in LocalAddresses.wifi() {
            menu.addItem(disabled("   \(address)"))
        }

        if !isTrusted(prompting: false) {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: "Дозволити керування комп’ютером…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(disabled("   без цього курсор не рухатиметься"))
        }

        menu.addItem(.separator())
        menu.addItem(slider(
            "Швидкість курсора", value: settings.sensitivity,
            range: 0.4 ... 3.0, action: #selector(sensitivityChanged)
        ))
        menu.addItem(slider(
            "Швидкість прокрутки", value: settings.scrollGain,
            range: 4 ... 48, action: #selector(scrollGainChanged)
        ))
        menu.addItem(slider(
            "Швидкість зуму (щипок)", value: settings.zoomSpeed,
            range: 0.5 ... 3.0, action: #selector(zoomSpeedChanged)
        ))

        let invert = NSMenuItem(
            title: "Зворотний напрям прокрутки",
            action: #selector(toggleScrollDirection),
            keyEquivalent: ""
        )
        invert.target = self
        invert.state = settings.invertScroll ? .on : .off
        menu.addItem(invert)

        let drag = NSMenuItem(
            title: "Перетягування трьома пальцями",
            action: #selector(toggleThreeFingerDrag),
            keyEquivalent: ""
        )
        drag.target = self
        drag.state = settings.threeFingerDrag ? .on : .off
        menu.addItem(drag)
        menu.addItem(disabled(settings.threeFingerDrag ? "   свайпи — чотирма" : "   свайпи — трьома"))

        if settings.threeFingerDrag {
            menu.addItem(slider(
                "Автопрокрутка біля краю", value: settings.edgePushSpeed,
                range: 0 ... 80, action: #selector(edgePushSpeedChanged)
            ))
            menu.addItem(disabled(settings.edgePushSpeed < 1
                ? "   вимкнено"
                : "   тягнеш до краю — їде далі само й розганяється"))
        }

        menu.addItem(.separator())
        // The phone cannot start this app: with nothing running there is nothing to hear
        // the request. Being already running is the only way "press Connect and it works"
        // can be true, so this is the setting that actually answers that wish.
        let launch = NSMenuItem(
            title: "Запускати при вході в систему",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        if let note = launchAtLoginNote {
            menu.addItem(disabled("   \(note)"))
        }

        menu.addItem(.separator())
        // Fires the shortcut without any phone involved. When a gesture "does nothing",
        // this separates a shortcut that never reaches the system from a gesture that was
        // never recognised — two very different bugs that look identical from the outside.
        let probe = NSMenuItem(
            title: "Перевірити ⌃↑ (Mission Control)",
            action: #selector(probeShortcut),
            keyEquivalent: ""
        )
        probe.target = self
        menu.addItem(probe)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Вийти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private var statusTitle: String {
        switch status {
        case .starting: "Запуск…"
        case .listening: "Очікую телефон"
        case .connected: "Підключено"
        case .failed(let message): "Помилка: \(message)"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func slider(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        action: Selector
    ) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))

        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 14, y: 24, width: 210, height: 16)
        label.font = .menuFont(ofSize: 12)
        container.addSubview(label)

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 20)
        slider.isContinuous = true
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    // MARK: - Actions

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        settings.sensitivity = sender.doubleValue
        // Applied live: tuning this by feel is the point, and a restart per nudge would
        // make it impossible to find the right value.
        queue.async { [synthesizer, settings] in
            synthesizer?.acceleration.sensitivity = settings.sensitivity
        }
        settings.save()
    }

    @objc private func scrollGainChanged(_ sender: NSSlider) {
        settings.scrollGain = sender.doubleValue
        queue.async { [synthesizer, settings] in
            synthesizer?.scrollGain = settings.scrollGain
        }
        settings.save()
    }

    /// How much zoom a millimetre of spread is worth. Two fingers on a phone have about
    /// forty millimetres of spread in them before the hand has to be repositioned, and how
    /// much of a zoom range that ought to cover is taste — so it gets a slider, like the
    /// pointer and the scroll.
    @objc private func zoomSpeedChanged(_ sender: NSSlider) {
        settings.zoomSpeed = sender.doubleValue
        queue.async { [recognizer, settings] in
            recognizer?.config.pinchStepMM = Settings.pinchStep(forZoomSpeed: settings.zoomSpeed)
        }
        settings.save()
    }

    @objc private func toggleScrollDirection() {
        settings.invertScroll.toggle()
        queue.async { [synthesizer, settings] in
            synthesizer?.naturalScrolling = EventSynthesizer.systemNaturalScrolling() != settings.invertScroll
        }
        settings.save()
        refreshMenu()
    }

    /// How fast a drag keeps travelling once the fingers reach the border. Taste, and it
    /// depends on the page, so it gets a slider rather than a constant. Zero is off, and
    /// the label under it says so.
    @objc private func edgePushSpeedChanged(_ sender: NSSlider) {
        let wasOff = settings.edgePushSpeed < 1
        settings.edgePushSpeed = sender.doubleValue
        queue.async { [recognizer, settings] in
            recognizer?.config.dragEdgePushMaxMMPerS = settings.edgePushSpeed
        }
        settings.save()
        // Only when it crosses the line: rebuilding the menu on every drag of the slider
        // would tear it out from under the cursor.
        if wasOff != (settings.edgePushSpeed < 1) { refreshMenu() }
    }

    /// Shown under the login-item toggle when the last attempt did not take.
    private var launchAtLoginNote: String?

    /// Starts the app with the session, so the phone always has something to connect to.
    ///
    /// `SMAppService` registers *this bundle at this path* — move `TrackpadPhone.app` and
    /// the login item points at where it used to be. macOS also shows the registration to
    /// the user in Settings ▸ General ▸ Login Items, where they can revoke it behind our
    /// back, so the menu reads the real status rather than a preference of our own.
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        launchAtLoginNote = nil
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            launchAtLoginNote = "не вдалося: \(error.localizedDescription)"
            print("launch at login: \(error)")
        }
        refreshMenu()
    }

    /// Three fingers drag, or three fingers swipe — not both.
    ///
    /// A drag and a swipe both start as three fingers moving, so nothing tells them apart
    /// early enough to be reliable. macOS makes the same trade in its own settings: turn
    /// the three-finger drag on and the swipes move to four fingers.
    @objc private func toggleThreeFingerDrag() {
        settings.threeFingerDrag.toggle()
        queue.async { [recognizer, settings] in
            recognizer?.config.threeFingerDrag = settings.threeFingerDrag
        }
        settings.save()
        refreshMenu()
    }

    /// Fires ⌃↑ three ways and records which one the system honoured.
    ///
    /// Whether a symbolic hotkey accepts a synthesised modifier depends on how that
    /// modifier is expressed, and no documentation settles it. Rather than guess and ask
    /// someone to re-test each time, the app runs the experiment and writes the answer
    /// down: Mission Control makes the Dock frontmost, which is observable from here.
    private func runModifierProbe() {
        queue.async { [weak self] in
            guard let self, let synthesizer = self.synthesizer else { return }
            print("--- probe start ---")

            // Control case: open Mission Control the ordinary way. If the detector cannot
            // see even this, the detector is what is broken, and every "no" below is noise.
            let controlBefore = Self.dockWindowCount()
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            usleep(1_200_000)
            print("probe launchApp: dock windows \(controlBefore) → \(Self.dockWindowCount())")
            synthesizer.sendEscape()
            usleep(600_000)

            let matrix: [(EventSynthesizer.ModifierStyle, CGEventTapLocation, String)] = [
                (.flagsOnly, .cghidEventTap, "hid"),
                (.modifierKey, .cghidEventTap, "hid"),
                (.flagsChanged, .cghidEventTap, "hid"),
                (.modifierKey, .cgSessionEventTap, "session"),
                (.flagsChanged, .cgSessionEventTap, "session"),
            ]

            for (style, tap, tapName) in matrix {
                let before = Self.dockWindowCount()
                synthesizer.sendMissionControl(style: style, tap: tap)
                usleep(800_000)
                let after = Self.dockWindowCount()
                print("probe \(style.rawValue)@\(tapName): dock windows \(before) → \(after)")
                if after > before {
                    synthesizer.sendEscape()
                    usleep(600_000)
                }
            }
            // Does a synthesised keystroke reach the event stream at all? If a listen-only
            // tap sees it, the events exist and the hotkey layer is refusing them by
            // policy, and no amount of reshaping will help. If the tap sees nothing, they
            // are dropped before delivery, which is a different problem entirely.
            observedKeyEvents = 0
            observedKeyDetail = ""
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                eventsOfInterest: CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)),
                callback: { _, _, event, _ in
                    observedKeyEvents += 1
                    observedKeyDetail += "[t\(event.type.rawValue) k\(event.getIntegerValueField(.keyboardEventKeycode)) f\(event.flags.rawValue)]"
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            ) {
                let loop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), loop, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)

                synthesizer.sendSpaceLeft(style: .flagsChanged)
                CFRunLoopRunInMode(.defaultMode, 0.6, false)
                print("probe tap saw \(observedKeyEvents) key events \(observedKeyDetail)")

                CGEvent.tapEnable(tap: tap, enable: false)
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), loop, .commonModes)
            } else {
                print("probe tap: could not create event tap")
            }

            // Does an ordinary application shortcut survive synthesis, even though a
            // system hotkey does not? Finder answers it cheaply and reversibly: ⌘N opens
            // a window, ⌘W closes it again.
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
            usleep(700_000)
            let finderBefore = Self.windowCount(owner: "Finder")
            synthesizer.sendCommandKey(45)   // N
            usleep(900_000)
            let finderAfter = Self.windowCount(owner: "Finder")
            print("probe app-shortcut ⌘N: finder windows \(finderBefore) → \(finderAfter)")
            if finderAfter > finderBefore {
                synthesizer.sendCommandKey(13)  // W
                usleep(500_000)
            }

            print("--- probe end ---")
        }
    }

    private static func dockWindowCount() -> Int { windowCount(owner: "Dock") }

    static func windowCount(owner: String) -> Int {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return -1 }
        return windows.filter { ($0[kCGWindowOwnerName as String] as? String) == owner }.count
    }

    @objc private func probeShortcut() {
        // Off the main thread: the synthesizer paces key events with short sleeps so the
        // WindowServer sees the modifier settle, and blocking the menu would be rude.
        queue.async { [synthesizer] in
            synthesizer?.apply(.shortcut(.missionControl))
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func isTrusted(prompting: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompting]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

/// Preferences live in UserDefaults; there is nothing here worth a file format.
struct Settings {
    var sensitivity: Double = 1.0
    var scrollGain: Double = 16.0
    var invertScroll = false
    var threeFingerDrag = true
    var edgePushSpeed: Double = 30
    /// A multiplier over the zoom's default feel rather than a threshold, so the number in
    /// the recogniser can be retuned without stranding everyone's saved setting on the old
    /// scale. One is whatever the default currently is; two is twice the zoom per pinch.
    var zoomSpeed: Double = 1.0
    var hasPromptedForAccessibility = false

    /// Millimetres of spread per zoom notch. Inverted: more speed is a shorter step.
    static func pinchStep(forZoomSpeed speed: Double) -> Double {
        GestureConfig().pinchStepMM / max(0.1, speed)
    }

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        var settings = Settings()
        if defaults.object(forKey: "sensitivity") != nil {
            settings.sensitivity = defaults.double(forKey: "sensitivity")
        }
        if defaults.object(forKey: "scrollGain") != nil {
            settings.scrollGain = defaults.double(forKey: "scrollGain")
        }
        settings.invertScroll = defaults.bool(forKey: "invertScroll")
        // Defaults to on, so it cannot be read with `bool(forKey:)` — an absent key and a
        // deliberate "off" both read as false.
        if defaults.object(forKey: "threeFingerDrag") != nil {
            settings.threeFingerDrag = defaults.bool(forKey: "threeFingerDrag")
        }
        if defaults.object(forKey: "edgePushSpeed") != nil {
            settings.edgePushSpeed = defaults.double(forKey: "edgePushSpeed")
        }
        if defaults.object(forKey: "zoomSpeed") != nil {
            settings.zoomSpeed = defaults.double(forKey: "zoomSpeed")
        }
        settings.hasPromptedForAccessibility = defaults.bool(forKey: "hasPromptedForAccessibility")
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(scrollGain, forKey: "scrollGain")
        defaults.set(invertScroll, forKey: "invertScroll")
        defaults.set(threeFingerDrag, forKey: "threeFingerDrag")
        defaults.set(edgePushSpeed, forKey: "edgePushSpeed")
        defaults.set(zoomSpeed, forKey: "zoomSpeed")
        defaults.set(hasPromptedForAccessibility, forKey: "hasPromptedForAccessibility")
    }
}

/// `--login-item on|off|status` — set the login item and exit, without the menu bar.
///
/// The menu has the same switch; this exists so it can be scripted, and so that whether
/// registration is accepted at all can be checked without a person clicking a menu item
/// and reporting back. Login items are refused for bundles macOS distrusts — quarantined,
/// translocated, badly signed — and the failure is silent from the user's side.
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let service = SMAppService.mainApp
    let wanted = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "status"
    do {
        switch wanted {
        case "on": try service.register()
        case "off": try service.unregister()
        default: break
        }
        print("login item: \(service.status == .enabled ? "enabled" : "status \(service.status.rawValue)")")
    } catch {
        print("login item failed: \(error)")
        exit(1)
    }
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
