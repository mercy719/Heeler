import Darwin
import Foundation
import Testing

@testable import HeelerSSH

/// Direct-tcpip streams an app holds beside ordinary session channels. These
/// run in `SessionDriverE2ETests`, so they inherit its fixture gate, its
/// serialization and its time limit, and each one talks to a real loopback echo
/// service on the Host through a real SSH session.
extension SessionDriverE2ETests {
    @Test("three direct TCP/IP streams carry 64 KiB each beside exec")
    func threeStreamsCarryBytesBesideExec() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let echo = try await DirectTCPIPEcho.launch(
            directory: "/tmp/heeler-direct-echo-\(UUID().uuidString)",
            using: connection)
        do {
            var streams: [SSHStreamLocalChannel] = []
            for _ in 0..<3 {
                streams.append(
                    try await connection.openDirectTCPIPStream(
                        host: "127.0.0.1",
                        port: echo.port,
                        timeout: .seconds(20)))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for (lane, stream) in streams.enumerated() {
                    group.addTask { try await echoRoundTrip(stream, lane: lane) }
                }
                group.addTask {
                    let result = try await connection.execute(
                        "printf direct-tcpip-exec",
                        timeout: .seconds(20))
                    #expect(result.stdout == Data("direct-tcpip-exec".utf8))
                }
                try await group.waitForAll()
            }

            for stream in streams {
                try await stream.close(timeout: .seconds(5))
            }
            #expect(await connection.isConnected)
        } catch {
            try? await echo.stop(using: connection)
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
        try await echo.stop(using: connection)
        try await connection.close(timeout: .seconds(2))
    }

    @Test("closing one direct TCP/IP stream spares the others and exec")
    func closingOneDirectStreamSparesTheOthers() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let echo = try await DirectTCPIPEcho.launch(
            directory: "/tmp/heeler-direct-echo-\(UUID().uuidString)",
            using: connection)
        do {
            let first = try await connection.openDirectTCPIPStream(
                host: "127.0.0.1", port: echo.port, timeout: .seconds(20))
            let second = try await connection.openDirectTCPIPStream(
                host: "127.0.0.1", port: echo.port, timeout: .seconds(20))
            let third = try await connection.openDirectTCPIPStream(
                host: "127.0.0.1", port: echo.port, timeout: .seconds(20))

            try await first.close(timeout: .seconds(5))
            // The closed handle left the driver's table and refuses I/O without
            // touching the session.
            await #expect(throws: SSHError.channelFailed) {
                try await first.write(Data("closed".utf8), timeout: .seconds(2))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await echoRoundTrip(second, lane: 1) }
                group.addTask { try await echoRoundTrip(third, lane: 2) }
                group.addTask {
                    let result = try await connection.execute(
                        "printf still-alive",
                        timeout: .seconds(20))
                    #expect(result.stdout == Data("still-alive".utf8))
                }
                try await group.waitForAll()
            }

            #expect(await connection.isConnected)
            try await second.close(timeout: .seconds(5))
            try await third.close(timeout: .seconds(5))
        } catch {
            try? await echo.stop(using: connection)
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
        try await echo.stop(using: connection)
        try await connection.close(timeout: .seconds(2))
    }

    @Test("a direct TCP/IP target with no listener reports unreachable and spares the session")
    func unreachableDirectTCPIPTargetSparesTheSession() async throws {
        let environment = try #require(SessionDriverTestEnvironment.current)
        let connection = try await environment.connect()
        let echo = try await DirectTCPIPEcho.launch(
            directory: "/tmp/heeler-direct-echo-\(UUID().uuidString)",
            using: connection)
        do {
            // Port 1 needs root to bind, so nothing on the fixture answers it.
            await #expect(throws: SSHError.targetUnreachable) {
                _ = try await connection.openDirectTCPIPStream(
                    host: "127.0.0.1", port: 1, timeout: .seconds(20))
            }
            #expect(await connection.isConnected)

            let result = try await connection.execute(
                "printf after-refusal",
                timeout: .seconds(20))
            #expect(result.stdout == Data("after-refusal".utf8))

            let stream = try await connection.openDirectTCPIPStream(
                host: "127.0.0.1", port: echo.port, timeout: .seconds(20))
            // An idle read timing out is ordinary on a stream that is waiting
            // for the far end, and must not cost the session.
            await #expect(throws: SSHError.timedOut) {
                _ = try await stream.read(timeout: .milliseconds(100))
            }
            #expect(await connection.isConnected)
            try await echoRoundTrip(stream, lane: 3)
            try await stream.close(timeout: .seconds(5))
        } catch {
            try? await echo.stop(using: connection)
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
        try await echo.stop(using: connection)
        try await connection.close(timeout: .seconds(2))
    }

    /// Writes a lane-specific 64 KiB pattern and requires it back unchanged, so
    /// a stream carrying another lane's bytes cannot pass.
    private func echoRoundTrip(_ stream: SSHStreamLocalChannel, lane: Int) async throws {
        let payload = Data((0..<65_536).map { UInt8(($0 + lane * 7) % 251) })
        try await stream.write(payload, timeout: .seconds(30))
        var received = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while received.count < payload.count {
            guard ContinuousClock.now < deadline else { throw DirectTCPIPEchoError.timedOut }
            guard
                let chunk = try await stream.read(
                    maximumBytes: 16 * 1_024,
                    timeout: .seconds(15))
            else { throw DirectTCPIPEchoError.closedEarly }
            received.append(chunk)
        }
        #expect(received == payload, "lane \(lane) received altered bytes")
    }
}

