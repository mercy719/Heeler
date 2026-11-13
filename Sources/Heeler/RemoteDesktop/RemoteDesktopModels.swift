import Foundation

/// What one Remote Desktop link can end with.
enum RemoteDesktopEnd: Error, Sendable, Equatable {
    /// The user stopped it, or the app went away.
    case stopped
    /// The Host's session exec reached EOF or failed: the Host cleaned up.
    case linkLost
    /// A heartbeat write failed; the Host will time out within 45 seconds.
    case heartbeatFailed
}

/// Why a Remote Desktop link could not start.
enum RemoteDesktopFailure: Error, Sendable, Equatable, LocalizedError {
    case notInstalled
    case noGuiSession
    case sillFailed
    case setupFailed(detail: String)
    case connection(String)

    /// The script's `error` codes. An unknown code is a setup failure, not a
    /// silent success.
    init(code: String, detail: String?) {
        switch code {
        case "notInstalled": self = .notInstalled
        case "noGuiSession": self = .noGuiSession
        case "sillFailed": self = .sillFailed
        default: self = .setupFailed(detail: detail ?? code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Remote Desktop is not installed on the Host.")
        case .noGuiSession: String(localized: "No one is logged in on the Host's desktop.")
        case .sillFailed: String(localized: "The Host's screen streamer did not start.")
        case .setupFailed(let detail): String(localized: "Remote Desktop setup failed: \(detail).")
        case .connection(let detail): String(localized: "Remote Desktop could not connect: \(detail).")
        }
    }
}

/// What a started link points at. The port is this device's own listener, not
/// the Host's.
struct RemoteDesktopReady: Sendable, Equatable {
    let port: UInt16
    let locked: Bool
}

/// The Mac-side sill host this build ships: `remote-desktop/build-sill-host.sh`
/// builds and signs it, and the session writes it to the Host.
struct SillHostPackage: Sendable, Equatable {
    let zip: Data
    /// Hex SHA-256 of `zip`, as `shasum -a 256` prints it.
    let sha256: String

    static func bundled() throws -> SillHostPackage {
        let listed = String(
            decoding: try RemoteDesktopScripts.bundledFile("SillHost.zip", "sha256"),
            as: UTF8.self)
        guard let sha = listed.split(whereSeparator: \.isWhitespace).first else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "SillHost.zip.sha256 is empty in the app."))
        }
        return SillHostPackage(
            zip: try RemoteDesktopScripts.bundledFile("SillHost", "zip"), sha256: String(sha))
    }

    /// Whether the Host's copy has to be replaced: its `shasum` answer names a
    /// different archive, or there is no answer because there is no file.
    func mustUpload(hostSHASum: String) -> Bool {
        guard let first = hostSHASum.split(whereSeparator: \.isWhitespace).first else { return true }
        return first.lowercased() != sha256.lowercased()
    }
}

/// The Host script, written on every start so the Host never runs a version
/// this build was not tested against, and the sill host it starts.
struct RemoteDesktopScripts: Sendable, Equatable {
    let session: Data
    /// Nil where a test starts no sill host.
    let sillHost: SillHostPackage?

    init(session: Data, sillHost: SillHostPackage? = nil) {
        self.session = session
        self.sillHost = sillHost
    }

    /// Read from the app bundle; T4 adds the resources to `project.yml`.
    static func bundled() throws -> RemoteDesktopScripts {
        try RemoteDesktopScripts(
            session: bundledFile("rc-session", "sh"),
            sillHost: try SillHostPackage.bundled())
    }

    static func bundledFile(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "\(name).\(ext) is missing from the app."))
        }
        return try Data(contentsOf: url)
    }
}
