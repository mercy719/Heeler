import SwiftUI

/// Controls over an Agent or terminal. On a horizontal screen separate glass
/// pieces float over the terminal: Back at the leading end, the Agent's title
/// beside it, and at the far end a More menu that stays put. On an iPhone Duo
/// vertical bar, native toolbar items hold Back, the surface switch and More,
/// leaving only the optional title over the content.
///
/// Back is the way out of a detail pushed over the list, on an iPhone or in
/// a compact iPad window, which the edge swipe alone never showed (#396).
/// Beside an iPad's sidebar there is nothing to go back to, so the header
/// keeps only its menu.
///
/// The menu holds the screen's actions and the item that folds or unfolds
/// the header, each titled in one word. Actions are plain values rather than
/// views, so a screen can leave out the ones it cannot offer.
///
/// An Agent that has Chat also shows a button for the surface it is not
/// showing, Chat or its terminal, sharing the menu's capsule on a horizontal
/// header and joining the native side bar on iPhone Duo, so the other surface
/// stays one tap away while the title is folded.
///
/// Level with a horizontal detail column bar, the menu and surface button
/// move into it as `AgentDetailHeaderBarControls`: the bar sits above the
/// screen and takes every touch across its row, so controls drawn under it
/// could not be pressed.
struct AgentDetailHeader: View {
    static let controlSize: CGFloat = 44
    /// How much of the glass shows, the rest letting output through.
    static let glassOpacity: Double = 0.9
    /// Buttons sharing a capsule sit closer than standalone ones.
    static let capsuleButtonWidth: CGFloat = 36
    static let capsuleInset: CGFloat = (controlSize - capsuleButtonWidth) / 2

    /// Where the header's top edge sits. Beside an iPad's sidebar it lines
    /// up with the detail column's bar, level with the sidebar's buttons and
    /// Show Sidebar, even while output starts below the bar; elsewhere it
    /// rides just below the output's top. A bar's buttons fill a control's
    /// height from its top edge, with the bar's remaining height below
    /// them, so the header starts at that edge rather than centering.
    static func top(outputTop: CGFloat, barRow: NavigationBarBand?) -> CGFloat {
        guard let barRow, levelsWithBar(barRow) else { return outputTop + 4 }
        return barRow.top
    }

    /// Whether the header shares the bar's row, which then holds the
    /// header's trailing controls.
    static func levelsWithBar(_ barRow: NavigationBarBand?) -> Bool {
        guard let barRow else { return false }
        return barRow.bottom - barRow.top >= controlSize
    }

    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    /// Nil where the detail stands beside the list rather than over it.
    let onBack: (() -> Void)?
    var actions: [AgentDetailHeaderAction] = []
    /// Nil for a screen with one surface, such as a shell terminal.
    var surfaceSwitch: AgentDetailSurfaceSwitch?
    /// Nil for a screen that names nothing, such as a shell terminal.
    var title: AgentDetailHeaderTitle?
    /// Temporarily replaces the task title and reveals it even while folded,
    /// without changing the user's expansion preference or the other controls.
    var statusTitle: String?
    /// Chat's confirmed model and effort sit beside the launch folder.
    var sessionSettings: AgentSessionSettings?
    /// The whole title opens the native model menu when switching is supported.
    var sessionControls: AgentSessionControls?
    /// Where this header's actions live. A horizontal bar keeps their room
    /// clear so the expanded title stays centred; a vertical bar stands
    /// outside the content and needs no horizontal reservation.
    var controlPlacement = AgentDetailHeaderControlPlacement.floating

    /// The width of the trailing controls, measured so the leading slot can match it.
    @State private var trailingWidth: CGFloat = 0
    @State private var showsModelGrid = false
    @State private var modelSelectionFeedback = 0
    /// The trailing safe inset, which a floating tab bar takes. The row starts
    /// this far in too, so the title centres on the content, not the row.
    @State private var trailingSafeInset: CGFloat = 0

    /// Both side slots are this wide while expanded, so the title sits at the
    /// header's centre rather than between controls of different widths.
    private var slotWidth: CGFloat {
        controlPlacement == .horizontalToolbar
            ? barControlsWidth : max(trailingWidth, Self.controlSize)
    }

    /// As wide as `AgentDetailHeaderTrailingControls` draws in the bar.
    private var barControlsWidth: CGFloat {
        guard surfaceSwitch != nil else { return Self.controlSize }
        return 2 * Self.capsuleButtonWidth + 2 * Self.capsuleInset
    }

