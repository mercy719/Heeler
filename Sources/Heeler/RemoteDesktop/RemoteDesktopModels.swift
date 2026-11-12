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
    case needsPermission
    case noGuiSession
    case sunshineFailed
    case webServerFailed
    case notPaired
    case setupFailed(detail: String)
    case connection(String)

    /// The scripts' `error` codes. An unknown code is a setup failure, not a
    /// silent success.
    init(code: String, detail: String?) {
        switch code {
        case "notInstalled": self = .notInstalled
        case "needsPermission": self = .needsPermission
        case "noGuiSession": self = .noGuiSession
        case "sunshineFailed": self = .sunshineFailed
        case "webServerFailed": self = .webServerFailed
        case "notPaired": self = .notPaired
        default: self = .setupFailed(detail: detail ?? code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .notInstalled: String(localized: "Remote Desktop is not installed on the Host.")
        case .needsPermission:
            String(localized: "Grant Screen Recording and Accessibility to Heeler Remote Desktop on the Host.")
        case .noGuiSession: String(localized: "No one is logged in on the Host's desktop.")
        case .sunshineFailed: String(localized: "The Host's screen streamer did not start.")
        case .webServerFailed: String(localized: "The Host's Remote Desktop page did not start.")
        case .notPaired: String(localized: "The Host's Remote Desktop is not paired yet.")
        case .setupFailed(let detail): String(localized: "Remote Desktop setup failed: \(detail).")
        case .connection(let detail): String(localized: "Remote Desktop could not connect: \(detail).")
        }
    }
}

/// What a started link points at. The port is this device's own listener, not
/// the Host's.
struct RemoteDesktopReady: Sendable, Equatable {
    let port: UInt16
    let hostID: Int
    let appID: Int
    let width: Int
    let height: Int
    let locked: Bool

    var localURL: URL {
        URL(
            string:
                "http://127.0.0.1:\(port)/stream.html?hostId=\(hostID)&appId=\(appID)"
        ) ?? URL(fileURLWithPath: "/")
    }
}

/// The two Host scripts, written on every start so the Host never runs a
/// version this build was not tested against.
struct RemoteDesktopScripts: Sendable, Equatable {
    let setup: Data
    let session: Data

    /// Read from the app bundle; T4 adds the resources to `project.yml`.
    static func bundled() throws -> RemoteDesktopScripts {
        try RemoteDesktopScripts(
            setup: readBundled("rc-setup", extension: "sh"),
            session: readBundled("rc-session", extension: "sh"))
    }

    private static func readBundled(_ name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw RemoteDesktopFailure.setupFailed(
                detail: String(localized: "\(name).\(ext) is missing from the app."))
        }
        return try Data(contentsOf: url)
    }
}
