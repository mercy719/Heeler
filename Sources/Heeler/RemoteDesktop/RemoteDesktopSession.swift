import Foundation

/// The Host scripts' one-line JSON answers.
enum RemoteDesktopWire {
    /// Quoted: the directory's name contains a space.
    static let binDirectory =
        "\"$HOME/Library/Application Support/Heeler/remote-desktop/bin\""

    static let setupCommand = "bash \(binDirectory)/rc-setup.sh"
    static let sessionCommand = "bash \(binDirectory)/rc-session.sh start"

    /// `{"ready":true,"port":52100,"hostId":1,"appId":1,"width":1280,…}`
    /// or `{"ready":false,"error":"<code>","detail":"…"}`.
    static func ready(from line: Data) throws -> RemoteDesktopReady {
        struct Line: Decodable {
            let ready: Bool
            let port: UInt16?
            let hostId: Int?
            let appId: Int?
            let width: Int?
            let height: Int?
            let locked: Bool?
            let error: String?
            let detail: String?
        }
        let decoded: Line
        do {
            decoded = try JSONDecoder().decode(Line.self, from: line)
        } catch {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "The Host's session answer was not JSON."))
        }
        guard decoded.ready else {
            throw RemoteDesktopFailure(code: decoded.error ?? "", detail: decoded.detail)
        }
        guard let port = decoded.port, let hostID = decoded.hostId,
            let appID = decoded.appId, let width = decoded.width,
            let height = decoded.height, let locked = decoded.locked
        else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "The Host's session answer is missing a field."))
        }
        return RemoteDesktopReady(
            port: port, hostID: hostID, appID: appID,
            width: width, height: height, locked: locked)
    }

    /// `{"installed":true,"needsPermission":false,"paired":true}` or
    /// `{"installed":false,"error":"<code>","detail":"…"}`. Answers whether the
    /// Host now holds the install, and whether its permissions are still owed.
    static func setupStatus(from line: Data) throws -> (installed: Bool, needsPermission: Bool) {
        struct Line: Decodable {
            let installed: Bool
            let needsPermission: Bool?
            let error: String?
            let detail: String?
        }
        let decoded: Line
        do {
            decoded = try JSONDecoder().decode(Line.self, from: line)
        } catch {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "The Host's setup answer was not JSON."))
        }
        guard decoded.installed else {
            throw RemoteDesktopFailure(code: decoded.error ?? "", detail: decoded.detail)
        }
        return (decoded.installed, decoded.needsPermission ?? false)
    }

    /// The scripts answer in one line; anything after it is not ours.
    static func firstLine(of data: Data) -> Data {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return data }
        return data[data.startIndex..<newline]
    }
}

