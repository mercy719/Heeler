import SwiftUI

extension ConsoleWorkspaceSection.ID {
    /// The identity as one stored string, for the arc list's saved choice.
    var storedText: String { "\(hostID.uuidString)/\(workspaceID)" }

    init?(_ storedText: String) {
        let parts = storedText.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let hostID = UUID(uuidString: String(parts[0])) else { return nil }
        self.init(hostID: hostID, workspaceID: String(parts[1]))
    }
}
/// The arc list's project colors: a stable hash of the label picks one of
/// eight system colors, so a project keeps its color from launch to launch.
/// `hashValue` is seeded per process and would repaint every project on each
/// start.
enum ArcProjectColor {
    static let palette: [Color] = [
        .orange, .blue, .green, .pink, .purple, .teal, .indigo, .mint,
    ]

    /// FNV-1a over the label's UTF-8 bytes.
    static func index(for label: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(palette.count))
    }

    static func color(for label: String) -> Color { palette[index(for: label)] }

    /// The first letter a badge shows; a Workspace with no label yet gets a
    /// placeholder rather than an empty square.
    static func initial(for label: String) -> String {
        label.first.map { String($0).uppercased() } ?? "?"
    }
}

/// The dot a project's tile carries: who in it needs the user, worst first.
/// herdr has a blue "finished a scheduled run" state too, but nothing in the
/// app reports it yet.
enum ArcProjectLight {
    enum Light: Equatable, Sendable {
        case blocked
        case done
        case working

        var color: Color {
            switch self {
            case .blocked: .red
            case .done: .green
            case .working: .yellow
            }
        }

        /// The App's own word for the status, as VoiceOver reads it.
        var status: AgentStatus {
            switch self {
            case .blocked: .blocked
            case .done: .done
            case .working: .working
            }
        }
    }

    /// Blocked outranks Done, which outranks Working; none of them, no dot.
    static func light(for statuses: [AgentStatus]) -> Light? {
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.done) { return .done }
        if statuses.contains(.working) { return .working }
        return nil
    }
}

/// One Host's projects for the arc list: every Workspace it reports, in
/// snapshot order, with the Agents' statuses that paint the tiles' dots.
struct ArcProjectGroup: Identifiable, Equatable, Sendable {
    struct Project: Identifiable, Equatable, Sendable {
        let id: ConsoleWorkspaceSection.ID
        let label: String
        let agents: [ConsoleAgent]

        var statuses: [AgentStatus] { agents.map(\.agent.status) }
        var light: ArcProjectLight.Light? { ArcProjectLight.light(for: statuses) }
    }

    let id: Host.ID
    let hostName: String
    let projects: [Project]

    /// A Host with no Workspaces listed yet contributes no row. A Workspace
    /// only an Agent names (a saved Chat whose Host session is gone) still
    /// gets a tile, after the snapshot's own list.
    static func groups(
        hosts: [Host], agents: [ConsoleAgent],
        workspacesByHost: [Host.ID: [ConsoleWorkspace]]
    ) -> [Self] {
        hosts.compactMap { host in
            let hostAgents = agents.filter { $0.hostID == host.id }
            var listed = (workspacesByHost[host.id] ?? [])
                .sorted { ($0.order, $0.label) < ($1.order, $1.label) }
            for agent in hostAgents
            where !listed.contains(where: { $0.id == agent.agent.workspaceID }) {
                listed.append(
                    ConsoleWorkspace(
                        id: agent.agent.workspaceID,
                        label: agent.workspaceLabel
                            ?? (agent.agent.workspaceID.isEmpty
                                ? String(localized: "Unknown Workspace")
                                : agent.agent.workspaceID)))
            }
            let projects = listed.map { workspace in
                Project(
                    id: ConsoleWorkspaceSection.ID(
                        hostID: host.id, workspaceID: workspace.id),
                    label: workspace.label,
                    agents: hostAgents.filter { $0.agent.workspaceID == workspace.id })
            }
            guard !projects.isEmpty else { return nil }
            return Self(id: host.id, hostName: host.displayName, projects: projects)
        }
    }
}

/// One Host's project tiles: a row of squares whose columns follow the
/// width, the Host's name above them when several Hosts list.
struct ArcProjectTilesRow: View {
    let group: ArcProjectGroup
    let showsHostName: Bool
    let selected: ConsoleWorkspaceSection.ID?
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHostName {
                Text(verbatim: group.hostName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8
            ) {
                ForEach(group.projects) { @Sendable project in
                    MainActorContent {
                        ArcProjectTile(
                            label: project.label, statuses: project.statuses,
                            isSelected: project.id == selected,
                            action: { onSelect(project.id) })
                    }
                }            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// One project's tile: its badge, its name, and a dot for whoever needs the
/// user. Selected, it takes the project's color.
struct ArcProjectTile: View {
    let label: String
    let statuses: [AgentStatus]
    let isSelected: Bool
    let action: () -> Void

    private var color: Color { ArcProjectColor.color(for: label) }
    private var light: ArcProjectLight.Light? { ArcProjectLight.light(for: statuses) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ArcProjectBadge(label: label)
                Text(verbatim: label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(color.opacity(0.22))
                        }
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(color, lineWidth: 1.5)
                        }
                    }
            }
            .overlay(alignment: .topTrailing) {
                if let light {
                    Circle()
                        .fill(light.color)
                        .frame(width: 9, height: 9)
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        [label, light?.status.displayTitle].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A project's first-letter badge, shared by its tile and its card header.
struct ArcProjectBadge: View {
    let label: String
    var size: CGFloat = 28

    var body: some View {
        Text(verbatim: ArcProjectColor.initial(for: label))
            .font(.system(size: size / 2, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                ArcProjectColor.color(for: label),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The selected project's card header: its badge, its name in the project's
/// color, and the New Agent button.
struct ArcProjectHeader: View {
    let label: String
    let onNewAgent: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArcProjectBadge(label: label)
            Text(verbatim: label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ArcProjectColor.color(for: label))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onNewAgent) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(ArcProjectColor.color(for: label))
            .hoverEffect(.highlight)
            .accessibilityLabel("New Agent")
        }
        .textCase(nil)
    }
}

/// A project with no Agents yet: says so, and offers to start one.
struct ArcProjectEmptyRow: View {
    let onNewAgent: () -> Void

    var body: some View {
        HStack {
            Text("No Agents")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("New Agent", systemImage: "plus", action: onNewAgent)
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
                .buttonStyle(.borderless)
        }
    }
}

/// The closing section's header: how many conversations in the other
/// projects wait on the user, the count in red.
struct ArcWaitingHeader: View {
    let count: Int

    var body: some View {
        Text(title)
            .textCase(nil)
    }

    private var title: AttributedString {
        var title = AttributedString(String(localized: "\(count) waiting on you"))
        if let digits = title.range(of: "\(count)") {
            title[digits].foregroundColor = .red
        }
        return title
    }
}
