import Foundation
import Observation
import SwiftUI

/// What the Remote Desktop screen shows. One of these at a time: the screen
/// has no other state to fall out of step with.
enum RemoteDesktopState: Equatable, Sendable {
    /// A step number of three, and the one line that names it.
    case connecting(step: Int)
    case connected
    case failed(String)
    case paused
    case notInstalled
    case needsPermission

    /// The status dot's colour, in the app's own status palette.
    var statusColor: Color {
        switch self {
        case .connected: .green
        case .failed: .red
        case .needsPermission, .notInstalled, .connecting, .paused: .orange
        }
    }

    /// VoiceOver's name for the status dot.
    var statusLabel: String {
        switch self {
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Failed")
        case .paused: String(localized: "Paused")
        case .notInstalled: String(localized: "Not installed")
        case .needsPermission: String(localized: "Needs permission")
        case .connecting: String(localized: "Connecting")
        }
    }
    /// What a connecting step says under its number.
    static func line(forStep step: Int) -> String {
        switch step {
        case 1: String(localized: "Connecting to the Mac")
        case 2: String(localized: "Starting Remote Desktop")
        default: String(localized: "Waiting for the picture")
        }
    }

    /// A failure that names its own reason keeps the sentence the Host gave.
    init(failure: RemoteDesktopFailure) {
        switch failure {
        case .notInstalled: self = .notInstalled
        case .needsPermission: self = .needsPermission
        default:
            self = .failed(failure.errorDescription ?? String(localized: "Remote Desktop failed."))
        }
    }
}

/// One quality setting: how often the Host encodes, at what bitrate, and the
/// widest picture it fits that into.
enum RemoteDesktopQuality: String, CaseIterable, Sendable {
    case sharp
    case standard
    case saver

    /// Frames a second, kilobits a second, and the widest encode: Sunshine
    /// never upscales, so a narrower display keeps its own width.
    private var preset: (fps: Int, bitrate: Int, maxWidth: Int) {
        switch self {
        case .sharp: (60, 8_000, 1_920)
        case .standard: (30, 3_000, 1_280)
        case .saver: (15, 1_000, 960)
        }
    }

    var fps: Int { preset.fps }
    var bitrateKbps: Int { preset.bitrate }
    var maxWidth: Int { preset.maxWidth }

    /// Its row in the menu: the name, then what it asks of the link.
    var menuTitle: String {
        switch self {
        case .sharp: String(localized: "Sharp · 60 fps · 8 Mbps")
        case .standard: String(localized: "Standard · 30 fps · 3 Mbps")
        case .saver: String(localized: "Data Saver · 15 fps · 1 Mbps")
        }
    }

    /// The Host's display scaled into `maxWidth`, in even pixels: encoders
    /// refuse odd sizes.
    func streamSize(for ready: RemoteDesktopReady) -> (width: Int, height: Int) {
        let scale = min(1, Double(maxWidth) / Double(max(1, ready.width)))
        let even = { (value: Double) in max(2, Int((value / 2).rounded()) * 2) }
        return (even(Double(ready.width) * scale), even(Double(ready.height) * scale))
    }
}

/// The screen's own settings, kept in `@AppStorage`.
enum RemoteDesktopSettings {
    static let qualityKey = "remoteDesktop.quality"
    static let touchModeKey = "remoteDesktop.touchMode"
}

/// How a finger moves the Host's pointer. Moonlight's own names travel to the
/// page; these are the two the app offers.
enum RemoteDesktopTouchMode: String, CaseIterable, Sendable {
    /// The finger moves the pointer, as on a laptop.
    case trackpad
    /// The pointer goes to the finger.
    case direct

    /// Moonlight's `touchMode` value.
    var pageValue: String {
        switch self {
        case .trackpad: "localCursor"
        case .direct: "pointAndDrag"
        }
    }
}

/// What the store needs of a session, so tests run it without a Host. T3's
/// `RemoteDesktopSession` conforms as it is; nothing in T3 changes.
protocol RemoteDesktopSessionRunning: Sendable {
    func start() async throws -> RemoteDesktopReady
    func stop() async
}

extension RemoteDesktopSession: RemoteDesktopSessionRunning {}

/// One Remote Desktop link's state, and the only thing the screen observes.
/// The session is a dedicated SSH connection of its own (T3), so nothing here
/// can cost the Console its link.
@MainActor
@Observable
final class RemoteDesktopStore {
    private(set) var state: RemoteDesktopState = .connecting(step: 1)
    /// The port sill's stream is dialled on; the view reaches nothing else.
    private(set) var ready: RemoteDesktopReady?