    private var showsTitle: Bool { isExpanded || statusTitle != nil }

    private var trailingSlotWidth: CGFloat? {
        showsTitle && controlPlacement.reservesHorizontalControlWidth
            ? slotWidth : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leadingSlot
            if showsTitle, let title {
                titlePill(title)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Spacer(minLength: 0)
            }
            trailingControls
                .frame(width: trailingSlotWidth, alignment: .trailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.trailing } action: {
            trailingSafeInset = $0
        }
        .padding(.leading, trailingSafeInset)
        .foregroundStyle(palette.foreground)
    }

    /// Back while expanded, on a slot as wide as the trailing controls.
    /// A folded header reserves an empty slot only while showing recovery.
    @ViewBuilder
    private var leadingSlot: some View {
        if controlPlacement != .verticalToolbar {
            if isExpanded {
                if let onBack {
                    AgentDetailHeaderButton("Back", systemImage: "chevron.left", action: onBack)
                        .headerGlass(in: .circle)
                        .frame(width: slotWidth, alignment: .leading)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Color.clear.frame(width: slotWidth)
                }
            } else if showsTitle {
                Color.clear.frame(width: slotWidth)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch controlPlacement {
        case .horizontalToolbar:
            if showsTitle {
                Color.clear.frame(width: slotWidth, height: Self.controlSize)
            }
        case .floating:
            AgentDetailHeaderTrailingControls(
                palette: palette, isExpanded: $isExpanded, actions: actions,
                surfaceSwitch: surfaceSwitch)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                trailingWidth = $0
            }
        case .verticalToolbar:
            EmptyView()
        }
    }

    /// The grid switches nothing while the title shows a status in place of the name.
    private func gridControls(_ controls: AgentSessionControls) -> AgentSessionControls {
        var controls = controls
        controls.isEnabled = controls.isEnabled && statusTitle == nil
        return controls
    }

    @ViewBuilder
    private func titlePill(_ title: AgentDetailHeaderTitle) -> some View {
        if let controls = sessionControls, let settings = sessionSettings {
            Button {
                showsModelGrid = true
            } label: {
                titleLabel(title)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsModelGrid, arrowEdge: .top) {
                AgentModelGrid(
                    settings: settings, controls: gridControls(controls), isPresented: $showsModelGrid,
                    onSelect: { modelSelectionFeedback += 1 })
                .presentationCompactAdaptation(.popover)
            }
            .sensoryFeedback(.selection, trigger: modelSelectionFeedback)
            .accessibilityLabel("Agent settings")
            .accessibilityValue(sessionSettings?.modelLine ?? String(localized: "Model"))
            .accessibilityHint("Select model and effort for \(title.title)")
            .accessibilityIdentifier("agent-header-model")
        } else {
            titleLabel(title)
        }
    }

    /// Fills the room between equal side slots. Long models truncate rather
    /// than pushing Back or More outside the screen.
    private func titleLabel(_ title: AgentDetailHeaderTitle) -> some View {
        let mark = AgentKindMark(kind: title.kind)
        // Claude's square asset has vertical padding; match the folder's visible height.
        let markSize: CGFloat = mark.artwork == AgentKindMark.artwork(for: .claude) ? 18 : 12
        return VStack(spacing: 1) {
            HStack(spacing: 6) {
                if statusTitle != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(palette.foreground)
                        .accessibilityHidden(true)
                }
                Text(statusTitle ?? title.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Group {
                    if let artwork = mark.artwork {
                        Image(artwork.template)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text(verbatim: mark.monogram)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                }
                .frame(width: markSize, height: markSize)
                .frame(height: 12)
                .accessibilityHidden(true)
                if let folder = title.folder {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Image(systemName: "folder")
                        .accessibilityHidden(true)
                    Text(verbatim: folder)
                        .truncationMode(.middle)
                }
                if let model = sessionSettings?.modelLine {
                    if title.folder != nil {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: model)
                        .layoutPriority(1)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.foreground.opacity(0.6))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: Self.controlSize, maxHeight: Self.controlSize)
        .headerGlass(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where the detail header's actions are drawn. Vertical wins when a regular
/// detail also has a measured horizontal bar: the system has already moved
/// that bar to the display's side.
enum AgentDetailHeaderControlPlacement: Equatable {
    case floating
    case horizontalToolbar
    case verticalToolbar

    init(headerSharesBar: Bool, usesVerticalToolbar: Bool) {
        if usesVerticalToolbar {
            self = .verticalToolbar
        } else if headerSharesBar {
            self = .horizontalToolbar
        } else {
            self = .floating
        }
    }

    var reservesHorizontalControlWidth: Bool { self != .verticalToolbar }
}

/// `AgentDetailHeader`'s trailing controls as an item of a horizontal detail
/// column bar, beside Show Sidebar. The item draws the header's own capsule,
/// so it keeps the floating header's size rather than the bar's wider item
/// spacing.
struct AgentDetailHeaderBarControls: ToolbarContent {
    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    var actions: [AgentDetailHeaderAction] = []
    var surfaceSwitch: AgentDetailSurfaceSwitch?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AgentDetailHeaderTrailingControls(
                palette: palette, isExpanded: $isExpanded, actions: actions,
                surfaceSwitch: surfaceSwitch)
        }
        .toolbarItemBackground(.hidden)
    }
}

/// The horizontal header's far end on its own glass: the surface button and
/// the More menu sharing a capsule, or the menu alone on a circle.
struct AgentDetailHeaderTrailingControls: View {
    let palette: TerminalThemePalette
    @Binding var isExpanded: Bool
    let actions: [AgentDetailHeaderAction]
    let surfaceSwitch: AgentDetailSurfaceSwitch?

    /// A bar button's glyph size and weight, as Show Sidebar beside these
    /// draws it, so the symbols keep the balance SF Symbols gives them.
    static let glyphFont = Font.system(size: 17)

    var body: some View {
        if let surfaceSwitch {
            HStack(spacing: 0) {
                AgentDetailSurfaceButton(control: surfaceSwitch)
                    .frame(
                        width: AgentDetailHeader.capsuleButtonWidth,
                        height: AgentDetailHeader.controlSize)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                moreMenu(width: AgentDetailHeader.capsuleButtonWidth)
            }
            .padding(.horizontal, AgentDetailHeader.capsuleInset)
            .fixedSize()
            .headerGlass(in: .capsule)
            .foregroundStyle(palette.foreground)
        } else {
            moreMenu(width: AgentDetailHeader.controlSize)
                .headerGlass(in: .circle)
        }
    }

    /// Stays at the far end in both states: the screen's actions, then the
    /// item that folds or unfolds the header.
    private func moreMenu(width: CGFloat) -> some View {
        Menu {
            AgentDetailHeaderMenuItems(actions: actions, isExpanded: $isExpanded)
        } label: {
            Image(systemName: "ellipsis")
                .font(Self.glyphFont)
                .foregroundStyle(palette.foreground)
                .frame(width: width, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        // Plain, or a bar pads the menu as one of its own buttons.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("More")
    }
}

/// The one-tap swap to the Agent surface not showing. Its Label gives a
/// native toolbar both a symbol and the title it needs for expanded forms;
/// the horizontal custom capsule applies its own frame and plain style.
private struct AgentDetailSurfaceButton: View {
    let control: AgentDetailSurfaceSwitch

    var body: some View {
        let target = control.other
        Button {
            control.select(target)
        } label: {
            Label {
                Text(target.showTitle)
            } icon: {
                AgentDetailSurfaceGlyph(glyph: target.showGlyph)
            }
            .labelStyle(.iconOnly)
        }
        .accessibilityHint(target.showAccessibilityHint)
    }
}

/// A surface's existing symbol, shared by the custom horizontal capsule and
/// the native vertical toolbar item.
private struct AgentDetailSurfaceGlyph: View {
    let glyph: AgentGlyph

    @ViewBuilder
    var body: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(AgentDetailHeaderTrailingControls.glyphFont)
        case .codeBubble:
            // Flattened because a native toolbar extracts a Label's symbol
            // representation and would discard an overlay on an SF Symbol.
            Image(uiImage: CodeBubbleGlyph.image(pointSize: 17))
        }
    }
}

/// The More menu's items: the screen's actions, then the item that folds
/// or unfolds the header.
private struct AgentDetailHeaderMenuItems: View {
    let actions: [AgentDetailHeaderAction]
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(actions) { @Sendable action in
            MainActorContent {
                Button(action.title, systemImage: action.systemImage, action: action.perform)
            }
        }
        Button(
            isExpanded ? "Collapse" : "Expand",
            // A window's top bar, which is what this shows and hides: put
            // away while it is out, filled in while it is folded.
            systemImage: isExpanded
                ? "menubar.arrow.up.rectangle" : "inset.filled.topthird.rectangle"
        ) {
            withAnimation(reduceMotion ? nil : .snappy) {
                isExpanded.toggle()
            }
        }
    }
}

enum AirBuildVerticalBarItem: String, CaseIterable, Sendable {
    case workspace
    case terminal
    case account
    case settings

    var systemImage: String {
        switch self {
        case .workspace: "square.grid.2x2"
        case .terminal: "terminal"
        case .account: "person.crop.circle"
        case .settings: "gearshape"
        }
    }
}

@MainActor
struct AirBuildGlobalActions {
    let openHosts: () -> Void
    let openSettings: () -> Void
}

#if compiler(>=6.4)
@available(iOS 27.1, *)
private struct AgentDetailHeaderVerticalBarControls: ToolbarContent {
    @Binding var isExpanded: Bool
    let actions: [AgentDetailHeaderAction]
    let surfaceSwitch: AgentDetailSurfaceSwitch?
    let onBack: (() -> Void)?

    var body: some ToolbarContent {
        if let onBack {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back", systemImage: "chevron.left", action: onBack)
            }
            .visibilityPriority(.high)
        }
        if let surfaceSwitch {
            ToolbarItem(placement: .primaryAction) {
                AgentDetailSurfaceButton(control: surfaceSwitch)
            }
            // The code bubble is a small custom symbol which supports the
            // vertical representation even though SwiftUI cannot infer it.
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
        }
        ToolbarOverflowMenu {
            AgentDetailHeaderMenuItems(actions: actions, isExpanded: $isExpanded)
        }
    }
}

@available(iOS 27.1, *)
private struct AirBuildFoldedBarControls<More: View>: ToolbarContent {
    let onBack: () -> Void
    let surfaceSwitch: AgentDetailSurfaceSwitch?
    let more: More

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Back", systemImage: "chevron.left", action: onBack)
                .tint(nil)
        }
        .visibilityPriority(.high)
        if let surfaceSwitch {
            ToolbarItem(placement: .primaryAction) {
                AgentDetailSurfaceButton(control: surfaceSwitch)
                    .tint(nil)
            }
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
        }
        ToolbarItem(placement: .primaryAction) { more.tint(nil) }
            .axisBehavior(.verticalPreferred)
    }
}

