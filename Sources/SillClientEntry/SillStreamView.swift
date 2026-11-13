import Network
import StreamProtocol
import SwiftUI

/// What the host UI says about the sill session it shows.
public enum SillStreamState: Equatable, Sendable {
    case connecting
    case connected(macName: String)
    case failed(String)
}

/// The sill stream over an address a Heeler session already reaches: the same client the upstream
/// app uses, dialled directly (`StreamClient.connect(to:name:)`) instead of through Bonjour, so no
/// local-network browse runs. Wired the way upstream's `ContentView` wires it; the connect screen
/// is replaced by a bare status layer because Heeler owns the chrome (plan §3).
@MainActor
public struct SillStreamView: View {
    private let host: String
    private let port: UInt16
    private let onState: @MainActor (SillStreamState) -> Void

    @StateObject private var client = StreamClient()
    /// Tells the Mac what this device sees, once a second while connected (`ContentView`).
    @StateObject private var statsReporter = ClientStatsReporter()
    @Environment(\.scenePhase) private var scenePhase
    /// The Mac's first window list arrived: the session is really up, not just the socket. The
    /// plain door reads "connected" before the Mac has answered (plan §3's pitfall).
    @State private var listed = false
    /// The dial's end was reported; later lines belong to sill's own reconnect, not to us.
    @State private var ended = false
    /// The 60 fps / 8 Mbps pick went out once (`changeSettings` sends nothing before the Mac's
    /// first settings state).
    @State private var sentQuality = false

    public init(host: String, port: UInt16, onState: @escaping @MainActor (SillStreamState) -> Void) {
        Self.skipFirstRunGuide()
        self.host = host
        self.port = port
        self.onState = onState
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if listed {
                StreamScreen(client: client)
            } else {
                WaitingLayer(text: client.status, waiting: !ended)
            }
        }
        .preferredColorScheme(.dark)
        // Tells sill which window shows the session (the iPad menu bar, the auto-lock timer).
        .background(WindowSessionObserver(client: client))
        .readsDuoPosture()
        .onAppear(perform: start)
        .onDisappear { client.disconnect() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            client.sound.setSceneForeground(phase != .background)
        }
        .onChange(of: client.macName, initial: true) { _, name in
            guard !name.isEmpty else { return }
            listed = true
            onState(.connected(macName: name))
        }
        .onChange(of: client.settings) { _, _ in sendQuality() }
        .onChange(of: client.status) { _, line in
            guard !listed, !ended else { return }
            // "Connecting to…" and "Waiting for…" are the dial going on; anything else is its end.
            if line.hasPrefix("Connecting to") || line.hasPrefix("Waiting for") {
                onState(.connecting)
            } else {
                ended = true
                onState(.failed(line))
            }
        }
    }

    private func start() {
        statsReporter.attach(to: client)
        onState(.connecting)
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            ended = true
            onState(.failed("Invalid port \(port)"))
            return
        }
        client.connect(to: .hostPort(host: NWEndpoint.Host(host), port: endpointPort), name: "Mac")
    }

    /// The plan's §2 starting point: the plain door carries no away-from-home downshift, so the
    /// Mac's LAN defaults (120 fps) are cut here. Sent once, as soon as the Mac has said what it
    /// holds; `changeSettings` refuses to guess before that.
    private func sendQuality() {
        guard !sentQuality, client.settings.host != nil else { return }
        sentQuality = true
        client.changeSettings(HostSettingsChange(maxFPS: 60, bitrate: QualityPreset.efficient.rawValue))
    }

    /// The upstream tour is a full-screen English walkthrough of a browse-and-pick flow Heeler never
    /// shows. Mark it passed and skipped at the version `TourStore` reads, so neither Release nor a
    /// later tour upgrade offers it.
    private static func skipFirstRunGuide() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: TourStore.versionKey) < TourPolicy.version else { return }
        defaults.set(TourTopic.allCases.map(\.rawValue), forKey: TourStore.seenKey)
        defaults.set(true, forKey: TourStore.skippedKey)
        defaults.set(TourPolicy.version, forKey: TourStore.versionKey)
    }
}

/// The dial's line over black, until the Mac's window list arrives or the dial ends.
private struct WaitingLayer: View {
    let text: String
    /// The dial is still going: sill keeps retrying after it ends, so a spinner over the end's
    /// words would say the wrong thing.
    let waiting: Bool

    var body: some View {
        VStack(spacing: 12) {
            if waiting {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}
