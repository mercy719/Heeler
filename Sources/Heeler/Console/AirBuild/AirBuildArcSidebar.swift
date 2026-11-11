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

    /// Big tiles, three across a phone like AirBuild's, never five small ones.
    static func columns(for width: CGFloat) -> Int {
        max(1, Int(width / 100))
    }

    static func badge(for project: ArcProjectGroup.Project) -> Badge? {
        let blocked = project.statuses.count { $0 == .blocked }
        if blocked > 0 { return .blocked(blocked) }
        // Running outranks Done: a finished Agent beside a running one must not hide the run.
        if project.statuses.contains(.working) { return .working }
        return project.statuses.contains(.done) ? .done : nil
    }

    static func ordered(_ projects: [ArcProjectGroup.Project]) -> [ArcProjectGroup.Project] {
        projects.enumerated().sorted { lhs, rhs in
            let leftBlocked = lhs.element.statuses.count { $0 == .blocked }
            let rightBlocked = rhs.element.statuses.count { $0 == .blocked }
            if leftBlocked != rightBlocked { return leftBlocked > rightBlocked }
            let leftWorking = lhs.element.statuses.contains(.working)
            let rightWorking = rhs.element.statuses.contains(.working)
            if leftWorking != rightWorking { return leftWorking }
            return lhs.offset < rhs.offset
        }.map(\.element)
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

struct AirBuildProjectGrid: View {
    let projects: [ArcProjectGroup.Project]
    let selected: ConsoleWorkspaceSection.ID?
    var limitsToTwoRows = true
    let onSelect: (ConsoleWorkspaceSection.ID) -> Void
    var onShowAll: (() -> Void)?

    @State private var width: CGFloat = 0
    @Environment(\.isSidebarColumn) private var isSidebarColumn

    private var columns: Int { AirBuildProjectLayout.columns(for: width) }
    /// Three rows like a home screen when folded; two beside the detail, where
    /// the conversations below need the room.
    private var rows: Int { isSidebarColumn ? 2 : 3 }
    /// The tile's square; the home screen has the room for a bigger one.
    private var tileSize: CGFloat { isSidebarColumn ? 62 : 84 }
    private var rowHeight: CGFloat { tileSize + 30 }

    var body: some View {
        Group {
            if limitsToTwoRows {
                let pages = AirBuildProjectLayout.pages(projects, columns: columns, rows: rows)
                if pages.count > 1 {
                    // Swiped page by page, as apps on the home screen. A fixed height,
                    // so nothing measured here feeds back into the layout.
                    TabView {
                        ForEach(pages.indices, id: \.self) { @Sendable index in
                            MainActorContent {
                                grid(pages[index])
                                    .frame(maxHeight: .infinity, alignment: .top)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .never))
                    .frame(height: CGFloat(rows) * rowHeight + 30)
                } else {
                    grid(pages.first ?? [])
                }
            } else {
                grid(AirBuildProjectLayout.ordered(projects).map { .project($0) })
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func grid(_ slots: [AirBuildProjectLayout.Slot]) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
            spacing: 10
        ) {
            ForEach(slots) { @Sendable slot in
                MainActorContent {
                    switch slot {
                    case .project(let project):
                        AirBuildProjectTile(
                            project: project, isSelected: project.id == selected, size: tileSize
                        ) { onSelect(project.id) }
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
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("All Projects"))
                        .accessibilityValue(Text(verbatim: "\(count)"))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }
}

private struct AirBuildProjectTile: View {
    let project: ArcProjectGroup.Project
    let isSelected: Bool
    var size: CGFloat = 62
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
                    .frame(maxWidth: size + 10)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    AirBuildStatusLampView(lamp: lamp, size: 14)
                        .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                        .offset(x: 2, y: 2)
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

struct AirBuildAccountMark: View {
    var size: CGFloat = 28

    var body: some View {
        Text("A")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [.orange, Color(red: 0.48, green: 0.17, blue: 0.1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle())
            .accessibilityLabel("Account")
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
