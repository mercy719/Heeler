import SwiftUI

/// The selected project's live arc board beside the chat, or in a sheet when folded. PR and Files
/// stay hidden until the board has data for them; no placeholder counts.
struct AirBuildProgressPanel: View {
    let project: ArcProjectGroup.Project
    let board: ArcProjectBoard?
    let refresh: () async -> Void
    let onClose: () -> Void
    let onOpenTerminal: () -> Void
    var onOpenUsage: (() -> Void)?
    var onShowChanges: (() -> Void)?
    /// A sheet brings its own navigation bar; beside the chat the panel sits
    /// inside the detail's stack, which must not nest another one.
    var inSheet = true

    @State private var query = ""
    @State private var showsFavorites = false

    private var asks: [ArcProjectBoard.Ask] {
        (board?.asks ?? []).filter {
            matches($0.title, $0.detail)
        }
    }
    private var next: ArcProjectBoard.Next? {
        guard let next = board?.next, matches(next.text, next.eta) else { return nil }
        return next
    }
    private var gates: [ArcProjectBoard.Gate] {
        (board?.gates ?? []).filter { matches($0.title, $0.why) }
    }
    private var waitingCount: Int {
        board?.asks.count ?? project.statuses.count { $0 == .blocked }
    }

    var body: some View {
        if inSheet {
            NavigationStack { panel }
        } else {
            panel
        }
    }

    private var panel: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        workspaceHeader
                        search
                        if showsFavorites {
                            sectionTitle("Frequently Used")
                            favorites(proxy: proxy)
                        }
                        if let board, !board.isEmpty {
                            if !asks.isEmpty {
                                sectionTitle("Waiting on You")
                                AirBuildPanelGroup {
                                    ForEach(asks) { @Sendable ask in
                                        MainActorContent {
                                            AirBuildPanelRow(
                                                icon: ask.kind == .decision ? "arrow.triangle.branch" : "hand.raised",
                                                tint: ask.kind == .decision ? .red : AirBuildStatusLamp.waiting.color,
                                                title: ask.title, detail: ask.detail,
                                                time: ask.since?.formatted(.relative(presentation: .named)))
                                        }
                                    }
                                }
                                .id("waiting")
                            }
                            if let next {
                                sectionTitle("Next Step")
                                AirBuildPanelGroup {
                                    AirBuildPanelRow(
                                        icon: "flag", tint: .blue,
                                        title: next.text, detail: next.eta, time: nil)
                                }
                            }
                            if !gates.isEmpty {
                                sectionTitle("Shipping")
                                AirBuildPanelGroup {
                                    ForEach(gates) { @Sendable gate in
                                        MainActorContent { row(gate) }
                                    }
                                }
                            }
                            if asks.isEmpty && next == nil && gates.isEmpty && !query.isEmpty {
                                ContentUnavailableView.search(text: query)
                            }
                        } else {
                            ContentUnavailableView {
                                Label("No board for this project", systemImage: "chart.bar.doc.horizontal")
                            } description: {
                                Text("Open the progress panel once in herdr arc on your computer.")
                            }
                            .padding(.top, 48)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(Text(verbatim: "\(project.label) · \(ConsoleTab.progress.title)"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 8) {
            workspaceTab(title: "Progress", isSelected: true, closeLabel: "Close Progress") {}
            if let onShowChanges {
                workspaceTab(title: "Changes", isSelected: false, closeLabel: "Close Changes") {
                    onClose()
                    onShowChanges()
                }
            }
            Spacer(minLength: 0)
            Button {
                showsFavorites.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .systemGray5), in: Circle())
            .accessibilityLabel("Frequently Used")
        }
        .padding(.top, 8)
    }

    private func workspaceTab(
        title: LocalizedStringKey, isSelected: Bool, closeLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Button(closeLabel, systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.system(size: 9, weight: .bold))
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color(uiColor: .systemGray5),
            in: Capsule())
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .font(.system(size: 14))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color(uiColor: .systemGray).opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 16)
            .padding(.bottom, 7)
    }

    private func favorites(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            AirBuildQuickAction(icon: "terminal", title: "Terminal", tint: Color(uiColor: .systemGray4)) {
                onClose()
                onOpenTerminal()
            }
            if waitingCount > 0 {
                AirBuildQuickAction(
                    icon: "hand.raised", title: "Waiting on You", count: waitingCount,
                    tint: AirBuildStatusLamp.waiting.color
                ) {
                    withAnimation { proxy.scrollTo("waiting", anchor: .top) }
                }
            }
            if let onShowChanges {
                AirBuildQuickAction(
                    icon: "plus.forwardslash.minus", title: "Changes", tint: .blue
                ) {
                    onClose()
                    onShowChanges()
                }
            }
            if let onOpenUsage {
                AirBuildQuickAction(icon: "gauge", title: "Usage", tint: .green) {
                    onClose()
                    onOpenUsage()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func row(_ gate: ArcProjectBoard.Gate) -> some View {
        switch gate.ok {
        case true:
            AirBuildPanelRow(icon: "checkmark.circle.fill", tint: .green, title: gate.title, detail: gate.why, time: nil)
        case false:
            AirBuildPanelRow(icon: "xmark.circle", tint: .red, title: gate.title, detail: gate.why, time: nil)
        case nil:
            AirBuildPanelRow(icon: "circle.dotted", tint: Color(uiColor: .systemGray), title: gate.title, detail: gate.why, time: nil)
        }
    }

    private func matches(_ values: String?...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return values.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

private struct AirBuildQuickAction: View {
    let icon: String
    let title: LocalizedStringKey
    var count: Int?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(tint, in: RoundedRectangle(cornerRadius: 11))
                if let count {
                    HStack(spacing: 3) {
                        Text(title)
                        Text(verbatim: "\(count)")
                    }
                } else {
                    Text(title)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AirBuildPanelGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AirBuildPanelRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String?
    let time: String?

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(3)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 4)
            if let time {
                Text(verbatim: time)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}
