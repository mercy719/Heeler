import SwiftUI

/// The two-row project grid's ordering and overflow, kept pure for the arc tests.
enum AirBuildProjectLayout {
    enum Badge: Equatable, Sendable {
        case blocked(Int)
        case working
        case done
    }

    enum Slot: Identifiable, Equatable, Sendable {
        case project(ArcProjectGroup.Project)
        case all(Int)

        var id: String {
            switch self {
            case .project(let project): project.id.storedText
            case .all: "all"
            }
        }
    }

    /// The project grid, N × N, as Settings sets it, on the folded home and beside the detail.
    static let homeGridKey = "arc.home-grid"
    static let homeGridChoices = [3, 4, 5]

    /// A project drawer's rows: an Agent's is 60 points and a shell's 38, as
    /// their rows draw them on the home screen.
    static func drawerRowsHeight(agents: Int, shells: Int) -> CGFloat {
        min(CGFloat(agents) * 60 + CGFloat(shells) * 38, drawerRowsLimit)
    }

    /// Five Agents' worth; more scroll, so the tiles below stay in reach.
    static let drawerRowsLimit: CGFloat = 300
    static let drawerTopInset: CGFloat = 6
    static let drawerFooterHeight: CGFloat = 55

    static func drawerContentHeight(agents: Int, shells: Int, hasNewButtons: Bool) -> CGFloat {
        drawerTopInset + drawerRowsHeight(agents: agents, shells: shells)
            + (hasNewButtons ? drawerFooterHeight : 0)
    }

    /// The largest tile `columns` fit across `width`, its label and the gaps
    /// included, never bigger than `largest`.
    static func tileSize(columns: Int, width: CGFloat, largest: CGFloat = 84) -> CGFloat {
        guard width > 0, columns > 0 else { return largest }
        let cell = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
        return min(largest, max(36, cell - 14))
    }

    static func badge(for project: ArcProjectGroup.Project) -> Badge? {
        let blocked = project.statuses.count { $0 == .blocked }
        if blocked > 0 { return .blocked(blocked) }
        // Running outranks Done: a finished Agent beside a running one must not hide the run.
        if project.statuses.contains(.working) { return .working }
        return project.statuses.contains(.done) ? .done : nil
    }

    /// Projects with Agents first, then the rest, each in herdr's order. A
    /// status change only relights a badge, so tiles keep their places.
    static func ordered(_ projects: [ArcProjectGroup.Project]) -> [ArcProjectGroup.Project] {
        projects.filter { !$0.agents.isEmpty } + projects.filter(\.agents.isEmpty)
    }

    /// Home-screen pages of `columns` × `rows` tiles. More projects than one
    /// page holds add the All tile (its search) after the last project.
    static func pages(_ projects: [ArcProjectGroup.Project], columns: Int, rows: Int) -> [[Slot]] {
        let ordered = ordered(projects)
        let capacity = max(1, columns) * max(1, rows)
        guard ordered.count > capacity else { return [ordered.map(Slot.project)] }
        let slots = ordered.map(Slot.project) + [.all(ordered.count)]
        return stride(from: 0, to: slots.count, by: capacity).map {
            Array(slots[$0..<min($0 + capacity, slots.count)])
        }
    }
}

/// What a long press on a project tile offers, most used first; nil leaves
/// an item out where the Host can't do it.
struct AirBuildProjectActions {
    var newAgent: (() -> Void)?
    var newTerminal: (() -> Void)?
    var rename: (() -> Void)?
    var copyPath: (() -> Void)?
}

struct AirBuildProjectGrid: View {
    let projects: [ArcProjectGroup.Project]
    let selected: ConsoleWorkspaceSection.ID?
    var limitsToTwoRows = true
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    var onShowAll: (() -> Void)?
    var actions: ((ArcProjectGroup.Project) -> AirBuildProjectActions)?
    /// What a tapped tile opens under its row (its Agents and terminals), given
    /// a way to close it; nil keeps a tap to selecting the project.
    var drawer: ((ArcProjectGroup.Project, @escaping @MainActor @Sendable () -> Void) -> AnyView)?

