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

/// The conversations the Waiting page lists, across every Host: Blocked
/// ones ask the user for an answer, Done ones have results to read.
enum ArcWaitingList {
    /// One row: the Agent and the project its badge and subtitle name.
    struct Entry: Identifiable, Equatable, Sendable {
        let agent: ConsoleAgent
        let projectLabel: String

        var id: ConsoleAgent.ID { agent.id }
    }

    /// Every Agent of `groups` with `status`, in Host, then herdr order.
    static func entries(_ groups: [ArcProjectGroup], status: AgentStatus) -> [Entry] {
        groups.flatMap(\.projects).flatMap { project in
            project.agents.filter { $0.agent.status == status }
                .map { Entry(agent: $0, projectLabel: project.label) }
        }
    }
}

/// One project's row on the Progress page: the counts its pills show, and
/// the Agent under its title, which says what the project is doing now.
struct ArcProgressRow: Identifiable, Equatable, Sendable {
    let project: ArcProjectGroup.Project
    /// Blocked, working and done Agents of the project, in that order.
    let blocked: Int
    let working: Int
    let done: Int
    /// The first Blocked Agent's title, else the first Working one's; nil
    /// when the project has neither.
    let subtitle: String?

    var id: ConsoleWorkspaceSection.ID { project.id }
    /// Whether the row has anything to say after its name.
    var isEmpty: Bool { subtitle == nil && blocked + working + done == 0 }

    /// Most Blocked Agents first; ties keep herdr's order.
    static func rows(
        _ groups: [ArcProjectGroup], title: (ConsoleAgent) -> String
    ) -> [Self] {
        let rows = groups.flatMap(\.projects).map { project in
            func matching(_ status: AgentStatus) -> [ConsoleAgent] {
                project.agents.filter { $0.agent.status == status }
            }
            let blocked = matching(.blocked)
            let working = matching(.working)
            return Self(
                project: project,
                blocked: blocked.count,
                working: working.count,
                done: matching(.done).count,
                subtitle: (blocked.first ?? working.first).map(title))
        }
        return rows.enumerated()
            .sorted { lhs, rhs in
                lhs.element.blocked != rhs.element.blocked
                    ? lhs.element.blocked > rhs.element.blocked
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
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
                columns: [GridItem(.adaptive(minimum: 60, maximum: 96), spacing: 6)], spacing: 6
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
        .padding(.vertical, 4)
    }
}

/// Every Host's projects as one scrolling row of tiles, so the selected
/// project's card keeps the screen; the trailing button opens the full grid.
struct ArcProjectStrip: View {
    let groups: [ArcProjectGroup]
    let selected: ConsoleWorkspaceSection.ID?
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    let onExpand: () -> Void

    private var count: Int { groups.reduce(0) { $0 + $1.projects.count } }