/// Runs one Remote Desktop link over its own SSH connection: writes the Host
/// scripts, starts the Host session, keeps it alive with heartbeats, and
/// forwards its page to a loopback listener. The Agent transport is never
/// involved, so nothing here can cost the Console its link.
actor RemoteDesktopSession {
    private let connector: any TransportConnector
    private let settings: SSHTransportSettings
    private let scripts: RemoteDesktopScripts
    private let heartbeatInterval: Duration
    private let onEnded: @Sendable (RemoteDesktopEnd) -> Void

    private var connection: (any RemoteDesktopConnection)?
    private var forwarder: LoopbackForwarder?
    private var sessionExec: (any RemoteDesktopByteStream)?
    private var heartbeatTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var ended = false

    init(
        connector: any TransportConnector,
        settings: SSHTransportSettings,
        scripts: RemoteDesktopScripts,
        heartbeatInterval: Duration = .seconds(15),
        onEnded: @escaping @Sendable (RemoteDesktopEnd) -> Void
    ) {
        self.connector = connector
        self.settings = settings
        self.scripts = scripts
        self.heartbeatInterval = heartbeatInterval
        self.onEnded = onEnded
    }

    func start() async throws -> RemoteDesktopReady {
        do {
            return try await run()
        } catch {
            await shutDown(reason: nil)
            throw error
        }
    }

    /// Idempotent, and reports at most once over the whole session.
    func stop() async {
        await shutDown(reason: .stopped)
    }

    private func run() async throws -> RemoteDesktopReady {
        let connection = try await connector.connectRemoteDesktop(settings: settings)
        self.connection = connection
        try await writeScripts(over: connection)
        try await installIfNeeded(over: connection)
        let (exec, ready) = try await startHostSession(over: connection)
        sessionExec = exec
        monitorTask = Task { [weak self] in
            await self?.watchLink(exec)
        }
        heartbeatTask = Task { [weak self] in
            await self?.heartbeat(exec)
        }
        let forwarder = LoopbackForwarder { [weak self] in
            guard let connection = await self?.connection else {
                throw RemoteDesktopFailure.connection(
                    String(localized: "The Host connection is closed."))
            }
            return try await connection.openTCP(port: ready.port)
        }
        let localPort = try await forwarder.start()
        self.forwarder = forwarder
        let started = RemoteDesktopReady(
            port: localPort, hostID: ready.hostID, appID: ready.appID,
            width: ready.width, height: ready.height, locked: ready.locked)
        return started
    }

    // MARK: Host scripts

    /// Written on every start, so the Host never runs a script this build was
    /// not tested against. The content goes over stdin, never the command line.
    private func writeScripts(over connection: any RemoteDesktopConnection) async throws {
        let directory = RemoteDesktopWire.binDirectory
        _ = try await connection.execute(
            "mkdir -p \(directory)", input: Data(), timeout: .seconds(30))
        for (name, contents) in [
            ("rc-setup.sh", scripts.setup), ("rc-session.sh", scripts.session),
        ] {
            let result = try await connection.execute(
                "cat > \(directory)/\(name)", input: contents, timeout: .seconds(30))
            guard result.status == 0 else {
                throw RemoteDesktopFailure.setupFailed(
                    detail: String(localized: "The Host refused \(name)."))
            }
        }
    }

    private func installIfNeeded(over connection: any RemoteDesktopConnection) async throws {
        let status = try await connection.execute(
            "\(RemoteDesktopWire.setupCommand) status", input: Data(), timeout: .seconds(60))
        if let installed = try? RemoteDesktopWire.setupStatus(
            from: RemoteDesktopWire.firstLine(of: status.stdout)), installed.installed
        {
            return
        }
        let installed = try await connection.execute(
            "\(RemoteDesktopWire.setupCommand) install", input: Data(), timeout: .seconds(300))
        let result = try RemoteDesktopWire.setupStatus(
            from: RemoteDesktopWire.firstLine(of: installed.stdout))
        if result.needsPermission { throw RemoteDesktopFailure.needsPermission }
    }

    // MARK: Host session

    private func startHostSession(
        over connection: any RemoteDesktopConnection
    ) async throws -> (any RemoteDesktopByteStream, RemoteDesktopReady) {
        let exec = try await connection.openExec(command: RemoteDesktopWire.sessionCommand)
        do {
            let line = try await Self.readFirstLine(from: exec, timeout: .seconds(40))
            return (exec, try RemoteDesktopWire.ready(from: line))
        } catch {
            await exec.close()
            throw error
        }
    }

    /// Reads until the first newline or EOF, inside one deadline.
    private static func readFirstLine(
        from exec: any RemoteDesktopByteStream, timeout: Duration
    ) async throws -> Data {
        try await AsyncDeadline.run(for: timeout) {
            var buffer = Data()
            while buffer.firstIndex(of: UInt8(ascii: "\n")) == nil {
                guard let chunk = try await exec.read(maximumBytes: 4096), !chunk.isEmpty
                else { break }
                buffer.append(chunk)
                guard buffer.count <= 64 * 1024 else {
                    throw RemoteDesktopFailure.setupFailed(
                        detail: String(localized: "The Host's answer was too long."))
                }
            }
            return RemoteDesktopWire.firstLine(of: buffer)
        }
    }

    /// The Host's `read -t 45` loop: a line every 15 seconds or it cleans up.
    private func heartbeat(_ exec: any RemoteDesktopByteStream) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled else { return }
                try await exec.write(Data([UInt8(ascii: "\n")]))
            } catch is CancellationError {
                return
            } catch {
                await shutDown(reason: .heartbeatFailed)
                return
            }
        }
    }

    /// EOF or a read failure means the Host session is gone, whatever it said.
    private func watchLink(_ exec: any RemoteDesktopByteStream) async {
        while !Task.isCancelled {
            do {
                if try await exec.read(maximumBytes: 4096) == nil { break }
            } catch is CancellationError {
                return
            } catch {
                break
            }
        }
        guard !Task.isCancelled else { return }
        await shutDown(reason: .linkLost)
    }

    // MARK: Teardown

    /// Everything closes in this order: the listener and its forwarded
    /// connections, the session exec, then the dedicated SSH connection.
    private func shutDown(reason: RemoteDesktopEnd?) async {
        let first = !ended
        ended = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        let forwarder = self.forwarder
        self.forwarder = nil
        let exec = sessionExec
        sessionExec = nil
        let connection = self.connection
        self.connection = nil
        await forwarder?.stop()
        await exec?.close()
        await connection?.close()
        if first, let reason { onEnded(reason) }
    }
}
