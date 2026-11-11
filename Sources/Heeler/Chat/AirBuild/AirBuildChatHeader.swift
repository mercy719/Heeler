import SwiftUI

/// Blocked conversations across every project, shown by the chat header's bell.
enum AirBuildWaitingSummary {
    static func blocked(_ agents: [ConsoleAgent]) -> [ConsoleAgent] {
        agents.filter { $0.agent.status == .blocked }
    }
}

/// The v2 status lamp's one mapping, shared by the header, rows and workspace.
enum AirBuildStatusLamp: Equatable, Sendable {
    case working
    case waiting
    case done
    case idle
    case disconnected

    init(status: AgentStatus, isHostConnected: Bool = true) {
        guard isHostConnected else {
            self = .disconnected
            return
        }
        switch status {
        case .working: self = .working
        case .blocked: self = .waiting
        case .done: self = .done
        default: self = .idle
        }
    }

    var rgb: UInt32 {
        switch self {
        case .working: 0xFF9F0A
        case .waiting: 0xBF5AF2
        case .done: 0x30D158
        case .idle, .disconnected: 0x8E8E93
        }
    }

    var isHollow: Bool { self == .disconnected }

    var color: Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255)
    }

    var accessibilityLabel: String {
        switch self {
        case .working: String(localized: "Running")
        case .waiting: String(localized: "Waiting on You")
        case .done: String(localized: "Agent status Done", defaultValue: "Done")
        case .idle: String(localized: "Idle")
        case .disconnected: String(localized: "Not Connected")
        }
    }
}

enum AirBuildRunningClock {
    static func text(startedAt: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(startedAt)).rounded(.down)
        // Past an hour "159:28" reads as minutes nobody counts; "2:39:28" reads at a glance.
        return Duration.seconds(elapsed)
            .formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

enum AirBuildChatMenuGroup: Equatable, Sendable, CaseIterable {
    case activity
    case session
    case navigation
    case destructive
}

enum AirBuildChatMenuItem: Equatable, Sendable {
    case agentTerminal
    case openTerminal
    case changes
    case progress
    case newAgent
    case model
    case permission
    case goTo
    case rename
    case worktreeDetails
    case close
}

/// The four system-menu groups. Optional actions hide without moving the groups.
enum AirBuildChatMenuPolicy {
    static func items(in group: AirBuildChatMenuGroup) -> [AirBuildChatMenuItem] {
        switch group {
        case .activity:
            [.agentTerminal, .openTerminal, .changes, .progress]
        case .session:
            [.model, .permission, .newAgent]
        case .navigation:
            [.goTo, .rename, .worktreeDetails]
        case .destructive:
            [.close]
        }
    }
}

/// The AirBuild chat chrome: navigation and context on the top line, every
/// session action in one system menu, and no control over the conversation.
struct AirBuildChatHeader: View {
    static let height: CGFloat = 68

    enum Mode {
        /// Back, the project and More on the top line.
        case full
        /// Only the project and the bell: Back and More are in the system's side bar.
        case titleOnly
        /// Only More, for the system's side bar, with the dialogs its items raise.
        case barMore
    }

    let project: ArcProjectGroup.Project
    let status: AgentStatus
    let isHostConnected: Bool
    var onBack: (() -> Void)?
    var onToggleSidebar: (() -> Void)?
    var waitingAgents: [ConsoleAgent] = []
    var onSelectWaiting: (ConsoleAgent.ID) -> Void = { _ in }
    let onOpenTerminal: () -> Void
    var additionalActions: [AgentDetailHeaderAction] = []
    var onShowChanges: (() -> Void)?
    var changesSummary: String?
    var onRename: (() -> Void)?
    let onShowProject: () -> Void
    let actions: AgentComposerActions
    let onTogglePanel: () -> Void
    var sessionSettings: AgentSessionSettings?
    var sessionControls: AgentSessionControls?
    var mode: Mode = .full
    @State private var confirmsBypass = false

    private var lamp: AirBuildStatusLamp {
        AirBuildStatusLamp(status: status, isHostConnected: isHostConnected)
    }

    private var projectLabel: some View {
        VStack(spacing: 2) {
            AirBuildProjectIcon(project: project, size: 40)
            HStack(spacing: 5) {
                AirBuildStatusLampView(lamp: lamp)
                Text(verbatim: project.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(uiColor: .systemGray4).opacity(0.92), in: Capsule())
        }
        .frame(maxWidth: 150)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: project.label))
        .accessibilityValue(lamp.accessibilityLabel)
    }

    var body: some View {
        switch mode {
        case .barMore: withDialogs(moreMenuInBar)
        case .titleOnly: topLine
        case .full: withDialogs(topLine)
        }
    }

