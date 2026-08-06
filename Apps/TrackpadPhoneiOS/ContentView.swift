import SwiftUI

struct ContentView: View {
    @State private var session = PhoneSession()
    @FocusState private var hostFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            surface
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        // The screen must not sleep mid-swipe.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Lets a launch script skip the address field and the button:
            //   simctl launch booted <id> -trackpadphone.host 127.0.0.1 -autoconnect 1
            // UserDefaults picks up `-key value` launch arguments on its own.
            if UserDefaults.standard.bool(forKey: "autoconnect") {
                session.connect()
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Mac address, e.g. 192.168.1.10", text: $session.host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .focused($hostFieldFocused)

                Button(session.state == .connected ? "Stop" : "Connect") {
                    hostFieldFocused = false
                    if session.state == .connected {
                        session.disconnect()
                    } else {
                        session.connect()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: session.resetStats)
                    .font(.caption)
                    .disabled(session.echoesReceived == 0)
            }

            // The number M0 exists to produce.
            HStack(spacing: 16) {
                metric("RTT p50", session.rttP50Ms)
                metric("p95", session.rttP95Ms)
                metric("max", session.rttMaxMs)
                VStack(alignment: .leading, spacing: 2) {
                    Text("frames").font(.caption2).foregroundStyle(.secondary)
                    Text("\(session.framesSent)").font(.system(.body, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.1f ms", value) : "—")
                .font(.system(.body, design: .monospaced))
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

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.12))

            if session.state != .connected {
                Text("not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TouchSurface(
                onFrame: { contacts, timestamp in
                    session.send(contacts: contacts, timestamp: timestamp)
                },
                onLayout: { points, scale in
                    session.updateSurface(points: points, scale: scale)
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
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
        case .idle: "idle"
        case .connecting: "connecting…"
        case .connected: "connected · \(session.echoesReceived) echoes"
        case .failed(let message): message
        }
    }
}