@available(iOS 27.1, *)
private struct AirBuildGlobalBarControls: ToolbarContent {
    let surfaceSwitch: AgentDetailSurfaceSwitch?
    @Binding var workspacePresented: Bool
    let actions: AirBuildGlobalActions
    /// The terminal's own More; Chat passes its menu as `more` instead.
    var moreActions: [AgentDetailHeaderAction] = []
    var isMoreExpanded: Binding<Bool> = .constant(false)
    var more: AnyView?

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Workspace", systemImage: AirBuildVerticalBarItem.workspace.systemImage) {
                workspacePresented.toggle()
            }
            .tint(workspacePresented ? Color.accentColor : nil)
        }
        .axisBehavior(.verticalPreferred)
        .visibilityPriority(.high)
        if let surfaceSwitch {
            ToolbarItem(placement: .primaryAction) {
                AgentDetailSurfaceButton(control: surfaceSwitch)
                    .tint(nil)
            }
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
        }
        // Hosts above Settings, as on the home screen's bar.
        ToolbarItem(placement: .primaryAction) {
            Button("Hosts", systemImage: "desktopcomputer", action: actions.openHosts)
                .tint(nil)
        }
        .axisBehavior(.verticalPreferred)
        ToolbarItem(placement: .primaryAction) {
            Button(
                "Settings", systemImage: AirBuildVerticalBarItem.settings.systemImage,
                action: actions.openSettings)
            .tint(nil)
        }
        .axisBehavior(.verticalPreferred)
        // More last on both surfaces, so a swap keeps every button where it was.
        if let more {
            ToolbarItem(placement: .primaryAction) { more.tint(nil) }
                .axisBehavior(.verticalPreferred)
        } else if !moreActions.isEmpty {
            ToolbarOverflowMenu {
                AgentDetailHeaderMenuItems(actions: moreActions, isExpanded: isMoreExpanded)
            }
        }
    }
}
#endif

