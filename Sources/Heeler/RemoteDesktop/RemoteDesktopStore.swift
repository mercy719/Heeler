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
    /// The port this session's page is served on; the view loads nothing else.
    private(set) var ready: RemoteDesktopReady?
    /// The one URL the page loads: this session's loopback page, or the
    /// debug launch's own. Nil until there is one.
    var pageURL: URL? { debugURL ?? ready?.localURL }
    private(set) var latencyMS: Int?
    private(set) var fps: Int?
    /// A decoded frame has arrived, which is what "connected" means: the
    /// page's own `stream-info` says nothing about a picture.
    private var sawFirstFrame = false

    var quality: RemoteDesktopQuality
    var touchMode: RemoteDesktopTouchMode

    private let settings: () throws -> SSHTransportSettings
    private let makeSession:
        (SSHTransportSettings, @escaping @Sendable (RemoteDesktopEnd) -> Void) throws ->
            any RemoteDesktopSessionRunning
    private var session: (any RemoteDesktopSessionRunning)?
    /// A start is on its way to a session: `session` is still nil then, and a
    /// second start must not begin a second one.
    private var isStarting = false
    private var runID = 0
    /// A URL the screen loads instead of starting a Host session: the
    /// Simulator's `-RemoteDesktopDebugURL`, which reaches a Mac through its
    /// own `ssh -L`. Debug builds only, so a release build has no such path.
    private var debugURL: URL?

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        overlays: OverlayNetworkRuntime = .shared,
        scripts: @escaping () throws -> RemoteDesktopScripts = { try RemoteDesktopScripts.bundled() },
        heartbeatInterval: Duration = .seconds(15),
        quality: RemoteDesktopQuality = .standard,
        touchMode: RemoteDesktopTouchMode = .trackpad
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
        self.quality = quality
        self.touchMode = touchMode
        self.debugURL = nil
    }

    /// A store over a session the caller builds: previews and tests.
    init(
        settings: @escaping () throws -> SSHTransportSettings,
        makeSession: @escaping (
            SSHTransportSettings, @escaping @Sendable (RemoteDesktopEnd) -> Void
        ) throws -> any RemoteDesktopSessionRunning,
        quality: RemoteDesktopQuality = .standard,
        touchMode: RemoteDesktopTouchMode = .trackpad
    ) {
        self.settings = settings
        self.makeSession = makeSession
        self.quality = quality
        self.touchMode = touchMode
        self.debugURL = nil
    }

    #if DEBUG
        /// The screen over a URL the app was launched with, skipping SSH: a
        /// Mac a Simulator run reached through its own `ssh -L`.
        static func debug(url: URL) -> RemoteDesktopStore {
            let store = RemoteDesktopStore(
                settings: { throw CancellationError() },
                makeSession: { _, _ in throw CancellationError() })
            store.debugURL = url
            return store
        }
    #endif

    /// Starts a link. Idempotent while one is starting or running: the one
    /// that is already under way owns `runID`.
    func start() {
        guard session == nil, !isStarting else { return }
        runID += 1
        let id = runID
        isStarting = true
        sawFirstFrame = false
        clearPage()
        state = .connecting(step: 1)
        Task { await connect(id: id) }
    }

    /// Idempotent: a second stop while the first is still closing does nothing.
    func stop() {
        runID += 1
        isStarting = false
        guard let session else { return }
        clearPage()
        Task { await session.stop() }
    }

    /// The menu's Reconnect, and a quality change: the page loads again at the
    /// new size, which is a fresh Host session. A debug launch has none, so its
    /// page just reloads in place.
    func reconnect() {
        stop()
        start()
    }

    /// The page's one sample a second: the transport's round trip and the
    /// frames the decoder produced since the last one.
    func received(stats: [String: Any]) {
        if let rtt = stats["rttMs"] as? Int { latencyMS = rtt }
        if let frames = stats["fps"] as? Int { fps = frames }
    }

    func receivedFirstFrame() {
        guard !sawFirstFrame, ready != nil else { return }
        sawFirstFrame = true
        state = .connected
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
        #if DEBUG
            // A debug launch has no Host session to start: the page is one the
            // caller already reached, so step 3 is where it begins.
            if debugURL != nil {
                ready = RemoteDesktopReady(
                    port: 0, hostID: 0, appID: 0, width: 1_920, height: 1_080, locked: false)
                state = .connecting(step: 3)
                isStarting = false
                return
            }
        #endif
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

    /// Nothing of the old link survives: no port to load, no figures to show.
    private func clearPage() {
        session = nil
        ready = nil
        latencyMS = nil
        fps = nil
    }
}

#if DEBUG
    /// `-RemoteDesktopDebugURL <url>`: a Simulator run opens Remote Desktop on
    /// that URL, skipping SSH. The URL is a Mac the caller reached through its
    /// own `ssh -L`, so nothing here dials a real Host.
    enum RemoteDesktopDebugURL {
        static var launchURL: URL? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-RemoteDesktopDebugURL"),
                case let next = arguments.index(after: index), next < arguments.endIndex,
                let url = URL(string: arguments[next])
            else { return nil }
            return url
        }
    }
#endif
