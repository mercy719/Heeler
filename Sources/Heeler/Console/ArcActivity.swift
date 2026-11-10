import Foundation

/// What one Agent is doing now, from herdr-agent-board's `now.json`:
/// `{"agents": {"t5": {"now": "…", "now_ms": 179…}}}`.
struct ArcAgentNow: Equatable, Sendable {
    let text: String
    let at: Date?

    static let fileMaximumBytes = 1_024 * 1_024

    /// The file's Agents by herdr-core terminal address. Anything unexpected
    /// reads as no file: a Host without the board is not an error.
    static func parse(_ data: Data) -> [String: ArcAgentNow] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let agents = object["agents"] as? [String: Any]
        else { return [:] }
        var out: [String: ArcAgentNow] = [:]
        for (address, value) in agents {
            guard let entry = value as? [String: Any],
                let text = (entry["now"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            out[address] = ArcAgentNow(text: text, at: milliseconds(entry["now_ms"]))
        }
        return out
    }

    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? Double, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }
}

/// One project's board from `arc-board.json`, the desktop arc mod's
/// per-space reading.
struct ArcProjectBoard: Equatable, Sendable {
    struct Ask: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable {
            case decision
            case assist
        }

        /// By position in the array, which is all the file gives.
        let id: Int
        let kind: Kind
        let title: String
        let detail: String?
        let since: Date?
    }

    struct Next: Equatable, Sendable {
        let text: String
        let eta: String?
    }

    struct Gate: Equatable, Sendable, Identifiable {
        /// By position in the array.
        let id: Int
        let ok: Bool?
        let title: String
        let why: String?
    }

    let asks: [Ask]
    let next: Next?
    let gates: [Gate]
    /// When the board was written; the file keeps it only for the space the
    /// desktop app last had open.
    let at: Date?

    var isEmpty: Bool { asks.isEmpty && next == nil && gates.isEmpty }

    /// The spaces the file lists, by herdr space id (`sp…`).
    static func parse(_ data: Data) -> [String: ArcProjectBoard] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let spaces = object["spaces"] as? [String: Any]
        else { return [:] }
        var out: [String: ArcProjectBoard] = [:]
        for (spaceID, value) in spaces {
            guard let entry = value as? [String: Any] else { continue }
            let ai = entry["ai"] as? [String: Any] ?? [:]
            out[spaceID] = ArcProjectBoard(
                asks: asks(ai["asks"]), next: next(ai["next"]), gates: gates(ai["gates"]),
                at: ArcAgentNow.milliseconds(entry["at"]))
        }
        return out
    }

    private static func asks(_ value: Any?) -> [Ask] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.enumerated().compactMap { index, row in
            guard let title = nonEmpty(row["title"]) else { return nil }
            let kind: Ask.Kind = (row["kind"] as? String) == "decision" ? .decision : .assist
            return Ask(
                id: index, kind: kind, title: title, detail: nonEmpty(row["detail"]),
                since: ArcAgentNow.milliseconds(row["since"]))
        }
    }

    private static func next(_ value: Any?) -> Next? {
        guard let row = value as? [String: Any], let text = nonEmpty(row["text"]) else { return nil }
        return Next(text: text, eta: nonEmpty(row["eta"]))
    }

    private static func gates(_ value: Any?) -> [Gate] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.enumerated().compactMap { index, row in
            guard let title = nonEmpty(row["title"]) else { return nil }
            return Gate(
                id: index, ok: row["ok"] as? Bool, title: title, why: nonEmpty(row["why"]))
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }
}

/// Where a project's board lands: the desktop app keys boards by herdr space
/// id, and a Projects row's Workspace id carries the same id behind
/// `HerdrCoreOrganization.spaceWorkspaceID`'s prefix.
enum ArcBoardLookup {
    static let spacePrefix = "space-"

    static func spaceID(forWorkspace workspaceID: String) -> String {
        workspaceID.hasPrefix(spacePrefix)
            ? String(workspaceID.dropFirst(spacePrefix.count)) : workspaceID
    }

    /// The board a row shows, from its Host's boards.
    static func board(
        for id: ConsoleWorkspaceSection.ID, in boards: [Host.ID: [String: ArcProjectBoard]]
    ) -> ArcProjectBoard? {
        boards[id.hostID]?[spaceID(forWorkspace: id.workspaceID)]
    }
}

/// The now a conversation shows, from its Host's file: by its herdr-core
/// terminal address, which is `ConsoleAgent.agent.paneID`.
enum ArcAgentNowLookup {
    static func now(for agent: ConsoleAgent, in now: [Host.ID: [String: ArcAgentNow]]) -> ArcAgentNow? {
        now[agent.hostID]?[agent.agent.paneID]
    }
}
