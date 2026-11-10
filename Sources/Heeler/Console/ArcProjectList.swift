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
}

/// The light a project's mark carries: who in it needs the user, worst first.
/// herdr has a blue "finished a scheduled run" state too, but nothing in the
/// app reports it yet.
enum ArcProjectLight {
    enum Light: Equatable, Sendable {
        case blocked
        case done
        case working

        var color: Color {
            switch self {
            case .blocked: AirBuildStatusLamp.waiting.color
            case .done: AirBuildStatusLamp.done.color
            case .working: AirBuildStatusLamp.working.color
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
/// snapshot order, with the Agents' statuses that light their marks.
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

/// The project switcher's menu, shared by the compact title and the
/// sidebar's switcher: projects where someone waits or works first, then
/// each Host's other projects.
enum ArcProjectMenu {
    struct Item: Identifiable, Equatable, Sendable {
        let project: ArcProjectGroup.Project

        var id: ConsoleWorkspaceSection.ID { project.id }
        var blocked: Int { project.statuses.filter { $0 == .blocked }.count }
        var working: Int { project.statuses.filter { $0 == .working }.count }
        var subtitle: String? { ArcProjectMenu.subtitle(blocked: blocked, working: working) }
    }

    struct Section: Identifiable, Equatable, Sendable {
        /// The Host whose other projects the section lists; nil for the
        /// leading section of busy projects.
        let hostID: Host.ID?
        let title: String
        let items: [Item]

        var id: String { hostID?.uuidString ?? "active" }
    }

    /// Busy projects, most Blocked first, ties in herdr order; then one
    /// section per Host of its remaining projects, in herdr order.
    static func sections(_ groups: [ArcProjectGroup]) -> [Section] {
        let active = groups.flatMap(\.projects).map(Item.init).enumerated()
            .filter { $0.element.blocked + $0.element.working > 0 }
            .sorted { lhs, rhs in
                lhs.element.blocked != rhs.element.blocked
                    ? lhs.element.blocked > rhs.element.blocked
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
        let activeIDs = Set(active.map(\.id))
        var sections = active.isEmpty ? [] : [
            Section(
                hostID: nil,
                title: String(
                    localized: "Arc menu active", defaultValue: "Active",
                    comment: "Project switcher section of projects with Agents waiting or working"),
                items: active),
        ]
        for group in groups {
            let rest = group.projects.filter { !activeIDs.contains($0.id) }.map(Item.init)
            if !rest.isEmpty {
                sections.append(Section(hostID: group.id, title: group.hostName, items: rest))
            }
        }
        return sections
    }

    /// "1 waiting · 1 running", leaving out a zero count; nil when both are.
    static func subtitle(blocked: Int, working: Int) -> String? {
        let parts = [
            blocked > 0 ? String(localized: "\(blocked) waiting") : nil,
            working > 0 ? String(localized: "\(working) running") : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A project's light as a dot: beside its name on the sidebar's switcher,
/// and as its menu item's image.
struct ArcProjectMark: View {
    let light: ArcProjectLight.Light
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(light.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The dot as a menu image: a menu keeps only a `UIImage`'s own colors,
    /// and only when it renders as original.
    @MainActor
    static func image(light: ArcProjectLight.Light, scale: CGFloat) -> UIImage? {
        let key = "\(String(describing: light))\u{1F}\(scale)"
        if let cached = imageCache[key] { return cached }
        let renderer = ImageRenderer(content: ArcProjectMark(light: light))
        renderer.scale = scale
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        imageCache[key] = image
        return image
    }

    @MainActor private static var imageCache: [String: UIImage] = [:]
}

/// The switcher menu's items: one section per `ArcProjectMenu` section, the
/// shown project checked.
struct ArcProjectMenuContent: View {
    let sections: [ArcProjectMenu.Section]
    let selected: ConsoleWorkspaceSection.ID?
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.items) { item in
                    Toggle(
                        isOn: Binding(
                            get: { item.id == selected }, set: { _ in onSelect(item.id) })
                    ) {
                        // A menu reads a Text after the Label as its subtitle.
                        Label {
                            Text(verbatim: item.project.label)
                        } icon: {
                            if let light = item.project.light,
                                let image = ArcProjectMark.image(light: light, scale: displayScale)
                            {
                                Image(uiImage: image)
                            }
                        }
                        if let subtitle = item.subtitle { Text(verbatim: subtitle) }
                    }
                }
            } header: {
                Text(verbatim: section.title)
            }
        }
    }
}

/// The sidebar's first row: the shown project's mark and name opening the
/// switcher menu, and New Agent beside them.
struct ArcProjectSwitcher: View {
    let project: ArcProjectGroup.Project
    let sections: [ArcProjectMenu.Section]
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    let onNewAgent: (() -> Void)?

    private var color: Color { ArcProjectColor.color(for: project.label) }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ArcProjectMenuContent(sections: sections, selected: project.id, onSelect: onSelect)
            } label: {
                HStack(spacing: 8) {
                    Text(verbatim: project.label)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                    if let light = project.light { ArcProjectMark(light: light) }
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Switch project, current \(project.label)"))
            if let onNewAgent {
                Button(action: onNewAgent) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(color)
                .hoverEffect(.highlight)
                .accessibilityLabel("New Agent")
            }
        }
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

/// One AirBuild conversation row. The link around it still carries the
/// detail, context menu and swipe actions.
struct ArcAgentRow: View {
    let agent: ConsoleAgent
    let title: String
    /// What the Agent is doing now, else its terminal's own title.
    let now: String?
    /// Named ahead of `now`, for a row under another project's card.
    var projectName: String?
    var isSelected = false
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    var body: some View {
        HStack(spacing: 10) {
            AirBuildSessionAvatar(agent: agent)
            VStack(alignment: .leading, spacing: 0) {
                (Text(verbatim: title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                + Text(verbatim: " @\(agent.agent.kind)")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary))
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(
                            agent.agent.status == .blocked
                                ? AirBuildStatusLamp.waiting.color : Color(uiColor: .tertiaryLabel))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background {
            if isSelected && !isSidebarColumn {
                Color.white.opacity(0.1)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var subtitle: String? {
        let said = now ?? agent.agent.terminalTitleStripped.flatMap { $0.isEmpty ? nil : $0 }
        let scoped = [projectName, said == title ? nil : said].compactMap { $0 }.joined(separator: " · ")
        guard agent.agent.status == .blocked else { return scoped.isEmpty ? nil : scoped }
        if scoped.isEmpty {
            return String(localized: "Waiting for your approval", defaultValue: "Waiting for approval")
        }
        return String(localized: "Waiting for approval: \(scoped)")
    }

    private var statusText: String {
        switch agent.agent.status {
        case .blocked: String(localized: "Waiting on You")
        case .working: String(localized: "Running")
        case .done: String(localized: "Agent status Done", defaultValue: "Done")
        default: agent.agent.status.displayTitle ?? ""
        }
    }

    private var accessibilityText: String {
        [title, "@\(agent.agent.kind)", subtitle, statusText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
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

    private var lead: some View {
        AgentKindMarkView(kind: agent.agent.kind, diameter: 28)
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
