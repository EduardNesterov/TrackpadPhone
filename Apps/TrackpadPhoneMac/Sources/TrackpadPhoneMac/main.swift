import AppKit
import ApplicationServices
import TrackpadInput
import TrackpadMac

/// Menu bar app. No window, no Dock icon — it is a receiver that needs to be reachable
/// and quittable, which is exactly what a status item is for.
///
/// Being a real bundled app matters beyond convenience: macOS ties the Accessibility
/// grant to the running program's code signature. Run from a terminal and the permission
/// belongs to the *terminal*, so it silently follows whichever one you happened to use.
/// Signed with a stable identity, the app is granted once and stays granted.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let queue = DispatchQueue(label: "trackpadphone.receiver")
    private var receiver: Receiver!
    private var synthesizer: EventSynthesizer!

    private var status: Receiver.Status = .starting {
        didSet { refreshMenu() }
    }

    private var settings = Settings.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: "TrackpadPhone"
        )
        statusItem.button?.image?.isTemplate = true

        var config = GestureConfig()
        config.scrollGain = settings.scrollGain

        synthesizer = EventSynthesizer(queue: queue, config: config)
        synthesizer.acceleration.sensitivity = settings.sensitivity

        let recognizer = GestureRecognizer(config: config)
        let session = Session(recognizer: recognizer, synthesizer: synthesizer)

        receiver = Receiver(session: session, port: 51888, queue: queue)
        receiver.logsStatistics = false
        receiver.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.status = status }
        }

        do {
            try receiver.start()
        } catch {
            status = .failed(error.localizedDescription)
        }

        refreshMenu()
        // Ask on first launch. Afterwards the menu carries the reminder, because a modal
        // prompt on every launch would be worse than useless.
        _ = isTrusted(prompting: !settings.hasPromptedForAccessibility)
        settings.hasPromptedForAccessibility = true
        settings.save()
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
            range: 2 ... 24, action: #selector(scrollGainChanged)
        ))

        let invert = NSMenuItem(
            title: "Зворотний напрям прокрутки",
            action: #selector(toggleScrollDirection),
            keyEquivalent: ""
        )
        invert.target = self
        invert.state = settings.invertScroll ? .on : .off
        menu.addItem(invert)

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

    @objc private func toggleScrollDirection() {
        settings.invertScroll.toggle()
        queue.async { [synthesizer, settings] in
            synthesizer?.naturalScrolling = EventSynthesizer.systemNaturalScrolling() != settings.invertScroll
        }
        settings.save()
        refreshMenu()
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
    var scrollGain: Double = 8.0
    var invertScroll = false
    var hasPromptedForAccessibility = false

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
        settings.hasPromptedForAccessibility = defaults.bool(forKey: "hasPromptedForAccessibility")
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(scrollGain, forKey: "scrollGain")
        defaults.set(invertScroll, forKey: "invertScroll")
        defaults.set(hasPromptedForAccessibility, forKey: "hasPromptedForAccessibility")
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