#if compiler(>=6.4)
/// Folded, the home screen's Add, account and Settings live in the system's
/// side bar, as AirBuild's do, instead of three corners of the list.
@available(iOS 27.1, *)
private struct AirBuildHomeBarControls: ToolbarContent {
    let onNewAgent: (() -> Void)?
    let actions: AirBuildGlobalActions

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let onNewAgent {
                    Button("New Agent", systemImage: "plus", action: onNewAgent)
                }
                Button("Connect Computer", systemImage: "desktopcomputer", action: actions.openHosts)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .tint(nil)
        }
        .axisBehavior(.verticalPreferred)
        ToolbarSpacer(.flexible, placement: .primaryAction)
        // The computers and their latency, one tap from home.
        ToolbarItem(placement: .primaryAction) {
            Button("Hosts", systemImage: "desktopcomputer", action: actions.openHosts)
                .tint(nil)
        }
        .axisBehavior(.verticalPreferred)
        ToolbarItem(placement: .primaryAction) {
            Button(
                "Settings", systemImage: AirBuildVerticalBarItem.settings.systemImage,
                action: actions.openSettings)
            .tint(nil)
        }
        .axisBehavior(.verticalPreferred)
    }
}
#endif

/// The task title and launch folder; Chat adds its live model separately.
struct AgentDetailHeaderTitle: Equatable {
    let title: String
    let kind: String
    let directory: String?

