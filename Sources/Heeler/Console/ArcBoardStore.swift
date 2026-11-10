import Foundation
import Observation

/// The desktop arc board's cache on each Host: what every Agent is doing now,
/// and each project's board. Read-only, over Chat's Host file channel, and
/// silent where the Host never ran the board.
@MainActor
@Observable
final class ArcBoardStore {
    /// `now.json` is small and changes as Agents work: the lists ask again
    /// this often while they are on screen.
    nonisolated static let nowInterval: Duration = .seconds(20)

    private(set) var now: [Host.ID: [String: ArcAgentNow]] = [:]
    private(set) var boards: [Host.ID: [String: ArcProjectBoard]] = [:]

    /// Every Host's `now.json`, each read on its own.
    func refreshNow(
        hosts: [Host], files: @escaping @MainActor (Host.ID) -> ChatHostFiles
    ) async {
        now = await Self.read(hosts: hosts) { hostID in
            guard let data = await Self.read(file: "now.json", files: files(hostID)) else {
                return [:]
            }
            return ArcAgentNow.parse(data)
        }
    }

    /// Every Host's `arc-board.json`, each read on its own.
    func refreshBoards(
        hosts: [Host], files: @escaping @MainActor (Host.ID) -> ChatHostFiles
    ) async {
        boards = await Self.read(hosts: hosts) { hostID in
            guard let data = await Self.read(file: "arc-board.json", files: files(hostID))
            else { return [:] }
            return ArcProjectBoard.parse(data)
        }
    }

    private static func read<Value: Sendable>(
        hosts: [Host],
        _ read: @escaping @MainActor @Sendable (Host.ID) async -> [String: Value]
    ) async -> [Host.ID: [String: Value]] {
        var next: [Host.ID: [String: Value]] = [:]
        for host in hosts {
            let value = await read(host.id)
            if !value.isEmpty { next[host.id] = value }
        }
        return next
    }

    /// One board file's bytes; nil when the Host will not answer, the file is
    /// missing, or it is larger than a board could be.
    private static func read(file: String, files: ChatHostFiles) async -> Data? {
        do {
            let directory = RemoteFilePath.join(
                try await files.home(), ".cache", "herdr-agent-board")
            let path = RemoteFilePath.join(directory, file)
            guard let status = try await files.status(path),
                status.kind == nil || status.kind == .regular,
                let size = status.size, size > 0,
                size <= UInt64(ArcAgentNow.fileMaximumBytes)
            else { return nil }
            return try await files.read(path: path, from: 0, to: size, chunk: 256 << 10)
        } catch {
            return nil
        }
    }
}
