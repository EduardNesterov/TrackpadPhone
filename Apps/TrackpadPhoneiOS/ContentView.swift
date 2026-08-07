import SwiftUI

struct ContentView: View {
    @State private var session = PhoneSession()
    @State private var showSettings = true
    @FocusState private var hostFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            surface.ignoresSafeArea()
            // While in use the surface is the whole screen; the only chrome is one small
            // button, which doubles as the connection indicator so it earns its space.
            // It alone keeps the safe area — in landscape the physical top-left corner is
            // behind the Dynamic Island.
            revealButton
            if showSettings { settingsPanel.ignoresSafeArea() }
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

    // MARK: - Settings

    private var settingsPanel: some View {
        ZStack {
            Color.black.opacity(0.75)
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