    var folder: String? { directory.map(RemoteHostPath.lastComponent(of:)) }
}

extension AgentDetailHeaderTitle {
    /// The task title as the Console list shows it, the harness's kind for
    /// its mark, and the reported launch directory. Keep the home folder's
    /// name rather than shortening it to `~`.
    init(_ agent: ConsoleAgent) {
        self.init(
            title: AgentTerminalView.displayTitle(for: agent),
            kind: agent.agent.kind,
            directory: agent.agent.cwd.isEmpty ? nil : agent.agent.cwd)
    }
}

/// The surface an Agent detail shows, and how to swap it, for
/// `AgentDetailHeader`'s surface button. Main-actor isolated, and so
/// Sendable, for the same reason as `AgentDetailHeaderAction`.
@MainActor
struct AgentDetailSurfaceSwitch {
    let current: AgentDetailSurface
    let select: (AgentDetailSurface) -> Void

    /// The surface the header's button brings up.
    var other: AgentDetailSurface {
        switch current {
        case .chat: .terminal
        case .terminal: .chat
        }
    }
}

/// One of the actions in `AgentDetailHeader`'s More menu. Isolated to the
/// main actor, which makes it Sendable: the menu's `ForEach` content is
/// `@Sendable` and hands each action to `MainActorContent` (#471).
@MainActor
struct AgentDetailHeaderAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let perform: () -> Void

    nonisolated var id: String { systemImage }
}

