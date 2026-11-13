import Foundation
import Network
import Synchronization
import Testing

@testable import Heeler

/// Remote Desktop's App-side seam: the loopback forwarder, the Host scripts'
/// answers, and the session's order of operations. Everything runs against
/// in-memory stand-ins, so no test leaves this device.
@Suite("Remote desktop")
struct RemoteDesktopTests {

    // MARK: In-memory byte streams

    /// What a Host echo service does: bytes written come back.
    fileprivate final class EchoStream: RemoteDesktopByteStream, Sendable {
        private let incoming = Mutex(Data())
        private let written = Mutex(Data())
        private let closed = Mutex(false)

        var isClosed: Bool { closed.withLock { $0 } }
        var allWritten: Data { written.withLock { $0 } }

        func write(_ data: Data) async throws {
            written.withLock { $0.append(data) }
            incoming.withLock { $0.append(data) }
        }

        func read(maximumBytes: Int) async throws -> Data? {
            while true {
                let chunk = incoming.withLock { buffer -> Data in
                    let count = min(maximumBytes, buffer.count)
                    let chunk = Data(buffer.prefix(count))
                    buffer.removeFirst(count)
                    return chunk
                }
                if !chunk.isEmpty { return chunk }
                if closed.withLock({ $0 }) { return nil }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func close() async {
            closed.withLock { $0 = true }
        }
    }

    /// A Host side that has already closed.
    fileprivate final class EndedStream: RemoteDesktopByteStream, Sendable {
        private let closed = Mutex(false)
        var isClosed: Bool { closed.withLock { $0 } }

        func write(_ data: Data) async throws {}
        func read(maximumBytes: Int) async throws -> Data? { nil }
        func close() async { closed.withLock { $0 = true } }
    }

    // MARK: Loopback plumbing

    private func loopbackConnection(port: UInt16) throws -> NWConnection {
        let endpoint = NWEndpoint.Port(rawValue: port)
        return NWConnection(
            to: .hostPort(host: "127.0.0.1", port: try #require(endpoint)), using: .tcp)
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    private func receive(_ connection: NWConnection, minimum: Int) async throws -> Data {
        var received = Data()
        while received.count < minimum {
            let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                    data, _, complete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if complete {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
            guard let chunk, !chunk.isEmpty else { break }
            received.append(chunk)
        }
        return received
    }

    private func waitUntil(
        timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw RemoteDesktopFailure.setupFailed(detail: "timed out waiting")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isRefused(_ connection: NWConnection) async throws -> Bool {
        for _ in 0..<300 {
            switch connection.state {
            case .failed, .waiting: return true
            case .ready: return false
            default: try await Task.sleep(for: .milliseconds(10))
            }
        }
        return false
    }

    // MARK: Forwarder

    @Test func forwarderPipesBytesBothWays() async throws {
        let opened = Mutex(0)
        let forwarder = LoopbackForwarder {
            opened.withLock { $0 += 1 }
            return RemoteDesktopTests.EchoStream()
        }
        let port = try await forwarder.start()
        let connection = try loopbackConnection(port: port)
        connection.start(queue: .global())
        defer {
            connection.cancel()
            Task { await forwarder.stop() }
        }
        try await waitUntil { connection.state == .ready }

        let payload = Data((0..<64 * 1_024).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        try await send(payload, over: connection)
        #expect(try await receive(connection, minimum: payload.count) == payload)
        #expect(opened.withLock { $0 } == 1)
    }

    @Test func forwarderClosesBothSidesWhenEitherEnds() async throws {
        // The client hangs up: the Host stream closes.
        let clientEnded = EndedStream()
        let opened = Mutex(0)
        let clientForwarder = LoopbackForwarder {
            opened.withLock { $0 += 1 }
            return clientEnded
        }
        let firstPort = try await clientForwarder.start()
        let first = try loopbackConnection(port: firstPort)
        first.start(queue: .global())
        try await waitUntil { first.state == .ready && opened.withLock { $0 } == 1 }
        first.cancel()
        try await waitUntil { clientEnded.isClosed }
        await clientForwarder.stop()

        // The Host stream ends: the client's side closes.
        let hostForwarder = LoopbackForwarder { EndedStream() }
        let secondPort = try await hostForwarder.start()
        let second = try loopbackConnection(port: secondPort)
        second.start(queue: .global())
        defer { second.cancel() }
        try await waitUntil { second.state == .ready }
        let (data, isComplete) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data?, Bool), any Error>) in
            second.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
        #expect(data?.isEmpty ?? true)
        #expect(isComplete)
        await hostForwarder.stop()
    }

    @Test func forwarderStopClosesEverything() async throws {
        let streams = Mutex<[EchoStream]>([])
        let forwarder = LoopbackForwarder {
            let stream = EchoStream()
            streams.withLock { $0.append(stream) }
            return stream
        }
        let port = try await forwarder.start()
        let connections = try (0..<2).map { _ in try loopbackConnection(port: port) }
        for connection in connections { connection.start(queue: .global()) }
        defer { for connection in connections { connection.cancel() } }
        try await waitUntil { streams.withLock { $0.count } == 2 }
        for connection in connections {
            try await waitUntil { connection.state == .ready }
            try await send(Data("ping".utf8), over: connection)
        }
        try await waitUntil {
            streams.withLock { all in all.allSatisfy { !$0.allWritten.isEmpty } }
        }

        await forwarder.stop()
        #expect(streams.withLock { all in all.allSatisfy(\.isClosed) })

        let probe = try loopbackConnection(port: port)
        probe.start(queue: .global())
        defer { probe.cancel() }
        #expect(try await isRefused(probe))
    }

    // MARK: Script answers

    @Test func readyLineParses() throws {
        let line = Data(
            #"{"ready":true,"port":52100,"locked":true}"#
                .utf8)
        let ready = try RemoteDesktopWire.ready(from: RemoteDesktopWire.firstLine(of: line))
        #expect(ready == RemoteDesktopReady(port: 52100, locked: true))
    }

    @Test func failureLineMapsToCode() {
        let codes: [(String, RemoteDesktopFailure)] = [
            ("notInstalled", .notInstalled),
            ("noGuiSession", .noGuiSession),
            ("sillFailed", .sillFailed),
        ]
        for (code, expected) in codes {
            #expect(throws: expected) {
                try RemoteDesktopWire.ready(
                    from: Data(#"{"ready":false,"error":"\#(code)","detail":"why"}"#.utf8))
            }
        }
        // A code this build does not know is a setup failure, never a start.
        #expect(throws: RemoteDesktopFailure.setupFailed(detail: "why")) {
            try RemoteDesktopWire.ready(
                from: Data(#"{"ready":false,"error":"somethingNew","detail":"why"}"#.utf8))
        }
        #expect(throws: RemoteDesktopFailure.self) {
            try RemoteDesktopWire.ready(from: Data("not json".utf8))
        }
    }

    // MARK: Session

    private func makeSettings() -> SSHTransportSettings {
        SSHTransportSettings(
            routes: [SSHRoute(host: "127.0.0.1", port: 22)],
            username: "tester",
            credentials: .password("not-a-real-password"),
            hostKeyPolicy: HostKeyPolicy(
                knownHosts: InMemoryKnownHostsStore(), confirmFirstConnect: { _ in true }),
            hostKeyTrust: .endpoint,
            socket: .absolutePath("/tmp/unused.sock"))
    }

    private func makeSession(
        _ connection: ScriptedConnection,
        heartbeat: Duration = .seconds(15),
        sillHost: SillHostPackage? = nil,
        ended: @escaping @Sendable (RemoteDesktopEnd) -> Void = { _ in }
    ) -> RemoteDesktopSession {
        RemoteDesktopSession(
            connector: ScriptedConnector(connection: connection),
            settings: makeSettings(),
            scripts: RemoteDesktopScripts(
                session: Data("session".utf8), sillHost: sillHost),
            heartbeatInterval: heartbeat,
            onEnded: ended)
    }

    @Test func sessionStartWritesScriptsThenReady() async throws {
        let connection = ScriptedConnection()
        let session = makeSession(connection)
        let ready = try await session.start()

        let calls = connection.calls
        let mkdir = try #require(calls.first)
        #expect(mkdir.command.hasPrefix("mkdir -p "))
        #expect(mkdir.command.contains("Library/Application Support/Heeler/remote-desktop/bin"))
        #expect(calls.count >= 3)
        #expect(calls[1].command.hasPrefix("cat > ") && calls[1].command.hasSuffix("/rc-session.sh"))
        #expect(calls[1].input == Data("session".utf8))
        #expect(calls[2].command.hasSuffix("rc-session.sh start sill"))
        #expect(!connection.isClosed)

        // The port is this device's own listener, never the Host's.
        #expect(ready.port != ScriptedConnection.hostPort)
        #expect(!ready.locked)
        await session.stop()
    }

    // MARK: Host package

    private static let sillHost = SillHostPackage(
        zip: Data("PK-sill-host".utf8),
        sha256: "6734cb30b3304b6a527f9026e12a149376b1eee1909fe6f0df9191efc12faebc")

    @Test func matchingSHASkipsTheUpload() async throws {
        let connection = ScriptedConnection()
        connection.setHostSHASum("\(Self.sillHost.sha256)  SillHost.zip\n")
        let session = makeSession(connection, sillHost: Self.sillHost)
        _ = try await session.start()
        #expect(!connection.calls.contains { $0.input == Self.sillHost.zip })
        #expect(!connection.calls.contains { $0.command.contains("ditto -x -k") })
        await session.stop()
    }

    @Test func aDifferentOrMissingSHAUploadsThePackage() async throws {
        for sum in ["0000000000000000000000000000000000000000000000000000000000000000  SillHost.zip\n", ""]
        {
            let connection = ScriptedConnection()
            connection.setHostSHASum(sum)
            let session = makeSession(connection, sillHost: Self.sillHost)
            _ = try await session.start()
            // The zip goes over stdin to a staging file, never on the command line.
            let upload = try #require(connection.calls.first { $0.input == Self.sillHost.zip })
            #expect(upload.command.hasPrefix("cat > "))
            #expect(!upload.command.contains(Self.sillHost.sha256))
            let unpack = try #require(
                connection.calls.first { $0.command.contains("ditto -x -k") })
            #expect(unpack.command.contains(".sillhost-upload"))
            #expect(unpack.command.contains("mv "))
            // The start comes after the unpack, so the Host runs this build's.
            let startIndex = try #require(
                connection.calls.firstIndex { $0.command.hasSuffix("rc-session.sh start sill") })
            let unpackIndex = try #require(
                connection.calls.firstIndex { $0.command.contains("ditto -x -k") })
            #expect(unpackIndex < startIndex)
            await session.stop()
        }
    }

    @Test func theStartCommandNamesSill() {
        #expect(RemoteDesktopWire.sessionCommand.hasSuffix("rc-session.sh start sill"))
    }

    @Test func stopWhileStartingLeavesNothingRunning() async throws {
        let ends = Mutex<[RemoteDesktopEnd]>([])
        let connection = ScriptedConnection()
        connection.setHoldStatus(true)
        let session = makeSession(connection) { end in ends.withLock { $0.append(end) } }
        let starting = Task { try await session.start() }
        try await waitUntil { connection.calls.count >= 2 }
        await session.stop()
        connection.setHoldStatus(false)
        await #expect(throws: (any Error).self) { _ = try await starting.value }
        #expect(connection.isClosed)
        #expect(!connection.calls.contains { $0.command.hasSuffix("rc-session.sh start sill") })
        #expect(ends.withLock { $0 } == [.stopped])
    }

    @Test func sessionEndsWhenExecHitsEOF() async throws {
        let ends = Mutex<[RemoteDesktopEnd]>([])
        let connection = ScriptedConnection()
        let session = makeSession(connection) { end in
            ends.withLock { $0.append(end) }
        }
        let ready = try await session.start()
        #expect(ready.port != 0)

        connection.endSession()
        try await waitUntil { ends.withLock { $0.count } >= 1 }
        #expect(ends.withLock { $0 } == [.linkLost])
        #expect(connection.isClosed)
        #expect(connection.sessionIsClosed)

        // The listener is gone: nothing answers that port any more.
        let probe = try loopbackConnection(port: ready.port)
        probe.start(queue: .global())
        defer { probe.cancel() }
        #expect(try await isRefused(probe))

        // A late stop is harmless and reports nothing more.
        await session.stop()
        #expect(ends.withLock { $0 } == [.linkLost])
    }

    @Test func heartbeatWritesLines() async throws {
        let ends = Mutex<[RemoteDesktopEnd]>([])
        let connection = ScriptedConnection()
        let session = makeSession(connection, heartbeat: .milliseconds(20)) { end in
            ends.withLock { $0.append(end) }
        }
        _ = try await session.start()
        try await waitUntil { connection.heartbeatLines >= 3 }
        let lines = connection.heartbeatLines
        #expect(lines >= 3)

        await session.stop()
        #expect(ends.withLock { $0 } == [.stopped])
        try await Task.sleep(for: .milliseconds(100))
        #expect(connection.heartbeatLines == lines)
        #expect(connection.isClosed)
        #expect(connection.sessionIsClosed)
    }

}

/// Mutable flags the scripted Host and its session exec both observe, shared
/// by reference because `Mutex` is noncopyable.
private final class ScriptedFlags: Sendable {
    let heartbeat: Mutex<Data>
    let sessionEnded: Mutex<Bool>
    let sessionClosed: Mutex<Bool>

    init() {
        heartbeat = Mutex(Data())
        sessionEnded = Mutex(false)
        sessionClosed = Mutex(false)
    }
}

private struct Call: Sendable, Equatable {
    let command: String
    let input: Data
}

/// Scripted Host: answers by command, and the session exec's reads follow
/// what the test does to it.
private final class ScriptedConnection: RemoteDesktopConnection, Sendable {
    private struct State: Sendable {
        var calls: [Call] = []
        /// What `shasum -a 256 SillHost.zip` prints; empty means no file.
        var hostSHASum = ""
        var closed = false
        var holdStatus = false
    }

    static let readyLine = Data(
        #"{"ready":true,"port":52100,"locked":false}"#
            .utf8)
    static let hostPort: UInt16 = 52_100

    private let state = Mutex(State())
    let flags = ScriptedFlags()

    var calls: [Call] { state.withLock { $0.calls } }
    var isClosed: Bool { state.withLock { $0.closed } }
    var sessionIsClosed: Bool { flags.sessionClosed.withLock { $0 } }
    var heartbeatLines: Int {
        flags.heartbeat.withLock { $0.filter { $0 == UInt8(ascii: "\n") }.count }
    }

    func setHostSHASum(_ sum: String) { state.withLock { $0.hostSHASum = sum } }
    func setHoldStatus(_ hold: Bool) { state.withLock { $0.holdStatus = hold } }

    func execute(
        _ command: String, input: Data, timeout: Duration
    ) async throws -> (status: Int32, stdout: Data) {
        let sum = state.withLock { state -> String in
            state.calls.append(Call(command: command, input: input))
            return state.hostSHASum
        }
        if command.hasPrefix("shasum -a 256") { return (0, Data(sum.utf8)) }
        // The last script written, held while a test stops the session.
        if command.hasSuffix("/rc-session.sh") {
            while state.withLock({ $0.holdStatus }) { try await Task.sleep(for: .milliseconds(5)) }
        }
        return (0, Data())
    }

    func openExec(command: String) async throws -> any RemoteDesktopByteStream {
        state.withLock { $0.calls.append(Call(command: command, input: Data())) }
        return SessionStream(firstLine: Self.readyLine, flags: flags)
    }

    func openTCP(port: UInt16) async throws -> any RemoteDesktopByteStream {
        state.withLock { $0.calls.append(Call(command: "tcp \(port)", input: Data())) }
        return RemoteDesktopTests.EchoStream()
    }

    func close() async {
        state.withLock { $0.closed = true }
    }

    func endSession() { flags.sessionEnded.withLock { $0 = true } }
}

/// The Host's session exec: prints the ready line, counts writes, then
/// reports EOF when the test says the Host link is gone.
private final class SessionStream: RemoteDesktopByteStream, Sendable {
    private let firstLine: Data
    private let flags: ScriptedFlags
    private let sentFirstLine = Mutex(false)

    init(firstLine: Data, flags: ScriptedFlags) {
        self.firstLine = firstLine
        self.flags = flags
    }

    func write(_ data: Data) async throws {
        flags.heartbeat.withLock { $0.append(data) }
    }

    func read(maximumBytes: Int) async throws -> Data? {
        let sendLine = sentFirstLine.withLock { sent -> Bool in
            defer { sent = true }
            return !sent
        }
        if sendLine { return firstLine + Data([UInt8(ascii: "\n")]) }
        while true {
            if flags.sessionEnded.withLock({ $0 }) { return nil }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() async {
        flags.sessionClosed.withLock { $0 = true }
    }
}

/// Hands the scripted connection to a session as the connector's answer.
private struct ScriptedConnector: TransportConnector {
    let connection: ScriptedConnection

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        throw TransportError.hostFeatureUnavailable(feature: "Remote Desktop")
    }

    func connectRemoteDesktop(
        settings: SSHTransportSettings
    ) async throws -> any RemoteDesktopConnection {
        connection
    }
}
