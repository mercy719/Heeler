import Foundation
import Synchronization
import Testing

@testable import Heeler

/// Remote Desktop's screen state: what the five states mean and when the link
/// stops. The session is a stand-in, so no test leaves this device.
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

    private static let ready = RemoteDesktopReady(port: 52_180, locked: false)

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

        store.sillListed()
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
            (.notInstalled, .notInstalled),
            (.noGuiSession, .failed(RemoteDesktopFailure.noGuiSession.errorDescription ?? "")),
            (.sillFailed, .failed(RemoteDesktopFailure.sillFailed.errorDescription ?? "")),
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
        store.sillListed()
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
        store.sillListed()
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
        store.sillListed()
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
}
