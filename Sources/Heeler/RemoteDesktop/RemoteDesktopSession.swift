import Foundation

/// The Host script's one-line JSON answers.
enum RemoteDesktopWire {
    /// The directory's name contains a space, so every path that reaches a
    /// shell is quoted whole.
    private static let hostRoot = "$HOME/Library/Application Support/Heeler/remote-desktop"
    private static func path(_ relative: String) -> String { "\"\(hostRoot)/\(relative)\"" }

    static let binDirectory = path("bin")
    static let sillHostApp = path("SillHost.app")
    static let sillHostZip = path("SillHost.zip")
    /// Where an upload is unpacked before it replaces anything.
    static let sillHostStaging = path(".sillhost-upload")
    static let sillHostStagingApp = path(".sillhost-upload/SillHost.app")
    static let sillHostStagingZip = path(".sillhost-upload/SillHost.zip")

    /// The App always drives the sill engine.
    static let sessionCommand = "bash \(binDirectory)/rc-session.sh start sill"

    /// `{"ready":true,"port":52100,"locked":false}` or
    /// `{"ready":false,"error":"<code>","detail":"…"}`.
    static func ready(from line: Data) throws -> RemoteDesktopReady {
        struct Line: Decodable {
            let ready: Bool
            let port: UInt16?
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
        guard let port = decoded.port, let locked = decoded.locked else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "The Host's session answer is missing a field."))
        }
        return RemoteDesktopReady(port: port, locked: locked)
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
        // `stop()` can run at any await below (the user closes while it connects);
        // what arrives after it is closed here instead of kept alive by heartbeats.
        guard !ended else {
            await connection.close()
            throw CancellationError()
        }
        self.connection = connection
        try await writeScripts(over: connection)
        try checkStopped()
        try await uploadSillHostIfNeeded(over: connection)
        try checkStopped()
        let (exec, ready) = try await startHostSession(over: connection)
        guard !ended else {
            await exec.close()
            throw CancellationError()
        }
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
        guard !ended else {
            await forwarder.stop()
            throw CancellationError()
        }
        self.forwarder = forwarder
        return RemoteDesktopReady(port: localPort, locked: ready.locked)
    }

    private func checkStopped() throws {
        if ended { throw CancellationError() }
    }

    // MARK: Host scripts

    /// Written on every start, so the Host never runs a script this build was
    /// not tested against. The content goes over stdin, never the command line.
    private func writeScripts(over connection: any RemoteDesktopConnection) async throws {
        let directory = RemoteDesktopWire.binDirectory
        _ = try await connection.execute(
            "mkdir -p \(directory)", input: Data(), timeout: .seconds(30))
        let result = try await connection.execute(
            "cat > \(directory)/rc-session.sh", input: scripts.session, timeout: .seconds(30))
        guard result.status == 0 else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "The Host refused rc-session.sh."))
        }
    }

    /// The Host's SillHost.app is the one this build ships, or it is replaced.
    /// The zip travels over stdin and is unpacked beside the old bundle, so a
    /// dropped link never leaves half an app where the next start looks.
    private func uploadSillHostIfNeeded(
        over connection: any RemoteDesktopConnection
    ) async throws {
        guard let package = scripts.sillHost else { return }
        let listing = try await connection.execute(
            "shasum -a 256 \(RemoteDesktopWire.sillHostZip) 2>/dev/null", input: Data(),
            timeout: .seconds(30))
        guard package.mustUpload(hostSHASum: String(decoding: listing.stdout, as: UTF8.self))
        else { return }
        let staging = RemoteDesktopWire.sillHostStaging
        for (command, input, timeout) in [
            ("rm -rf \(staging) && mkdir -p \(staging)", Data(), Duration.seconds(30)),
            ("cat > \(RemoteDesktopWire.sillHostStagingZip)", package.zip, .seconds(300)),
            (
                "ditto -x -k \(RemoteDesktopWire.sillHostStagingZip) \(staging)"
                    + " && rm -rf \(RemoteDesktopWire.sillHostApp)"
                    + " && mv \(RemoteDesktopWire.sillHostStagingApp) \(RemoteDesktopWire.sillHostApp)"
                    + " && mv \(RemoteDesktopWire.sillHostStagingZip) \(RemoteDesktopWire.sillHostZip)"
                    + " && rm -rf \(staging)",
                Data(), .seconds(120)
            ),
        ] {
            let result = try await connection.execute(command, input: input, timeout: timeout)
            guard result.status == 0 else {
                throw RemoteDesktopFailure.setupFailed(
                    detail: String(localized: "The Host refused the Remote Desktop package."))
            }
        }
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
