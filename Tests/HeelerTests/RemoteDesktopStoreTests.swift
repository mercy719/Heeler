import Foundation
import Synchronization
import Testing

@testable import Heeler

/// Remote Desktop's screen state: what the six states mean, when the link
/// stops, and what a change of the keyboard field sends. The session is a
/// stand-in, so no test leaves this device.
@Suite("Remote desktop store")
@MainActor
struct RemoteDesktopStoreTests {

    // MARK: Stand-in session

    /// A session the test drives: it starts when told, and reports what the
    /// test tells it to.
    private final class StubSession: RemoteDesktopSessionRunning, Sendable {
        private let started = Mutex(0)
        private let stopped = Mutex(0)
        private let answer: Result<RemoteDesktopReady, any Error>
        private let hold: Bool

        init(answer: Result<RemoteDesktopReady, any Error>, hold: Bool = false) {
            self.answer = answer
            self.hold = hold
        }

        var startCount: Int { started.withLock { $0 } }
        var stopCount: Int { stopped.withLock { $0 } }

        func start() async throws -> RemoteDesktopReady {
            started.withLock { $0 += 1 }
            if hold {
                // Cancellation is how the store says "stop now"; a start that
                // ignores it would keep the test waiting.
                while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
                throw CancellationError()
            }
            return try answer.get()
        }

        func stop() async { stopped.withLock { $0 += 1 } }
    }

    private static let ready = RemoteDesktopReady(
        port: 52_180, hostID: 1, appID: 2, width: 1_920, height: 1_080, locked: false)

    /// The stub sessions a store started, in order.
    private final class Sessions: Sendable {
        private let list = Mutex<[StubSession]>([])
        var all: [StubSession] { list.withLock { $0 } }
        var count: Int { list.withLock { $0.count } }
        var first: StubSession? { list.withLock { $0.first } }
        func append(_ session: StubSession) { list.withLock { $0.append(session) } }
    }

