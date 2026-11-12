import Foundation
import HeelerSSH

/// One byte stream of a Remote Desktop link: an exec's stdin/stdout, or one
/// forwarded TCP connection. An idle stream reads nothing for long stretches,
/// so a read deadline is normal and the implementation swallows it; only nil
/// means the remote end is gone.
protocol RemoteDesktopByteStream: Sendable {
    func write(_ data: Data) async throws
    /// The next bytes, or nil after the remote end closed.
    func read(maximumBytes: Int) async throws -> Data?
    func close() async
}

/// The SSH surface Remote Desktop needs. The session runs against a scripted
/// stand-in in tests, and the app never shares the Agent transport's link.
protocol RemoteDesktopConnection: Sendable {
    func execute(
        _ command: String, input: Data, timeout: Duration
    ) async throws -> (status: Int32, stdout: Data)
    func openExec(command: String) async throws -> any RemoteDesktopByteStream
    func openTCP(port: UInt16) async throws -> any RemoteDesktopByteStream
    func close() async
}

/// The production link: the Host's own authenticated connection, opened by
/// `HeelerSSHTransport.connectAuthenticated` rather than taken from a running
/// Transport, so a stalled video stream cannot cost the Agent list its link.
struct SSHRemoteDesktopConnection: RemoteDesktopConnection {
    let connection: SSHConnection

    func execute(
        _ command: String, input: Data, timeout: Duration
    ) async throws -> (status: Int32, stdout: Data) {
        let result = try await connection.execute(command, input: input, timeout: timeout)
        return (result.exitStatus, result.stdout)
    }

    func openExec(command: String) async throws -> any RemoteDesktopByteStream {
        SSHRemoteDesktopStream(
            channel: try await connection.openExec(
                command: command, timeout: SSHRemoteDesktopStream.writeTimeout))
    }

    /// The scripts listen on the Host's own loopback only.
    func openTCP(port: UInt16) async throws -> any RemoteDesktopByteStream {
        SSHRemoteDesktopStream(
            channel: try await connection.openDirectTCPIPStream(
                host: "127.0.0.1", port: port, timeout: SSHRemoteDesktopStream.writeTimeout))
    }

    func close() async {
        try? await connection.close(timeout: .seconds(2))
    }
}

private struct SSHRemoteDesktopStream: RemoteDesktopByteStream {
    static let readTimeout: Duration = .seconds(1)
    static let writeTimeout: Duration = .seconds(15)

    let channel: any HeelerSSHAPIChannel

    func write(_ data: Data) async throws {
        try await channel.write(data, timeout: Self.writeTimeout)
    }

    func read(maximumBytes: Int) async throws -> Data? {
        while true {
            try Task.checkCancellation()
            do {
                return try await channel.read(
                    maximumBytes: maximumBytes, timeout: Self.readTimeout)
            } catch SSHError.timedOut, TransportError.timedOut {
                continue
            }
        }
    }

    func close() async {
        try? await channel.close(timeout: .seconds(2))
    }
}