private enum DirectTCPIPEchoError: Error {
    case invalidLaunchResponse(String)
    case timedOut
    case closedEarly
}

/// A loopback echo service on the Host, launched through the fixture's real
/// SSH session. The caller picks a unique `/tmp/heeler-direct-echo-<UUID>` path
/// before launch so a failed start can still be cleaned without a parsed PID.
private struct DirectTCPIPEcho {
    let directory: String
    let processID: Int32
    let port: UInt16

    static func launch(
        directory: String,
        using observer: SSHConnection
    ) async throws -> DirectTCPIPEcho {
        let command = """
            set -eu
            directory=\(Self.shellQuote(directory))
            mkdir "$directory"
            /bin/cat >"$directory/echo.py"
            /usr/bin/python3 "$directory/echo.py" "$directory" </dev/null \
                >"$directory/stdout" 2>"$directory/stderr" &
            echo_pid=$!
            attempts=0
            while [ ! -s "$directory/port" ] && kill -0 "$echo_pid" 2>/dev/null; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 500 ] || break
                sleep 0.01
            done
            if [ ! -s "$directory/port" ]; then
                cat "$directory/stderr" >&2
                exit 1
            fi
            printf '%s\n%s\n' "$directory" "$echo_pid"
            cat "$directory/port"
            """
        let result = try await observer.execute(
            command,
            input: Data(pythonSource.utf8),
            timeout: .seconds(30))
        let response = String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard
            result.exitStatus == 0,
            response.count == 3,
            response[0] == directory,
            let processID = Int32(response[1]),
            let port = UInt16(response[2])
        else {
            throw DirectTCPIPEchoError.invalidLaunchResponse(
                String(decoding: result.stderr, as: UTF8.self))
        }
        return DirectTCPIPEcho(directory: directory, processID: processID, port: port)
    }

    /// Stops only the process this fixture started and removes its directory.
    /// The path check keeps a mismatched handle from deleting anything else.
    func stop(using observer: SSHConnection) async throws {
        let command = """
            directory=\(Self.shellQuote(directory))
            case "$directory" in
              /tmp/heeler-direct-echo-*) ;;
              *) printf 'refusing unexpected cleanup path: %s\\n' "$directory" >&2; exit 1 ;;
            esac
            kill -TERM \(processID) 2>/dev/null || true
            attempts=0
            while kill -0 \(processID) 2>/dev/null; do
                attempts=$((attempts + 1))
                [ "$attempts" -lt 200 ] || break
                sleep 0.01
            done
            kill -KILL \(processID) 2>/dev/null || true
            rm -rf "$directory"
            """
        _ = try await observer.execute(command, timeout: .seconds(10))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let pythonSource = #"""
import os
import socket
import sys
import threading

directory = sys.argv[1]


def publish(name, value):
    temporary = os.path.join(directory, name + ".tmp")
    with open(temporary, "w", encoding="ascii") as marker:
        marker.write(str(value))
        marker.flush()
        os.fsync(marker.fileno())
    os.replace(temporary, os.path.join(directory, name))


def serve(connection):
    with connection:
        while True:
            data = connection.recv(65_536)
            if not data:
                return
            connection.sendall(data)


listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
publish("port", listener.getsockname()[1])
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
"""#
}