    @State private var width: CGFloat = 0
    /// The page shown when the projects take more than one.
    @State private var page: Int?
    /// The project whose drawer is open, at full height.
    @State private var drawerProjectID: ConsoleWorkspaceSection.ID?
    /// Drawers in the layout: the open one, one still closing, and one about to
    /// open at no height, so opening and closing both animate a height and never
    /// an insertion (which would land at full height and jump the rows below).
    @State private var mountedDrawers: Set<ConsoleWorkspaceSection.ID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSidebarColumn) private var isSidebarColumn
    @AppStorage(AirBuildProjectLayout.homeGridKey) private var homeGrid = 3

    /// Settings' N × N everywhere; beside the detail the tiles stay smaller,
    /// so the conversations below keep some room.
    private var columns: Int { homeGrid }
    private var rows: Int { homeGrid }
    private var tileSize: CGFloat {
        AirBuildProjectLayout.tileSize(columns: homeGrid, width: width, largest: isSidebarColumn ? 62 : 84)
    }
    private var rowHeight: CGFloat { tileSize + 30 }
    private static let pageTopInset: CGFloat = 8

    var body: some View {
        Group {
            if limitsToTwoRows {
                let pages = AirBuildProjectLayout.pages(projects, columns: columns, rows: rows)
                if pages.count > 1 {
                    // Swiped page by page, as apps on the home screen. A SwiftUI paging
                    // scroll, not a page-style TabView: that one's UIKit pages jumped
                    // up and down whenever an opening drawer changed its height.
                    VStack(spacing: 0) {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(pages.indices, id: \.self) { @Sendable index in
                                    MainActorContent {
                                        // Room above for the badges and the selection
                                        // ring that stand out of a tile.
                                        grid(pages[index])
                                            .padding(.top, Self.pageTopInset)
                                            .frame(minHeight: CGFloat(rows) * rowHeight + Self.pageTopInset, alignment: .top)
                                            .containerRelativeFrame(.horizontal)
                                            .id(index)
                                    }
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollIndicators(.hidden)
                        .scrollPosition(id: $page)
                        AirBuildPageDots(count: pages.count, current: page ?? 0)
                            .frame(height: 30)
                    }
                } else {
                    grid(pages.first ?? [])
                }
            } else {
                grid(AirBuildProjectLayout.ordered(projects).map { .project($0) })
            }
        }
        // A new N × N builds the pages afresh: the paged view kept the old
        // pages' cells and laid the new size over them.
        .id(homeGrid)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// Rows of tiles; a drawer sits under its tile's row and pushes the rows
    /// below it down, as a folder opens in place.
    private func grid(_ slots: [AirBuildProjectLayout.Slot]) -> some View {
        let lines = stride(from: 0, to: slots.count, by: columns).map {
            Array(slots[$0..<min($0 + columns, slots.count)])
        }
        // Spacing lives in padding, so a drawer at no height adds none.
        return VStack(spacing: 0) {
            ForEach(lines.indices, id: \.self) { @Sendable index in
                MainActorContent {
                    let line = lines[index]
                    let isLast = index == lines.count - 1
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(line) { @Sendable slot in
                            MainActorContent { cell(slot) }
                        }
                        ForEach(line.count..<columns, id: \.self) { @Sendable _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                        }
                    }
                    .padding(.bottom, isLast ? 0 : 10)
                    ForEach(Array(line.enumerated()), id: \.element.id) { @Sendable pair in
                        MainActorContent {
                            if let drawer, case .project(let project) = pair.element, mountedDrawers.contains(project.id) {
                                drawerPanel(drawer(project) { close() }, project: project, column: pair.offset)
                                    .padding(isLast ? .top : .bottom, 10)
                                    .modifier(AirBuildRevealHeight(
                                        height: project.id == drawerProjectID ? drawerHeight(project) + 10 : 0))
                                    .opacity(project.id == drawerProjectID ? 1 : 0)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    private func drawerPanel(_ content: AnyView, project: ArcProjectGroup.Project, column: Int) -> some View {
        let fill = Color(uiColor: .secondarySystemBackground)
        return VStack(spacing: 0) {
            // The caret points at the tile that opened it.
            HStack(spacing: 8) {
                ForEach(0..<columns, id: \.self) { @Sendable index in
                    MainActorContent {
                        if index == column {
                            AirBuildDrawerCaret().fill(fill).frame(width: 20, height: Self.caretHeight)
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: Self.caretHeight)
                        }
                    }
                }
            }
            content
                .frame(height: contentHeight(project), alignment: .top)
                .background(fill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private static let caretHeight: CGFloat = 9

    /// Known before the drawer draws, so the paged view and the rows below
    /// move in the same animation as the drawer itself.
    private func contentHeight(_ project: ArcProjectGroup.Project) -> CGFloat {
        let actions = actions?(project)
        return AirBuildProjectLayout.drawerContentHeight(
            agents: project.agents.count, shells: project.shells.count,
            hasNewButtons: actions?.newAgent != nil || actions?.newTerminal != nil)
    }

    private func drawerHeight(_ project: ArcProjectGroup.Project) -> CGFloat {
        Self.caretHeight + contentHeight(project)
    }

    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12) }

    /// Mounts the drawer at no height first, then grows it on the next turn,
    /// while any other open drawer shrinks in the same animation.
    private func toggleDrawer(_ id: ConsoleWorkspaceSection.ID) {
        if drawerProjectID == id { return close() }
        mountedDrawers.insert(id)
        Task { @MainActor in
            withAnimation(motion) { drawerProjectID = id } completion: { unmountClosed() }
        }
    }

    private func close() {
        withAnimation(motion) { drawerProjectID = nil } completion: { unmountClosed() }
    }

    private func unmountClosed() {
        mountedDrawers = drawerProjectID.map { [$0] } ?? []
    }

    @ViewBuilder
    private func cell(_ slot: AirBuildProjectLayout.Slot) -> some View {
        switch slot {
        case .project(let project):
            AirBuildProjectTile(
                project: project, isSelected: project.id == selected, size: tileSize,
                actions: actions?(project)
            ) {
                onSelect(project.id)
                if drawer != nil { toggleDrawer(project.id) }
            }
        case .all(let count):
            Button {
                onShowAll?()
            } label: {
                VStack(spacing: 6) {
                    VStack(spacing: 0) {
                        Text("All")
                        Text(verbatim: "\(count)")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: tileSize, height: tileSize)
                    .background(
                        Color(uiColor: .systemGray).opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("All Projects")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("All Projects"))
            .accessibilityValue(Text(verbatim: "\(count)"))
        }
    }
}

/// Which page of tiles shows, as the home screen's dots say it.
private struct AirBuildPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { @Sendable index in
                MainActorContent {
                    Circle()
                        .fill(index == current ? Color.primary : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Page \(current + 1) of \(count)"))
    }
}

/// A height that lays out afresh on every frame of its animation. The home
/// list resizes the grid's row for each step as a plain change; a plain
/// animated `frame(height:)` let the list animate the row itself, which drew
/// the tiles up to 300 points too high while a drawer shrank.
private struct AirBuildRevealHeight: ViewModifier, Animatable {
    var height: CGFloat

    nonisolated var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: max(0, height), alignment: .top).clipped()
    }
}

private struct AirBuildDrawerCaret: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct AirBuildProjectTile: View {
    let project: ArcProjectGroup.Project
    let isSelected: Bool
    var size: CGFloat = 62
    var actions: AirBuildProjectActions?
    /// The badge's ring cuts it from the tile against the page behind.
    private let background = Color(uiColor: .systemBackground)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AirBuildProjectIcon(project: project, size: size * 0.74)
                        .frame(width: size, height: size)
                        .background(
                            Color(uiColor: .systemGray6),
                            in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
                        .overlay {
                            if isSelected {
                                RoundedRectangle(cornerRadius: size * 0.26 + 3, style: .continuous)
                                    .stroke(.tint, lineWidth: 2.5)
                                    .frame(width: size + 6, height: size + 6)
                            }
                        }
                    badge
                }
                Text(verbatim: project.label)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let newAgent = actions?.newAgent {
                Button("New Agent", systemImage: "plus", action: newAgent)
            }
            if let newTerminal = actions?.newTerminal {
                Button("New Terminal", systemImage: "apple.terminal", action: newTerminal)
            }
            if let rename = actions?.rename {
                Button("Rename", systemImage: "pencil", action: rename)
            }
            if let copyPath = actions?.copyPath {
                Button("Copy Path", systemImage: "doc.on.doc", action: copyPath)
            }
        }
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var badge: some View {
        switch AirBuildProjectLayout.badge(for: project) {
        case .blocked(let count):
            Text(verbatim: "\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .padding(.horizontal, count > 9 ? 4 : 0)
                .background(AirBuildStatusLamp.waiting.color, in: Capsule())
                .overlay(Capsule().stroke(background, lineWidth: 2))
                .offset(x: 4, y: -4)
                .accessibilityHidden(true)
        case .working:
            Circle()
                .fill(AirBuildStatusLamp.working.color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(background, lineWidth: 2))
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        case .done:
            Circle()
                .fill(AirBuildStatusLamp.done.color)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(background, lineWidth: 2))
                .offset(x: 2, y: -2)
                .accessibilityHidden(true)
        case nil:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        var parts = [project.label]
        switch AirBuildProjectLayout.badge(for: project) {
        case .blocked(let count):
            parts.append("\(String(localized: "Waiting on You")) \(count)")
        case .working:
            parts.append(String(localized: "Running"))
        case .done:
            parts.append(String(localized: "Agent status Done", defaultValue: "Done"))
        case nil:
            break
        }
        return parts.joined(separator: ", ")
    }
}

/// All Projects' search: a substring of the name, or the first letters of
/// its words in pinyin, so 「lg」 finds 灵感看板.
enum AirBuildProjectSearch {
    static func matches(_ label: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if label.localizedCaseInsensitiveContains(query) { return true }
        let latin = (label.applyingTransform(.toLatin, reverse: false) ?? label)
            .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? label.lowercased()
        let words = latin.split { !$0.isLetter && !$0.isNumber }
        return String(words.compactMap(\.first)).hasPrefix(query) || words.joined().hasPrefix(query)
    }
}

struct AirBuildAllProjectsView: View {
    let groups: [ArcProjectGroup]
    let selected: ConsoleWorkspaceSection.ID?
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [(group: ArcProjectGroup, projects: [ArcProjectGroup.Project])] {
        groups.compactMap { group in
            let projects = group.projects.filter { AirBuildProjectSearch.matches($0.label, query: query) }
            return projects.isEmpty ? nil : (group, projects)
        }
    }

    private func choose(_ id: ConsoleWorkspaceSection.ID) {
        onSelect(id)
        dismiss()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(matches, id: \.group.id) { @Sendable match in
                        MainActorContent {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: match.group.hostName)
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                AirBuildProjectGrid(
                                    projects: match.projects, selected: selected,
                                    limitsToTwoRows: false,
                                    onSelect: { id in choose(id) })
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .overlay {
                if matches.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search Projects"))
            // Return opens the first match, so a few letters and Return switch projects.
            .onSubmit(of: .search) {
                if let first = matches.first?.projects.first { choose(first.id) }
            }
            .navigationTitle("All Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A project's icon: its boss Agent's plush on a tile, never the name's
/// first letter; a grey plush of its own for a project with no Agent yet.
struct AirBuildProjectIcon: View {
    let project: ArcProjectGroup.Project
    var size: CGFloat = 42

    var body: some View {
        Group {
            if let boss = project.boss {
                OBPlushAvatar(seed: AirBuildSessionAvatar.seed(for: boss), size: size)
            } else {
                // No Agent yet: still a plush, one of its own, but grey and dim so
                // an empty project reads as asleep beside the staffed ones.
                OBPlushAvatar(seed: "project:\(project.id)", size: size)
                    .saturation(0)
                    .opacity(0.45)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The fixed 40-point session avatar and its Blocked, Done or Working mark.
struct AirBuildSessionAvatar: View {
    let agent: ConsoleAgent
    var size: CGFloat = 40
    static func seed(for agent: ConsoleAgent) -> String { "\(agent.hostID.uuidString):\(agent.agent.paneID)" }
    private var seed: String { Self.seed(for: agent) }

    var body: some View {
        OBPlushAvatar(seed: seed, size: size)
            .clipShape(Circle())
            // One mark for every state, the tiles' own: a quarter ring turning
            // above the head read as a stray arc (2026-11-12).
            .overlay(alignment: .bottomTrailing) {
                if let lamp {
                    // In scale with the avatar: a fixed 14 points outgrew Chat's 22-point one.
                    AirBuildStatusLampView(lamp: lamp, size: max(6, (size * 0.3).rounded()))
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: size < 30 ? 1.5 : 2))
                        .offset(x: size * 0.05, y: size * 0.05)
                }
            }
            .frame(width: size + 6, height: size + 6)
            .accessibilityLabel(Text(verbatim: "\(agent.agent.displayName), \(statusText)"))
    }

    private var lamp: AirBuildStatusLamp? {
        switch agent.agent.status {
        case .working: .working
        case .blocked: .waiting
        case .done: .done
        default: nil
        }
    }

    private var statusText: String {
        switch agent.agent.status {
        case .blocked: String(localized: "Waiting on You")
        case .working: String(localized: "Running")
        case .done: String(localized: "Agent status Done", defaultValue: "Done")
        default: agent.agent.status.displayTitle ?? ""
        }
    }
}

struct AirBuildHeelerLogo: View {
    var body: some View {
        if let icon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon") {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityLabel("Heeler")
        } else {
            Text("H")
                .font(.system(size: 17, weight: .bold))
                .frame(width: 32, height: 32)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Heeler")
        }
    }
}

struct AirBuildGlassCapsule<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0, content: content)
            .frame(height: 40)
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear.glassEffect(.regular, in: Capsule())
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
    }
}

struct AirBuildScrollEdgeEffectStyle: ViewModifier {
    var isEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

struct AirBuildIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(LocalizedStringKey(label), systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }
}