    private func makeStore(
        answer: Result<RemoteDesktopReady, any Error> = .success(ready),
        hold: Bool = false
    ) -> (RemoteDesktopStore, Sessions) {
        let sessions = Sessions()
        let store = RemoteDesktopStore(
            settings: {
                SSHTransportSettings(
                    routes: [SSHRoute(host: "127.0.0.1", port: 22)], username: "tester",
                    credentials: .password("not-a-real-password"),
                    hostKeyPolicy: HostKeyPolicy(
                        knownHosts: InMemoryKnownHostsStore(), confirmFirstConnect: { _ in true }),
                    hostKeyTrust: .endpoint, socket: .absolutePath("/tmp/unused.sock"))
            },
            makeSession: { _, _ in
                let session = StubSession(answer: answer, hold: hold)
                sessions.append(session)
                return session
            })
        return (store, sessions)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(120)) }

    // MARK: States

    @Test func aStartedLinkConnectsOnlyOnTheFirstFrame() async throws {
        let (store, sessions) = makeStore()
        #expect(store.state == .connecting(step: 1))
        store.start()
        // Steps 2 and 3 come from the connecting task, never from `start`.
        try await waitUntil { store.state == .connecting(step: 3) }
        #expect(store.ready == Self.ready)
        // The page is loading; nothing has been decoded yet.
        #expect(store.state == .connecting(step: 3))

        store.receivedFirstFrame()
        #expect(store.state == .connected)
        #expect(sessions.first?.startCount == 1)
        store.stop()
    }

    @Test func aSecondStartWhileRunningDoesNothing() async throws {
        let (store, sessions) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.start()
        try await settle()
        #expect(sessions.count == 1)
        store.stop()
    }

    @Test func everyFailureMapsToItsState() async throws {
        let cases: [(RemoteDesktopFailure, RemoteDesktopState)] = [
            (.needsPermission, .needsPermission),
            (.notInstalled, .notInstalled),
            (.notPaired, .failed(RemoteDesktopFailure.notPaired.errorDescription ?? "")),
            (.sunshineFailed, .failed(RemoteDesktopFailure.sunshineFailed.errorDescription ?? "")),
        ]
        for (failure, expected) in cases {
            let (store, _) = makeStore(answer: .failure(failure))
            store.start()
            try await waitUntil {
                if case .connecting = store.state { return false }
                return true
            }
            #expect(store.state == expected, "\(failure) mapped to \(store.state)")
            #expect(store.ready == nil)
        }
    }

    @Test func aLostLinkIsAFailure() async throws {
        let reports = Mutex<(@Sendable (RemoteDesktopEnd) -> Void)?>(nil)
        let store = RemoteDesktopStore(
            settings: {
                SSHTransportSettings(
                    routes: [SSHRoute(host: "127.0.0.1", port: 22)], username: "tester",
                    credentials: .password("not-a-real-password"),
                    hostKeyPolicy: HostKeyPolicy(
                        knownHosts: InMemoryKnownHostsStore(), confirmFirstConnect: { _ in true }),
                    hostKeyTrust: .endpoint, socket: .absolutePath("/tmp/unused.sock"))
            },
            makeSession: { _, ended in
                reports.withLock { $0 = ended }
                return StubSession(answer: .success(Self.ready))
            })
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.receivedFirstFrame()
        #expect(store.state == .connected)

        // The Host session went away: the screen says so instead of showing a
        // frozen picture.
        reports.withLock { $0 }?(.linkLost)
        try await waitUntil { store.state != .connected }
        guard case .failed(let reason) = store.state else {
            Issue.record("expected a failure, got \(store.state)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(store.ready == nil)
    }

    // MARK: Lifecycle

    @Test func backgroundPausesAndStopsOnce() async throws {
        let (store, sessions) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.receivedFirstFrame()
        #expect(store.state == .connected)

        store.pause()
        #expect(store.state == .paused)
        try await settle()
        // The one link the screen started is the one that stopped.
        #expect(sessions.first?.stopCount == 1)

        // A second pause has no link left to stop, so nothing is stopped twice.
        store.pause()
        try await settle()
        #expect(sessions.count == 1)
        #expect(sessions.first?.stopCount == 1)

        store.resume()
        #expect(store.state == .connecting(step: 1))
        try await waitUntil { sessions.count == 2 }
    }

    @Test func resumeDoesNothingUnlessPaused() async throws {
        let (store, sessions) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.receivedFirstFrame()
        store.resume()
        try await settle()
        #expect(sessions.count == 1)
        store.stop()
    }

    @Test func stopTwiceInARowOnlyStopsOneSession() async throws {
        let (store, sessions) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.stop()
        store.stop()
        try await settle()
        #expect(sessions.first?.stopCount == 1)
    }

    @Test func aStoppedLinkLeavesNoPage() async throws {
        let (store, _) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        #expect(store.ready != nil)
        store.stop()
        #expect(store.ready == nil)
    }

    // MARK: Stats

    @Test func aSampleSetsLatencyAndFrames() async throws {
        let (store, _) = makeStore()
        store.start()
        try await waitUntil { store.state == .connecting(step: 3) }
        store.received(stats: ["rttMs": 42, "fps": 30, "frames": 900])
        #expect(store.latencyMS == 42)
        #expect(store.fps == 30)
        // A sample without a round trip leaves the last one in place.
        store.received(stats: ["rttMs": NSNull(), "fps": 29])
        #expect(store.latencyMS == 42)
        #expect(store.fps == 29)
        store.stop()
    }

    // MARK: Sizes

    @Test func streamSizesFollowTheDisplayAndStayEven() {
        let ready = RemoteDesktopReady(
            port: 1, hostID: 1, appID: 1, width: 3_024, height: 1_964, locked: false)
        let sharp = RemoteDesktopQuality.sharp.streamSize(for: ready)
        #expect(sharp.width == 1_920)
        #expect(sharp.width % 2 == 0 && sharp.height % 2 == 0)
        #expect(sharp.width <= RemoteDesktopQuality.sharp.maxWidth)

        let saver = RemoteDesktopQuality.saver.streamSize(for: ready)
        #expect(saver.width == 960)
        #expect(saver.width % 2 == 0 && saver.height % 2 == 0)

        // A display narrower than the cap is never upscaled, and a tiny one
        // still asks for an encodable size.
        let small = RemoteDesktopReady(
            port: 1, hostID: 1, appID: 1, width: 800, height: 600, locked: false)
        #expect(RemoteDesktopQuality.sharp.streamSize(for: small) == (800, 600))
        let tiny = RemoteDesktopReady(
            port: 1, hostID: 1, appID: 1, width: 1, height: 1, locked: false)
        #expect(RemoteDesktopQuality.sharp.streamSize(for: tiny) == (2, 2))
    }

    // MARK: Keyboard

    @Test func typedChangeNamesBackspacesAndNewText() {
        // A word replaced by another: the field's change is not one character.
        #expect(RemoteDesktopTyped.change(before: "helo", after: "hello") == (1, "lo"))
        #expect(RemoteDesktopTyped.change(before: "hello", after: "help") == (2, "p"))
        #expect(RemoteDesktopTyped.change(before: "abc", after: "") == (3, ""))
        #expect(RemoteDesktopTyped.change(before: "", after: "a") == (0, "a"))
        // The phone's keyboard can replace every character at once.
        #expect(RemoteDesktopTyped.change(before: "cat", after: "dog") == (3, "dog"))
        // A Mac gets only what a US keyboard types: an emoji or a Chinese
        // character is neither sent nor answered with a Backspace when deleted.
        #expect(RemoteDesktopTyped.change(before: "", after: "🙂") == (0, ""))
        #expect(RemoteDesktopTyped.change(before: "a🙂", after: "a") == (0, ""))
        #expect(RemoteDesktopTyped.change(before: "a🙂", after: "a🙂b") == (0, "b"))
        #expect(RemoteDesktopTyped.change(before: "a你好", after: "a") == (0, ""))
        #expect(RemoteDesktopTyped.change(before: "ls", after: "ls\n") == (0, "\n"))
    }
}
