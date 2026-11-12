import Foundation
import Network
import Synchronization

/// A loopback-only TCP listener that turns each accepted connection into one
/// Remote Desktop stream. It copies bytes and nothing else: no HTTP, no
/// WebSocket, no framing. A connection that fails closes only itself.
final class LoopbackForwarder: Sendable {
    private final class Link: Sendable {
        let connection: NWConnection
        let stream: any RemoteDesktopByteStream
        private let closed = Mutex(false)

        init(connection: NWConnection, stream: any RemoteDesktopByteStream) {
            self.connection = connection
            self.stream = stream
        }

        /// Closes the socket and the Host stream once; later calls do nothing.
        func close() async {
            let first = closed.withLock { closed -> Bool in
                guard !closed else { return false }
                closed = true
                return true
            }
            guard first else { return }
            connection.cancel()
            await stream.close()
        }
    }

    private struct State: Sendable {
        var listener: NWListener?
        var links: [ObjectIdentifier: Link] = [:]
        var stopped = true
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "heeler.remote-desktop.loopback")
    /// Opened for each accepted connection: the Host end of the pipe.
    private let openStream: @Sendable () async throws -> any RemoteDesktopByteStream

    init(openStream: @escaping @Sendable () async throws -> any RemoteDesktopByteStream) {
        self.openStream = openStream
    }

    /// Binds 127.0.0.1 on a system-assigned port and returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        state.withLock { state in
            state.listener = listener
            state.stopped = false
        }
        // .ready reports the port, then .cancelled reports the stop: one resume.
        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                // Only an answer spends the one resume; .setup and .waiting pass.
                switch state {
                case .ready, .failed, .cancelled: break
                default: return
                }
                let first = resumed.withLock { resumed -> Bool in
                    guard !resumed else { return false }
                    resumed = true
                    return true
                }
                guard first else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, port != 0 {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(
                            throwing: RemoteDesktopFailure.setupFailed(
                                detail: String(localized: "The local listener has no port.")))
                    }
                case .failed(let error):
                    continuation.resume(
                        throwing: RemoteDesktopFailure.setupFailed(
                            detail: String(describing: error)))
                case .cancelled:
                    continuation.resume(
                        throwing: RemoteDesktopFailure.setupFailed(
                            detail: String(localized: "The local listener stopped.")))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Idempotent: the listener and every forwarded connection close.
    func stop() async {
        let (listener, links) = state.withLock { state -> (NWListener?, [Link]) in
            state.stopped = true
            let listener = state.listener
            let links = Array(state.links.values)
            state.listener = nil
            state.links.removeAll()
            return (listener, links)
        }
        listener?.cancel()
        for link in links { await link.close() }
    }

    /// Only a loopback peer is served: the Host's own page never comes from
    /// anywhere else.
    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint), !state.withLock({ $0.stopped })
        else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        Task { await serve(connection) }
    }

    /// Both directions run until either ends, then both sides close.
    private func serve(_ connection: NWConnection) async {
        let stream: any RemoteDesktopByteStream
        do {
            stream = try await openStream()
        } catch {
            connection.cancel()
            return
        }
        let link = Link(connection: connection, stream: stream)
        let identity = ObjectIdentifier(connection)
        let kept = state.withLock { state -> Bool in
            // `stop()` while the Host end was opening: nothing may leak.
            guard !state.stopped else { return false }
            state.links[identity] = link
            return true
        }
        guard kept else {
            await link.close()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.pumpToHost(link) }
            group.addTask { await self.pumpToClient(link) }
            await group.next()
            group.cancelAll()
            // Cancelling the socket fails the other direction's pending
            // receive or send, so its task returns instead of parking.
            await link.close()
        }
        state.withLock { $0.links[identity] = nil }
    }

    private func pumpToHost(_ link: Link) async {
        do {
            while true {
                let (data, isComplete) = try await Self.receive(link.connection)
                if let data, !data.isEmpty {
                    try await link.stream.write(data)
                }
                if isComplete { return }
            }
        } catch {}
    }

    private func pumpToClient(_ link: Link) async {
        do {
            while let data = try await link.stream.read(maximumBytes: 64 * 1024) {
                try await Self.send(data, over: link.connection)
            }
        } catch {}
    }

    private static func receive(_ connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
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

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host
        else { return false }
        return address == IPv4Address("127.0.0.1")
    }
}