    var body: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 {
                                Divider().frame(height: 32)
                            }
                            ForEach(group.projects) { project in
                                ArcProjectTile(
                                    label: project.label, statuses: project.statuses,
                                    isSelected: project.id == selected,
                                    action: { onSelect(project.id) })
                                .frame(width: 64)
                                .id(project.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
                .onChange(of: selected) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Button(action: onExpand) {
                VStack(spacing: 2) {
                    Image(systemName: "square.grid.2x2")
                        .font(.body.weight(.semibold))
                    Text(verbatim: "\(count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.tint)
                .frame(width: 44, height: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("All Projects"))
            .accessibilityValue(Text(verbatim: "\(count)"))
        }
        .frame(height: 54)
        .padding(.vertical, 4)
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
            VStack(spacing: 3) {
                ArcProjectBadge(label: label, size: 24)
                Text(verbatim: label)
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(color.opacity(0.22))
                        }
                    }
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

/// The Waiting page: Blocked conversations, then Done ones, each a row that
/// opens the Agent. Approving in place comes later; the rows carry no
/// buttons.
struct ArcWaitingPage: View {
    let blocked: [ArcWaitingList.Entry]
    let done: [ArcWaitingList.Entry]
    let agentTitle: (ConsoleAgent) -> String
    let now: (ConsoleAgent) -> String?
    let onSelect: (ConsoleAgent.ID) -> Void

    var body: some View {
        Group {
            if blocked.isEmpty && done.isEmpty {
                ContentUnavailableView {
                    Label("Nothing waiting", systemImage: "checkmark.circle")
                }
            } else {
                List {
                    if !blocked.isEmpty {
                        Section { rows(blocked) }
                    }
                    if !done.isEmpty {
                        Section {
                            rows(done)
                        } header: {
                            Text(String(localized: "Waiting section Done", defaultValue: "Done", comment: "Section of finished Agents on the Waiting page"))
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(ConsoleTab.waiting.title)
    }

    private func rows(_ entries: [ArcWaitingList.Entry]) -> some View {
        ForEach(entries) { @Sendable entry in
            MainActorContent {
                ArcWaitingRow(
                    agent: entry.agent, projectName: entry.projectLabel,
                    title: agentTitle(entry.agent),
                    now: now(entry.agent)
                ) { onSelect(entry.id) }
            }
        }
    }
}

/// The desktop board's reading of one conversation, for an arc row's second
/// line and a status: what its Agent is doing now, and where that leaves it.
struct ArcAgentLine: Equatable, Sendable {
    let now: String?
    let status: ArcProjectLight.Light?

    init(agent: ConsoleAgent, now: [Host.ID: [String: ArcAgentNow]]) {
        self.now = ArcAgentNowLookup.now(for: agent, in: now)?.text
        switch agent.agent.status {
        case .blocked: status = .blocked
        case .working: status = .working
        case .done: status = .done
        default: status = nil
        }
    }
}

/// One conversation on the arc list's card: the program's mark, the title,
/// and what the Agent is doing now, with its status at the trailing edge.
/// The link around it carries the detail, menu and swipe actions.
struct ArcAgentRow: View {
    let agent: ConsoleAgent
    let title: String
    /// What the Agent is doing now, else its terminal's own title.
    let now: String?
    /// Named ahead of `now`, for a row under another project's card.
    var projectName: String?

    var body: some View {
        HStack(spacing: 10) {
            AgentKindMarkView(kind: agent.agent.kind, diameter: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let said = subtitle, said != title {
                    Text(verbatim: said)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            status
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    @ViewBuilder
    private var status: some View {
        switch agent.agent.status {
        case .blocked:
            Text(String(localized: "Blocked pill", defaultValue: "Waiting", comment: "Badge on a Blocked Agent's row"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.16), in: Capsule())
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.yellow)
                .accessibilityHidden(true)
        case .done:
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        default:
            EmptyView()
        }
    }

    private var subtitle: String? {
        switch (projectName, now) {
        case (let project?, let now?): "\(project) · \(now)"
        case (_?, nil): projectName
        case (nil, _): now
        }
    }

    private var accessibilityText: String {
        [title, subtitle, agent.agent.status.displayTitle]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// One conversation on the Waiting page: its project's badge with the
/// Agent's own mark, its title, where it lives, and what it is doing now.
struct ArcWaitingRow: View {
    let agent: ConsoleAgent
    let projectName: String
    let title: String
    /// What the Agent is doing now; the terminal's own title stands in.
    let now: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                lead
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(verbatim: "\(projectName) · \(agent.hostName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let said = now ?? agent.agent.terminalTitleStripped.flatMap({
                        $0.isEmpty ? nil : $0
                    }), said != title {
                        Text(verbatim: said)
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(projectName), \(agent.hostName)"))
        .accessibilityAddTraits(.isButton)
    }

    /// The project's 38-point badge with the Agent's mark over its lower
    /// trailing corner, so a row says both where it belongs and what runs it.
    private var lead: some View {
        ArcProjectBadge(label: projectName, size: 38)
            .overlay(alignment: .bottomTrailing) {
                AgentKindMarkView(kind: agent.agent.kind, diameter: 20)
                    .offset(x: 4, y: 4)
            }
            .accessibilityHidden(true)
    }
}

/// Where the Progress page pushes: the Usage dashboard, the one page below it.
enum ArcProgressDestination: Hashable, Sendable {
    case usage
}

/// The Progress page's two scopes: the project the list shows, or every one.
enum ArcProgressScope: String, CaseIterable, Identifiable, Sendable {
    case project
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .project: String(localized: "This Project")
        case .all: String(localized: "All")
        }
    }
}

/// The Progress page: the selected project's board, or every project's
/// counts, then Usage. A project row opens that project on the Projects tab.
struct ArcProgressPage<Usage: View>: View {
    let scope: Binding<ArcProgressScope>
    let rows: [ArcProgressRow]
    /// The project the page's own scope shows: the arc list's selection.
    let selected: ArcProgressRow?
    let board: ArcProjectBoard?
    /// Every Host's boards, by space, for the all-projects rows' first ask.
    let boards: [Host.ID: [String: ArcProjectBoard]]
    let showsUsage: Bool
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    /// Reads the boards again: a pull down, or a first look.
    let refresh: () async -> Void
    @ViewBuilder let usage: () -> Usage

    var body: some View {
        List {
            Section {
                Picker("Progress scope", selection: scope) {
                    ForEach(ArcProgressScope.allCases) { @Sendable item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
            }
            switch scope.wrappedValue {
            case .project:
                projectBoard
            case .all:
                allProjects
            }
            if showsUsage {
                Section(ConsoleTab.usage.title) {
                    NavigationLink(value: ArcProgressDestination.usage) {
                        Label(ConsoleTab.usage.title, systemImage: ConsoleTab.usage.systemImage)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ConsoleTab.progress.title)
        .navigationDestination(for: ArcProgressDestination.self) { _ in usage() }
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    @ViewBuilder
    private var projectBoard: some View {
        if let selected {
            if let board, !board.isEmpty {
                ArcBoardSections(project: selected.project, board: board)
            } else {
                Section {
                    ContentUnavailableView {
                        Label("No board for this project", systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text("Open the progress panel once in herdr arc on your computer.")
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var allProjects: some View {
        if !rows.isEmpty {
            Section("Projects") {
                ForEach(rows) { @Sendable row in
                    MainActorContent {
                        ArcProgressProjectRow(
                            row: row,
                            board: ArcBoardLookup.board(for: row.id, in: boards)
                        ) { onSelect(row.id) }
                    }
                }
            }
        }
    }
}

/// One project's board: the header with its counts, then whoever waits on
/// the user, the next step, what can ship, and when it was written.
struct ArcBoardSections: View {
    let project: ArcProjectGroup.Project
    let board: ArcProjectBoard

    private var blocked: Int { project.statuses.count { $0 == .blocked } }

    var body: some View {
        Section {
            ArcBoardHeader(
                label: project.label, blocked: blocked, asks: board.asks.count,
                shippable: board.gates.count { $0.ok == true })
        }
        if !board.asks.isEmpty {
            Section("Waiting on You") {
                ForEach(board.asks) { @Sendable ask in
                    MainActorContent {
                        ArcBoardAskRow(
                            icon: ask.kind == .decision ? "arrow.triangle.branch" : "hand.raised",
                            tint: ask.kind == .decision ? .red : .orange,
                            title: ask.title, detail: ask.detail, since: ask.since)
                    }
                }
            }
        }
        if let next = board.next {
            Section("Next Step") {
                ArcBoardNextRow(next: next)
            }
        }
        if !board.gates.isEmpty {
            Section("Shipping") {
                ForEach(board.gates) { @Sendable gate in
                    MainActorContent { ArcBoardGateRow(gate: gate) }
                }
            }
        }
        if let at = board.at {
            Section {
                Text(verbatim: ArcBoardText.updated(at))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A board's head: the project's badge, its name, and how many wait on the
/// user, how many asks there are, and how much can ship.
struct ArcBoardHeader: View {
    let label: String
    let blocked: Int
    let asks: Int
    let shippable: Int

    var body: some View {
        HStack(spacing: 10) {
            ArcProjectBadge(label: label, size: 34)
            Text(verbatim: label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ArcProjectColor.color(for: label))
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if blocked > 0 { ArcCountPill(light: .blocked, count: blocked) }
                if asks > 0 {
                    ArcTaggedCountPill(count: asks, systemImage: "text.bubble", tint: .orange)
                }
                if shippable > 0 {
                    ArcTaggedCountPill(count: shippable, systemImage: "shippingbox", tint: .green)
                }
            }
        }
        .textCase(nil)
    }
}

/// One thing waiting on the user: what it is, its detail, and how long it
/// has waited.
struct ArcBoardAskRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?
    let since: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.subheadline)
                    .lineLimit(3)
                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            if let since {
                Text(verbatim: since.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The board's next step: a flag, the sentence, and how long it should take.
struct ArcBoardNextRow: View {
    let next: ArcProjectBoard.Next

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "flag")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)
                .background(Color.blue.opacity(0.16), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(verbatim: next.text)
                .font(.subheadline)
                .lineLimit(4)
            Spacer(minLength: 4)
            if let eta = next.eta {
                Text(verbatim: eta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One item that can ship, or cannot yet: its mark, what it is, and why.
struct ArcBoardGateRow: View {
    let gate: ArcProjectBoard.Gate

    private var mark: (icon: String, tint: Color) {
        switch gate.ok {
        case true: ("checkmark.circle.fill", .green)
        case false: ("xmark.circle", .red)
        case nil: ("circle.dotted", .gray)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: mark.icon)
                .foregroundStyle(mark.tint)
                .accessibilityLabel(Text(statusText))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: gate.title)
                    .font(.subheadline)
                    .lineLimit(3)
                if let why = gate.why {
                    Text(verbatim: why)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        }
    }

    private var statusText: String {
        switch gate.ok {
        case true: String(localized: "Can ship")
        case false: String(localized: "Cannot ship yet")
        case nil: String(localized: "Needs checking")
        }
    }
}

/// The board's own wording: the footer's update line.
enum ArcBoardText {
    static func updated(_ date: Date) -> String {
        String(localized: "Updated \(date.formatted(.relative(presentation: .named)))")
    }
}

/// A status's count in its color: red Blocked, yellow Working, green Done.
struct ArcCountPill: View {
    let light: ArcProjectLight.Light
    let count: Int

    private var systemImage: String {
        switch light {
        case .blocked: "hand.raised"
        case .working: "circle.dotted"
        case .done: "checkmark"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(verbatim: "\(count)")
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(light.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(light.color.opacity(0.16), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// An all-projects row's second line: the first thing waiting on the user,
/// else the Agent the project is busy with.
enum ArcProgressSubtitle {
    static func text(for row: ArcProgressRow, board: ArcProjectBoard?) -> String? {
        board?.asks.first.map { String(localized: "Waiting: \($0.title)") } ?? row.subtitle
    }
}

/// A count in a board color, with its own symbol: asks waiting and gates
/// that can ship.
struct ArcTaggedCountPill: View {
    let count: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(verbatim: "\(count)")
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Every project's row on Progress: its badge, its name, the first ask that
/// waits on the user (else what a working Agent does), and its counts.
struct ArcProgressProjectRow: View {
    let row: ArcProgressRow
    /// The board that names its first ask, where there is one.
    let board: ArcProjectBoard?
    let action: () -> Void

    private var counts: [(light: ArcProjectLight.Light, count: Int)] {
        [(.blocked, row.blocked), (.working, row.working), (.done, row.done)]
            .filter { $0.count > 0 }
    }

    private var subtitle: String? { ArcProgressSubtitle.text(for: row, board: board) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArcProjectBadge(label: row.project.label, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.project.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.subheadline)
                            .foregroundStyle(
                                AnyShapeStyle(board?.asks.isEmpty == false ? .red : .secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(counts, id: \.light) { @Sendable item in
                        MainActorContent {
                            ArcCountPill(light: item.light, count: item.count)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        ([row.project.label, subtitle].compactMap { $0 }
            + counts.map { "\($0.light.status.displayTitle ?? "") \($0.count)" })
            .joined(separator: ", ")
    }
}