/// An icon button inside `AgentDetailHeader`. It has no surface of its own:
/// the header puts it on a glass circle.
struct AgentDetailHeaderButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: AgentDetailHeader.controlSize, height: AgentDetailHeader.controlSize)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension View {
    /// Puts `AgentDetailHeader`'s controls in their resolved bar. A horizontal
    /// bar keeps the existing custom capsule; a vertical bar uses native
    /// toolbar items and the system overflow menu.
    ///
    /// `onBack` puts Back in the bar as well, for a screen whose header
    /// leaves it out. On iPhone Duo the system draws the bar along the
    /// display's side, Back first, where the floating one would sit at the
    /// top across the screen from the bar.
    func detailHeaderBarControls(
        _ placement: AgentDetailHeaderControlPlacement,
        palette: TerminalThemePalette,
        isExpanded: Binding<Bool>,
        actions: [AgentDetailHeaderAction],
        surfaceSwitch: AgentDetailSurfaceSwitch? = nil,
        onBack: (() -> Void)? = nil,
        airBuildWorkspace: Binding<Bool>? = nil,
        airBuildActions: AirBuildGlobalActions? = nil
    ) -> some View {
        toolbar {
            #if compiler(>=6.4)
            if #available(iOS 27.1, *), placement == .verticalToolbar {
                if let airBuildWorkspace, let airBuildActions {
                    AirBuildGlobalBarControls(
                        surfaceSwitch: surfaceSwitch,
                        workspacePresented: airBuildWorkspace,
                        actions: airBuildActions,
                        moreActions: actions,
                        isMoreExpanded: isExpanded)
                } else {
                    AgentDetailHeaderVerticalBarControls(
                        isExpanded: isExpanded, actions: actions,
                        surfaceSwitch: surfaceSwitch, onBack: onBack)
                }
            } else if placement == .horizontalToolbar {
                AgentDetailHeaderBarControls(
                    palette: palette, isExpanded: isExpanded, actions: actions,
                    surfaceSwitch: surfaceSwitch)
            }
            #else
            if placement == .horizontalToolbar {
                AgentDetailHeaderBarControls(
                    palette: palette, isExpanded: isExpanded, actions: actions,
                    surfaceSwitch: surfaceSwitch)
            }
            #endif
        }
    }

    /// Folded, Chat's Back, terminal switch and More go to the system's side bar
    /// (the outer display's otherwise empty right column), leaving the top line
    /// to the project alone.
    func airBuildFoldedBarControls<More: View>(
        isVisible: Bool,
        onBack: @escaping () -> Void,
        surfaceSwitch: AgentDetailSurfaceSwitch?,
        @ViewBuilder more: () -> More
    ) -> some View {
        let more = more()
        return toolbar {
            #if compiler(>=6.4)
            if #available(iOS 27.1, *), isVisible {
                AirBuildFoldedBarControls(onBack: onBack, surfaceSwitch: surfaceSwitch, more: more)
            }
            #endif
        }
    }

    /// Arc's global side bar, without adding the terminal header's horizontal controls to Chat.
    func airBuildGlobalBarControls(
        isVisible: Bool,
        surfaceSwitch: AgentDetailSurfaceSwitch?,
        workspace: Binding<Bool>?,
        actions: AirBuildGlobalActions?,
        more: AnyView? = nil
    ) -> some View {
        toolbar {
            #if compiler(>=6.4)
            if #available(iOS 27.1, *), isVisible,
                let workspace, let actions
            {
                AirBuildGlobalBarControls(
                    surfaceSwitch: surfaceSwitch,
                    workspacePresented: workspace,
                    actions: actions,
                    more: more)
            }
            #endif
        }
    }

    /// The home screen's side-bar controls (`AirBuildHomeBarControls`).
    func airBuildHomeBarControls(
        isVisible: Bool, onNewAgent: (() -> Void)?, actions: AirBuildGlobalActions
    ) -> some View {
        toolbar {
            #if compiler(>=6.4)
            if #available(iOS 27.1, *), isVisible {
                AirBuildHomeBarControls(onNewAgent: onNewAgent, actions: actions)
            }
            #endif
        }
    }

    /// Agent and terminal details are task-oriented: when their native side
    /// controls compete with tabs, keep the controls and compact the tabs.
    @ViewBuilder
    func prioritizesVerticalDetailToolbar() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Publishes `usesVerticalToolbar` for the screens below, from the
    /// system's vertical bar edge where the SDK and system have one. Behind
    /// a compiler check so Xcode 26 still builds it.
    @ViewBuilder
    func readsVerticalToolbar() -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            modifier(VerticalToolbarReader())
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Liquid Glass where the system has it, a blur before that. The glass
    /// sits behind the icons at part strength, so the output under the
    /// buttons still shows through while the icons stay solid. Chat's
    /// floating buttons share it at their own strength.
    func headerGlass(
        in shape: some Shape, opacity: Double = AgentDetailHeader.glassOpacity
    ) -> some View {
        background {
            Group {
                if #available(iOS 26, *) {
                    Color.clear.glassEffect(.regular, in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .opacity(opacity)
        }
        .contentShape(shape)
    }
}

extension EnvironmentValues {
    /// Whether the system draws this screen's bars along the display's side,
    /// as iPhone Duo does on its outer display and on its inner one in
    /// landscape. A detail's Back, surface switch and More controls then move
    /// from its floating header into the bar.
    @Entry var usesVerticalToolbar = false
    /// Arc's shared workspace overlay and global Host/Settings actions.
    @Entry var airBuildWorkspacePresented: Binding<Bool>? = nil
    @Entry var airBuildGlobalActions: AirBuildGlobalActions? = nil
}

#if compiler(>=6.4)
@available(iOS 27.1, *)
private struct VerticalToolbarReader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var toolbarVerticalEdge

    func body(content: Content) -> some View {
        content.environment(\.usesVerticalToolbar, toolbarVerticalEdge != nil)
    }
}
#endif

/// Hands `usesVerticalToolbar` up to a view that sits above the reader, as the
/// split view's sidebar toolbar does. The edge is the screen's, not the
/// toolbar's contents, so writing it back cannot loop.
struct VerticalToolbarProbe: View {
    @Binding var usesVerticalToolbar: Bool
    @Environment(\.usesVerticalToolbar) private var reads

    var body: some View {
        Color.clear
            .onAppear { usesVerticalToolbar = reads }
            .onChange(of: reads) { _, value in usesVerticalToolbar = value }
            .accessibilityHidden(true)
    }
}
