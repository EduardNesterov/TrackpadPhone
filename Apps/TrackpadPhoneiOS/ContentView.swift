import SwiftUI
import TrackpadProtocol

struct ContentView: View {
    @State private var session = PhoneSession()
    @State private var showSettings = true
    @State private var showKeyboard = false

    /// Height left for the trackpad when the keyboard is up. Enough to nudge the cursor
    /// and reach a menu without dismissing anything — the keyboard takes the rest, which
    /// is the whole point of drawing our own instead of using the system one.
    ///
    /// Trimmed from 92 when the suggestion strip arrived, so the keys kept their size: the
    /// strip costs a row, and a row had to come from somewhere. Nine millimetres is still a
    /// comfortable nudge, and while the keyboard is up the strip is what the thumb is *not*
    /// using.
    private let trackpadStripHeight: Double = 56
    @FocusState private var hostFieldFocused: Bool

    /// The close button only acts on a second tap; this is the moment in between.
    @State private var closeArmed = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            surface.ignoresSafeArea()
            // While in use the surface is the whole screen; the only chrome is one small
            // button, which doubles as the connection indicator so it earns its space.
            // It alone keeps the safe area — in landscape the physical top-left corner is
            // behind the Dynamic Island.
            revealButton
            closeButton
            if showKeyboard { keyboard }
            if showSettings { settingsPanel }
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        // Edge swipes belong to the trackpad, not to Control Centre and the app switcher.
        .defersSystemGestures(on: .all)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if UserDefaults.standard.bool(forKey: "autoconnect") {
                session.connect()
            }
            // Lets a launch script open the keyboard, which cannot be tapped from a script:
            //   simctl launch booted <id> -keyboard 1
            if UserDefaults.standard.bool(forKey: "keyboard") {
                showKeyboard = true
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: session.state) { _, state in
            // Get out of the way as soon as the link is up, and come back if it drops.
            switch state {
            case .connected: showSettings = false
            case .failed: showSettings = true
            default: break
            }
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
        // Touches must not reach the surface while the settings are up, or adjusting the
        // address would fling the cursor across the Mac.
        .allowsHitTesting(!showSettings)
    }

    private var revealButton: some View {
        HStack(spacing: 8) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 34, height: 34)
                    .background(Color(white: 0.16), in: Circle())
            }
            .allowsHitTesting(!showSettings)

            Button {
                showKeyboard.toggle()
            } label: {
                Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(white: 0.16), in: Circle())
            }
            .allowsHitTesting(!showSettings)

            // Fingers seen in the last gesture. Makes "the gesture did nothing" answer
            // itself: swipe with three, lift, and if this still reads 2 the phone never
            // saw the third and there is no point looking at the Mac.
            Text(session.peakContacts > 0 ? "\(session.peakContacts)" : "–")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
        .opacity(showSettings ? 0 : 0.55)
        .padding(.leading, 14)
        .padding(.top, 10)
    }

    /// Leaving the app on purpose.
    ///
    /// Swiping up is deliberately made awkward — `defersSystemGestures` costs a swipe, and
    /// that is as far as iOS lets an app go; the home gesture cannot be taken away. So
    /// there has to be a way out that is meant, and this is it: the first tap only arms the
    /// button, the second closes. One stray touch in the corner does nothing, which matters
    /// because that corner is inside the trackpad.
    private var closeButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    if closeArmed {
                        session.disconnect()
                        exit(0)
                    } else {
                        closeArmed = true
                        disarmTask?.cancel()
                        disarmTask = Task {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled { closeArmed = false }
                        }
                    }
                } label: {
                    Image(systemName: closeArmed ? "power.circle.fill" : "xmark")
                        .font(.system(size: closeArmed ? 21 : 14, weight: .semibold))
                        .foregroundStyle(closeArmed ? Color.red : Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color(white: closeArmed ? 0.22 : 0.14), in: Circle())
                }
                .opacity(showSettings ? 0 : (closeArmed ? 1 : 0.35))
                .animation(.easeOut(duration: 0.15), value: closeArmed)
                .allowsHitTesting(!showSettings)
                .padding(.trailing, 12)
                .padding(.bottom, 6)
            }
        }
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
                    hostFieldFocused = false
                    if session.state == .connected { showSettings = false }
                }

            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    TextField("192.168.1.10", text: $session.host)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                        .focused($hostFieldFocused)
                        .frame(maxWidth: 220)

                    Button(session.state == .connected ? "Відʼєднати" : "Підключити") {
                        hostFieldFocused = false
                        if session.state == .connected {
                            session.disconnect()
                        } else {
                            session.connect()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    if session.state == .connected {
                        Button("Готово") { showSettings = false }
                    }
                }

                HStack(spacing: 14) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Вібрація", isOn: $session.hapticsEnabled)
                        .toggleStyle(.switch)
                        .font(.caption)
                        .fixedSize()

                    Slider(value: $session.hapticStrength, in: 0.2 ... 1.0) { editing in
                        // Fires as the thumb is released, so the new strength can be felt
                        // straight away rather than guessed at.
                        if !editing { session.previewHaptic() }
                    }
                    .frame(width: 110)
                    .disabled(!session.hapticsEnabled)
                }

                HStack(spacing: 18) {
                    metric("RTT p50", session.rttP50Ms)
                    metric("p95", session.rttP95Ms)
                    metric("max", session.rttMaxMs)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("кадрів").font(.caption2).foregroundStyle(.secondary)
                        Text("\(session.framesSent)").font(.system(.callout, design: .monospaced))
                    }
                    Button("Скинути", action: session.resetStats)
                        .font(.caption)
                        .disabled(session.echoesReceived == 0)
                }
            }
            .padding(22)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.1f", value) : "—")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(colorForLatency(value))
        }
    }

    /// Under ~50 ms feels immediate; past that the cursor visibly trails the finger.
    private func colorForLatency(_ ms: Double) -> Color {
        switch ms {
        case 0: .secondary
        case ..<25: .green
        case ..<50: .yellow
        default: .red
        }
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: "не підключено"
        case .connecting: "підключення…"
        case .connected: "підключено · \(session.echoesReceived) відлунь"
        case .failed(let message): message
        }
    }
}
