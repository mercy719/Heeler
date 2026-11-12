import SwiftUI
import UIKit

/// Remote Desktop, full screen over black. The page draws the picture; this
/// screen draws only what a page cannot: the way out, the link's state, the
/// keys a phone keyboard has no room for, and the menu.
struct RemoteDesktopView: View {
    @State private var store: RemoteDesktopStore
    @State private var page = RemoteDesktopPage()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RemoteDesktopSettings.qualityKey) private var quality = RemoteDesktopQuality.standard
    @AppStorage(RemoteDesktopSettings.touchModeKey)
    private var touchMode = RemoteDesktopTouchMode.trackpad
    @State private var isKeyboardShown = false
    @State private var modifiers: Set<RemoteDesktopModifier> = []
    /// What the fixed controls cover, for the zoom follow's edges.
    private let barHeight: CGFloat = 56

    init(store: RemoteDesktopStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let ready = store.ready, let url = store.pageURL {
                RemoteDesktopWebView(
                    url: url,
                    quality: store.quality,
                    ready: ready,
                    touchMode: store.touchMode,
                    covered: (barHeight, barHeight),
                    page: page,
                    onStats: { store.received(stats: $0) },
                    onFirstFrame: { store.receivedFirstFrame() }
                )
                .ignoresSafeArea()
                .id(url)
            }
            controls
            if store.state != .connected { overlay }
            RemoteDesktopKeyboard(
                isShown: $isKeyboardShown,
                isEnabled: store.state == .connected,
                onChange: typed,
                onBackspaceOnEmpty: { press(.backspace) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            store.quality = quality
            store.touchMode = touchMode
            store.start()
        }
        .onDisappear { store.stop() }
        .onChange(of: scenePhase) { _, phase in
            // The phone cannot hold the stream in the background and nobody
            // sees it, so the Host session stops now.
            if phase == .background {
                isKeyboardShown = false
                store.pause()
            } else if phase == .active { store.resume() }
        }
        .onChange(of: quality) { _, value in
            store.quality = value
            isKeyboardShown = false
        }
        .onChange(of: touchMode) { _, value in
            store.touchMode = value
            page.call("touchMode", value.pageValue)
        }
        .onChange(of: store.state) { _, value in if value != .connected { isKeyboardShown = false } }
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
            VStack(spacing: 12) {
                glassButton("doc.on.clipboard", label: "Paste from iPhone") { paste() }
                    .disabled(store.state != .connected || !UIPasteboard.general.hasStrings)
                glassButton(
                    isKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard",
                    label: isKeyboardShown ? "Hide Keyboard" : "Show Keyboard"
                ) { isKeyboardShown.toggle() }
                .disabled(store.state != .connected)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
            if isKeyboardShown { keyRow }
        }
        .padding(.bottom, 12)
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Circle().fill(store.state.statusColor).frame(width: 8, height: 8)
            if let latency = store.latencyMS {
                Text("\(latency) ms")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Menu { menuContent } label: {
                Image(systemName: "ellipsis").rdGlyph(15, weight: .semibold)
                    .frame(width: 28, height: 28).contentShape(Circle())
            }
            .accessibilityLabel(Text("Remote Desktop Options"))
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: 44)
        .glassBackground(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(store.state.statusLabel))
    }

    @ViewBuilder private var menuContent: some View {
        Picker("Touch Mode", selection: $touchMode) {
            Label("Trackpad", systemImage: "cursorarrow.motionlines")
                .tag(RemoteDesktopTouchMode.trackpad)
            Label("Direct Touch", systemImage: "hand.tap")
                .tag(RemoteDesktopTouchMode.direct)
        }
        Button("Fit to Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
            page.call("fit")
        }
        Picker("Quality", selection: $quality) {
            ForEach(RemoteDesktopQuality.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
        }
        Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
        Divider()
        Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { close() }
    }

    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                key("keyboard.chevron.compact.down", "Hide Keyboard") { isKeyboardShown = false }
                key("escape", "Escape") { press(.escape) }
                key("arrow.right.to.line", "Tab") { press(.tab) }
                ForEach(RemoteDesktopModifier.allCases, id: \.self) { modifierKey($0) }
                key("arrow.left", "Left Arrow") { press(.left) }
                key("arrow.up", "Up Arrow") { press(.up) }
                key("arrow.down", "Down Arrow") { press(.down) }
                key("arrow.right", "Right Arrow") { press(.right) }
                key("delete.left", "Delete") { press(.backspace) }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
        .glassBackground(in: Rectangle())
        .padding(.top, 8)
    }

    private func key(
        _ symbol: String, _ label: LocalizedStringKey, action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).rdGlyph(16)
                .frame(width: 40, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// A modifier locks until the next key lets it go, and the key that names
    /// it is its own SF Symbol (`control`, `option`, `command`, `shift`).
    private func modifierKey(_ modifier: RemoteDesktopModifier) -> some View {
        let isOn = modifiers.contains(modifier)
        return Button {
            if isOn { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
            page.call("modifier", modifier.pageCode, !isOn)
        } label: {
            Image(systemName: modifier.symbolName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .white)
                .frame(width: 40, height: 36)
                .background(isOn ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(modifier.symbolName))
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
        isKeyboardShown = false
        store.stop()
        dismiss()
    }

    private func reconnect() {
        isKeyboardShown = false
        store.reconnect()
    }

    private func press(_ key: RemoteDesktopKey) {
        page.call("key", key.pageCode, key.keyValue)
        releaseModifiers()
    }

    private func releaseModifiers() {
        for modifier in modifiers { page.call("modifier", modifier.pageCode, false) }
        modifiers.removeAll()
    }

    private func typed(before: String, after: String) {
        let change = RemoteDesktopTyped.change(before: before, after: after)
        for _ in 0..<change.backspaces { page.call("key", "Backspace", "Backspace") }
        if !change.text.isEmpty { page.call("type", change.text) }
        // A held modifier is for one shortcut, such as Cmd+C.
        if change.backspaces > 0 || !change.text.isEmpty { releaseModifiers() }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        releaseModifiers()
        page.call("type", String(text.prefix(2_000)))
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
                    "Give Sunshine Screen Recording and Accessibility in the Mac's Privacy settings."
             ),
             String(localized: "Retry"))
        }
    }
}

/// What the page can be told to press: the US keyboard codes Moonlight reads
/// off `KeyboardEvent`, which travel as they are.
enum RemoteDesktopKey: String, Sendable {
    case escape = "Escape"
    case tab = "Tab"
    case backspace = "Backspace"
    case left = "ArrowLeft"
    case right = "ArrowRight"
    case up = "ArrowUp"
    case down = "ArrowDown"

    var pageCode: String { rawValue }
    var keyValue: String { rawValue }
}

enum RemoteDesktopModifier: String, Hashable, Sendable, CaseIterable {
    case control = "ControlLeft"
    case option = "AltLeft"
    case command = "MetaLeft"
    case shift = "ShiftLeft"

    var pageCode: String { rawValue }

    /// Its SF Symbol, which is the key's own name.
    var symbolName: String { pageCode.replacingOccurrences(of: "Left", with: "").lowercased() }
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
