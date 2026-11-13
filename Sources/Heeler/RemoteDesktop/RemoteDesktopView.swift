import SillClient
import SwiftUI

/// Remote Desktop, full screen over black. The sill stream draws the screen,
/// its window bar, its keyboard and its settings; this view draws only the way
/// out and the link's own state until the Mac's window list arrives.
struct RemoteDesktopView: View {
    @State private var store: RemoteDesktopStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(store: RemoteDesktopStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let ready = store.ready {
                // The plain door reads "connected" before the Mac has answered,
                // so the screen's state follows the window list, not the socket.
                SillStreamView(host: "127.0.0.1", port: ready.port) { state in
                    switch state {
                    case .connecting: break
                    case .connected: store.sillListed()
                    case .failed(let message): store.sillFailed(message)
                    }
                }
                .ignoresSafeArea()
                .id(ready.port)
            }
            if store.state != .connected {
                controls
                // Step 3 is sill's own dial, and it draws its own line; this
                // layer speaks only for the steps before it and for failures.
                if store.state != .connecting(step: 3) { overlay }
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: scenePhase) { _, phase in
            // The phone cannot hold the stream in the background and nobody
            // sees it, so the Host session stops now.
            if phase == .background {
                store.pause()
            } else if phase == .active { store.resume() }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                glassButton("xmark", label: "Close") { close() }
                Spacer(minLength: 0)
                statusCapsule
            }
            .padding(.horizontal, 12).padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 12)
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Circle().fill(store.state.statusColor).frame(width: 8, height: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .glassBackground(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(store.state.statusLabel))
    }

    // MARK: Overlay

    private var overlay: some View {
        VStack(spacing: 16) {
            if case .connecting(let step) = store.state {
                ProgressView().controlSize(.large).tint(.white)
                Text("\(step)/3")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                overlayText(RemoteDesktopState.line(forStep: step))
            } else if let message = store.state.overlay {
                Image(systemName: message.icon).font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(message.color).accessibilityHidden(true)
                overlayText(message.text)
                Button(message.action) { reconnect() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 280)
        .glassBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func overlayText(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }

    // MARK: Glass

    private func glassButton(
        _ symbol: String, label: LocalizedStringKey, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).rdGlyph(16, weight: .semibold)
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassBackground(in: Circle())
        .accessibilityLabel(Text(label))
    }

    // MARK: Actions

    private func close() {
        store.stop()
        dismiss()
    }

    private func reconnect() {
        store.reconnect()
    }
}

extension RemoteDesktopState {
    /// A state that is not connected: one icon, one sentence, one button.
    var overlay: (icon: String, color: Color, text: String, action: String)? {
        switch self {
        case .connecting, .connected: nil
        case .failed(let reason):
            ("exclamationmark.triangle.fill", .red, reason, String(localized: "Retry"))
        case .paused:
            ("pause.circle.fill", .white.opacity(0.8), String(localized: "Paused"),
             String(localized: "Reconnect"))
        case .notInstalled:
            ("shippingbox", .orange,
             String(localized: "Remote Desktop is not installed on this Mac."),
             String(localized: "Retry"))
        case .needsPermission:
            ("lock.shield.fill", .orange,
             String(
                localized:
                    "Give Heeler Remote Desktop Screen Recording and Accessibility in the Mac's Privacy settings."
             ),
             String(localized: "Retry"))
        }
    }
}

extension View {
    /// A white SF Symbol at the bar's size, the one look every control shares.
    func rdGlyph(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        font(.system(size: size, weight: weight)).foregroundStyle(.white)
    }
}

extension View {
    func glassBackground(in shape: some Shape) -> some View {
        background {
            if #available(iOS 26, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .contentShape(shape)
    }
}