    private var topLine: some View {
        ZStack(alignment: .top) {
            projectLabel.frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                if mode == .full, let onBack {
                    iconButton("chevron.left", label: "Back", action: onBack)
                }
                if onToggleSidebar != nil {
                    // The split view's own Show Sidebar sits here; drawing a second
                    // one stacked two buttons (unfolded portrait, 2026-11-12).
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
                if !waitingAgents.isEmpty { waitingMenu }
                Spacer(minLength: 0)
                if mode == .full { moreMenu }
            }
        }
        .frame(height: Self.height, alignment: .top)
    }

    /// Close and Bypass confirmations, on whichever instance shows More.
    private func withDialogs(_ content: some View) -> some View {
        content
        .agentCloseConfirmation(actions.closeConfirmation)
        .confirmationDialog(
            "Skip every permission prompt?", isPresented: $confirmsBypass, titleVisibility: .visible
        ) {
            Button("Bypass Permissions", role: .destructive) {
                sessionControls?.setPermissionMode("bypassPermissions")
            }
        } message: {
            Text("The Agent runs every tool without asking until you switch back.")
        }
    }

    private func iconButton(
        _ systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .headerGlass(in: .circle)
        .accessibilityLabel(label)
    }

    private var waitingMenu: some View {
        Menu {
            ForEach(waitingAgents) { @Sendable agent in
                MainActorContent {
                    Button {
                        onSelectWaiting(agent.id)
                    } label: {
                        HStack(spacing: 9) {
                            AirBuildSessionAvatar(agent: agent, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: agent.agent.displayName)
                                Text(verbatim: agent.workspaceLabel ?? agent.agent.workspaceID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityLabel(Text(verbatim: "\(agent.agent.displayName), \(String(localized: "Waiting on You"))"))
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bell")
                Text(verbatim: "\(waitingAgents.count)")
                    .monospacedDigit()
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 13)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .headerGlass(in: .capsule)
        .accessibilityLabel("Waiting on You")
        .accessibilityValue(Text(verbatim: "\(waitingAgents.count)"))
    }

    private var moreMenu: some View {
        moreMenuButton
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .headerGlass(in: .circle)
            .accessibilityLabel("More")
    }

    /// The bar draws its own glass and sizing; a plain label lets it.
    private var moreMenuInBar: some View {
        Menu {
            moreMenuItems
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private var moreMenuButton: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        ForEach(AirBuildChatMenuGroup.allCases, id: \.self) { @Sendable group in
            MainActorContent {
                Section {
                    ForEach(AirBuildChatMenuPolicy.items(in: group), id: \.self) { @Sendable item in
                        MainActorContent { row(for: item) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: AirBuildChatMenuItem) -> some View {
        switch item {
        case .agentTerminal:
            Button("Open Terminal", systemImage: "terminal", action: onOpenTerminal)
        case .openTerminal:
            composerButton(.openTerminal, title: String(localized: "Open Shell Terminal"), systemImage: "macwindow.badge.plus")
        case .changes:
            if let onShowChanges {
                Button(action: onShowChanges) {
                    menuLabel("Changes", systemImage: "plus.forwardslash.minus", value: changesSummary)
                }
            }
        case .progress:
            Button("Progress", systemImage: "square.grid.2x2", action: onTogglePanel)
        case .newAgent:
            composerButton(.newAgent)
        case .model:
            if let sessionSettings, let sessionControls {
                modelMenu(settings: sessionSettings, controls: sessionControls)
            }
        case .permission:
            if let sessionSettings, let sessionControls {
                permissionMenu(settings: sessionSettings, controls: sessionControls)
            }
        case .goTo:
            Menu {
                Button("Show Project", systemImage: "folder", action: onShowProject)
                ForEach(additionalActions) { @Sendable action in
                    MainActorContent {
                        Button(action.title, systemImage: action.systemImage, action: action.perform)
                    }
                }
            } label: {
                menuLabel("Go to", systemImage: "rectangle.on.rectangle", value: nil)
            }
        case .rename:
            // One entry for the three renames; Skills and Snippets edit the draft, so they live under Composer's +.
            Menu {
                if let onRename {
                    Button("Title", systemImage: "pencil", action: onRename)
                }
                composerButton(.renameAgent)
                composerButton(.renameWorkspace)
            } label: {
                menuLabel("Rename", systemImage: "pencil", value: nil)
            }
        case .worktreeDetails:
            composerButton(.worktreeDetails)
        case .close:
            composerButton(.closeAgent)
        }
    }

    @ViewBuilder
    private func composerButton(
        _ item: AgentActionMenuItem, title: String? = nil, systemImage: String? = nil
    ) -> some View {
        if AgentActionMenuPolicy.isVisible(item, actions: actions) {
            Button(role: item.role) {
                AgentActionMenuPolicy.perform(item, actions: actions)
            } label: {
                if let systemImage {
                    Label(title ?? AgentActionMenuPolicy.title(of: item, actions: actions), systemImage: systemImage)
                } else {
                    Label(title ?? AgentActionMenuPolicy.title(of: item, actions: actions), glyph: item.glyph)
                }
            }
            .disabled(!AgentActionMenuPolicy.isEnabled(item, actions: actions))
        }
    }

    private func menuLabel(
        _ title: LocalizedStringKey, systemImage: String, value: String?
    ) -> some View {
        LabeledContent {
            if let value {
                Text(verbatim: value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func modelMenu(settings: AgentSessionSettings, controls: AgentSessionControls) -> some View {
        Menu {
            ForEach(AgentModelPage.pages(settings.modelChoices), id: \.name) { @Sendable page in
                MainActorContent {
                    Section(page.name) {
                        ForEach(page.rows, id: \.id) { @Sendable model in
                            MainActorContent {
                                Button {
                                    controls.setModel(model.id)
                                } label: {
                                    HStack {
                                        Text(verbatim: model.rowTitle)
                                        if AgentSessionSettings.model(settings.model, is: model.id) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .disabled(!controls.isEnabled)
                            }
                        }
                    }
                }
            }
            Section("Effort") {
                ForEach(AgentSessionSettings.effortChoices, id: \.self) { @Sendable effort in
                    MainActorContent {
                        Button {
                            controls.setEffort(effort)
                        } label: {
                            HStack {
                                Text(verbatim: AgentModelGrid.effortTitle(effort))
                                if settings.effort == effort { Image(systemName: "checkmark") }
                            }
                            .disabled(!controls.isEnabled)
                        }
                    }
                }
            }
        } label: {
            menuLabel("Model", systemImage: "sparkles", value: settings.modelLine)
        }
        .accessibilityLabel("Agent settings")
        .accessibilityValue(settings.modelLine ?? String(localized: "Model"))
    }

    private func permissionMenu(settings: AgentSessionSettings, controls: AgentSessionControls) -> some View {
        Menu {
            ForEach(
                AgentSessionSettings.permissionChoices.filter {
                    $0 != "bypassPermissions" || controls.allowsBypassPermissions
                }, id: \.self
            ) { @Sendable mode in
                MainActorContent {
                    Button {
                        if mode == "bypassPermissions" {
                            confirmsBypass = true
                        } else {
                            controls.setPermissionMode(mode)
                        }
                    } label: {
                        HStack {
                            Text(verbatim: AgentSessionSettings.permissionTitle(mode))
                            if settings.permissionMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            menuLabel(
                "Permission", systemImage: "checkmark.shield",
                value: permissionValue(settings: settings, controls: controls))
        }
        .disabled(!controls.isEnabled)
        .accessibilityLabel("Permission mode")
    }

    private func permissionValue(
        settings: AgentSessionSettings, controls: AgentSessionControls
    ) -> String {
        let current = AgentSessionSettings.permissionTitle(settings.permissionMode ?? "")
        guard controls.isSwitchingPermissionMode else { return current }
        return String(localized: "Switching from \(current)")
    }
}

struct AirBuildStatusLampView: View {
    let lamp: AirBuildStatusLamp
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        Circle()
            .fill(lamp.isHollow ? Color.clear : lamp.color)
            .overlay(Circle().stroke(lamp.color, lineWidth: lamp.isHollow ? 1.5 : 0))
            .frame(width: size, height: size)
            // Scoped to scale and opacity: an animation by value also repeated
            // the lamp's move into place forever, so it hopped out of its pill.
            .animation(
                reduceMotion || lamp != .working
                    ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
            ) { dot in
                dot
                    .scaleEffect(breathing ? 1.16 : 1)
                    .opacity(breathing ? 0.58 : 1)
            }
            .accessibilityLabel(lamp.accessibilityLabel)
            .onAppear { breathing = lamp == .working && !reduceMotion }
            .onDisappear { breathing = false }
            .onChange(of: lamp) { _, next in breathing = next == .working && !reduceMotion }
            .onChange(of: reduceMotion) { _, reduce in
                breathing = lamp == .working && !reduce
            }
    }
}

struct AirBuildRunningCapsule: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                AirBuildStatusLampView(lamp: .working, size: 6)
                Text("Running")
                Text(verbatim: "· \(AirBuildRunningClock.text(startedAt: startedAt, now: context.date))")
            }
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }
}
