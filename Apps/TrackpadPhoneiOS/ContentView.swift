import SwiftUI
import TrackpadProtocol

struct ContentView: View {
    @State private var session = PhoneSession()
    @State private var showSettings = true
    @State private var showKeyboard = false
    @State private var showScanner = false
    @Environment(\.scenePhase) private var scenePhase

    /// Height left for the trackpad when the keyboard is up. Enough to nudge the cursor
    /// and reach a menu without dismissing anything — the keyboard takes the rest, which
    /// is the whole point of drawing our own instead of using the system one.
    ///
    /// Trimmed from 92 when the suggestion strip arrived, so the keys kept their size: the
    /// strip costs a row, and a row had to come from somewhere. Nine millimetres is still a
    /// comfortable nudge, and while the keyboard is up the strip is what the thumb is *not*
    /// using.
    private let trackpadStripHeight: Double = 56

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            surface.ignoresSafeArea()
            // While in use the surface is the whole screen; the only chrome is one small
            // button, which doubles as the connection indicator so it earns its space.
            // It alone keeps the safe area — in landscape the physical top-left corner is
            // behind the Dynamic Island.
            revealButton
            if showKeyboard { keyboard }
            if showSettings { settingsPanel }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        // Edge swipes belong to the trackpad, not to Control Centre and the app switcher.
        .defersSystemGestures(on: .all)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Paired is enough: there is nothing left to type, so there is nothing to
            // wait for the user to do.
            if session.isPaired {
                session.connect()
            }
            // Lets a launch script open the keyboard, which cannot be tapped from a script:
            //   simctl launch booted <id> -keyboard 1
            if UserDefaults.standard.bool(forKey: "keyboard") {
                showKeyboard = true
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Coming back from the background is a fresh start for the link: iOS takes the
        // connection away while the app is suspended, and `onAppear` does not fire a second
        // time. Without this the trackpad comes back dead and looks unpaired.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if session.isPaired, !session.isLive { session.connect() }
            case .background:
                session.disconnect()
            default:
                break
            }
        }
        // Out of the way when the Mac actually answers — not merely when a socket opened,
        // which is all `state` can tell us and would hide the panel over a dead link.
        .onChange(of: session.isLive) { _, live in
            if live { showSettings = false }
        }
        .onChange(of: session.state) { _, state in
            // A link that merely went quiet is the watchdog's business and is fixed without
            // anyone being told. Only a refusal is worth the user's attention.
            if case .failed = state { showSettings = true }
        }
    }

    // MARK: - Surface

    private var surface: some View {
        TouchSurface(
            onFrame: { contacts, timestamp in
                session.send(contacts: contacts, timestamp: timestamp)
            },
            onLayout: { points, scale in
                session.updateSurface(points: points, scale: scale)
            }
        )
        .background(Color(white: 0.07))
        // Touches must not reach the surface while the settings are up, or reaching for a
        // button would fling the cursor across the Mac.
        .allowsHitTesting(!showSettings)
    }

    /// The two buttons that live on top of the trackpad.
    ///
    /// Their target is deliberately larger than they look. A miss here does not do nothing —
    /// it lands on the surface underneath and clicks on the Mac, which is the most annoying
    /// failure a button can have. So the visible circle stays small and unobtrusive while
    /// `contentShape` hands each one a 56-point square to be hit in; the extra area costs
    /// nothing, because the strip along the top edge is not where anyone aims the cursor.
    private var revealButton: some View {
        HStack(spacing: 4) {
            circleButton(
                icon: "slider.horizontal.3", tint: statusColor
            ) { showSettings = true }

            circleButton(
                icon: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard", tint: .white
            ) { showKeyboard.toggle() }
        }
        .opacity(showSettings ? 0 : 0.55)
        .padding(.leading, 6)
    }

    private func circleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(Color(white: 0.16), in: Circle())
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!showSettings)
    }

    /// Deliberately *not* ignoring the horizontal safe area: in landscape the Dynamic
    /// Island sits over one edge, and the first key in the row — escape — was disappearing
    /// underneath it.
    private var keyboard: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: trackpadStripHeight)
            CustomKeyboard(onKeyInput: { session.send($0) }, isVisible: $showKeyboard)
        }
    }

    // MARK: - Settings

    private var settingsPanel: some View {
        ZStack {
            // Only the backdrop reaches the screen edges. The card itself stays inside the
            // safe area, or in landscape the Dynamic Island eats its left-hand column —
            // which is what was clipping "не підключено" down to "е підключено".
            Color.black.opacity(0.75)
                .ignoresSafeArea()
                .onTapGesture {
                    if session.isLive { showSettings = false }
                }

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.callout)
                    Spacer(minLength: 12)

                    if session.isPaired {
                        Button(session.state == .connected ? "Disconnect" : "Connect") {
                            if session.state == .connected {
                                session.disconnect()
                            } else {
                                session.connect()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    // Two buttons rather than one with a chosen style: the styles are
                    // different types, and the unpaired case is the one that has to shout.
                    if session.isPaired {
                        Button("Other Mac") { showScanner = true }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Scan code") { showScanner = true }
                            .buttonStyle(.borderedProminent)
                    }

                    if session.isLive {
                        Button("Done") { showSettings = false }
                    }
                }

                if !session.isPaired {
                    Text("On the Mac: menu bar icon → “Show pairing code…”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    Toggle("Haptics", isOn: $session.hapticsEnabled)
                        .toggleStyle(.switch)
                        .font(.caption)
                        .fixedSize()

                    Slider(value: $session.hapticStrength, in: 0.2 ... 1.0) { editing in
                        // Fires as the thumb is released, so the new strength can be felt
                        // straight away rather than guessed at.
                        if !editing { session.previewHaptic() }
                    }
                    .frame(width: 160)
                    .disabled(!session.hapticsEnabled)
                }
            }
            .padding(22)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 18))
        }
        .sheet(isPresented: $showScanner) {
            PairingScanner { code in
                session.pair(with: code)
                showScanner = false
            }
            .ignoresSafeArea()
        }
    }

    private var statusColor: Color {
        // Green means the Mac answered, not that a socket opened. See `isLive`.
        switch session.state {
        case .connected: session.isLive ? .green : .yellow
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "not connected"
        case .connecting: "connecting…"
        case .connected where session.isLive: "connected · \(session.pairedName ?? "")"
        case .connected: "looking for \(session.pairedName ?? "Mac")…"
        case .failed(let message): message
        }
    }
}