    private let settings: () throws -> SSHTransportSettings
    private let makeSession:
        (SSHTransportSettings, @escaping @Sendable (RemoteDesktopEnd) -> Void) throws ->
            any RemoteDesktopSessionRunning
    private var session: (any RemoteDesktopSessionRunning)?
    /// A start is on its way to a session: `session` is still nil then, and a
    /// second start must not begin a second one.
    private var isStarting = false
    private var runID = 0

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared,
        scripts: @escaping () throws -> RemoteDesktopScripts = { try RemoteDesktopScripts.bundled() },
        heartbeatInterval: Duration = .seconds(15)
    ) {
        self.settings = {
            try ConsoleStore.consoleSettings(
                for: host, knownHosts: knownHosts, credentials: credentials, overlays: overlays)
        }
        self.makeSession = { settings, onEnded in
            // The scripts are read on every start, so a build that lost one
            // fails here rather than running an old copy on the Host.
            RemoteDesktopSession(
                connector: connector, settings: settings, scripts: try scripts(),
                heartbeatInterval: heartbeatInterval, onEnded: onEnded)
        }
    }

    /// A store over a session the caller builds: previews and tests.
    init(
        settings: @escaping () throws -> SSHTransportSettings,
        makeSession: @escaping (
            SSHTransportSettings, @escaping @Sendable (RemoteDesktopEnd) -> Void
        ) throws -> any RemoteDesktopSessionRunning
    ) {
        self.settings = settings
        self.makeSession = makeSession
    }

    /// Starts a link. Idempotent while one is starting or running: the one
    /// that is already under way owns `runID`.
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    func start() {
        guard session == nil, !isStarting else { return }
        runID += 1
        let id = runID
        isStarting = true
        clearPage()
        state = .connecting(step: 1)
        // A Host session still closing would tear down this one's processes.
        let previous = stopTask
        Task {
            await previous?.value
            await connect(id: id)
        }
    }

    /// Idempotent: a second stop while the first is still closing does nothing.
    func stop() {
        runID += 1
        isStarting = false
        guard let session else { return }
        clearPage()
        stopTask = Task { await session.stop() }
    }

    /// The status capsule's Retry: the screen's own link starts afresh.
    func reconnect() {
        stop()
        start()
    }

    /// The Mac's window list arrived: sill's own "connected", not the loopback
    /// forwarder being up (`SillStreamView`'s state).
    func sillListed() {
        guard ready != nil else { return }
        state = .connected
    }

    /// sill's stream ended: its line is the reason, and the screen's Retry
    /// starts a fresh session. sill's own Disconnect ends a connected stream
    /// the same way, because its panel is then the only way out and that would
    /// leave this screen with no exit.
    func sillFailed(_ reason: String) {
        guard ready != nil, state == .connected || state == .connecting(step: 3) else { return }
        fail(.failed(reason), id: runID)
    }

    /// The app left the foreground: the phone cannot hold the stream and
    /// nobody sees it, so the Host session stops now rather than on a timeout.
    func pause() {
        stop()
        state = .paused
    }

    /// Back in the foreground: only a paused link comes back by itself.
    func resume() {
        guard state == .paused else { return }
        start()
    }

    // MARK: Connecting

    private func connect(id: Int) async {
        state = .connecting(step: 2)
        do {
            let session = try makeSession(try settings()) { [weak self] end in
                Task { @MainActor in self?.ended(end, id: id) }
            }
            self.session = session
            let ready = try await session.start()
            guard id == runID else { return }
            self.ready = ready
            state = .connecting(step: 3)
        } catch is CancellationError {
            // The user stopped it, or left the app: already in its own state.
        } catch let failure as RemoteDesktopFailure {
            fail(.init(failure: failure), id: id)
        } catch {
            fail(.failed(error.localizedDescription), id: id)
        }
        finishedStarting(id: id)
    }

    private func ended(_ end: RemoteDesktopEnd, id: Int) {
        switch end {
        case .stopped: return
        case .linkLost:
            fail(.failed(String(localized: "The connection to the Mac was lost.")), id: id)
        case .heartbeatFailed:
            fail(.failed(String(localized: "The Mac stopped answering.")), id: id)
        }
    }

    private func fail(_ state: RemoteDesktopState, id: Int) {
        guard id == runID else { return }
        clearPage()
        self.state = state
    }

    /// The connect task is done, whatever it decided: the next start may run.
    private func finishedStarting(id: Int) {
        guard id == runID else { return }
        isStarting = false
    }

    /// Nothing of the old link survives: no port sill can dial.
    private func clearPage() {
        session = nil
        ready = nil
    }
}
