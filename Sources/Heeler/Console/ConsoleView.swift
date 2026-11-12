import SwiftUI

/// The Console home screen (#8): a bottom tab bar over Agents across every
/// Host (flat or grouped by Host or Workspace), their ordinary shell Terminals
/// grouped by Workspace or Host (#316), and one Search across both. Host
/// management (#14) and Settings are tabs too. An iPad beside its sidebar
/// has no tab bar: the sidebar switches lists at its top and opens Hosts
/// and Settings as sheets from its bottom. Every tab is its own
/// split view, but they share one selection and only the selected tab
/// mounts the detail column, so a terminal is never attached twice. In
/// regular width a list tab swaps its own last selection back in when it
/// returns.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let inputMode: AgentInputModeSettings
    let detailSurface: AgentDetailSurfaceSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    /// Owns the navigation path (#74): user taps and notification deep links
    /// drive the same stack.
    @Bindable var notificationRouter: AgentNotificationRouter
    /// Announces foreground Blocked/Done transitions in-app (#77).
    let bannerStore: AgentNotificationBannerStore
    /// Per-Host Live Activity start/update/end and the Settings toggle.
    let liveActivities: HostLiveActivityCoordinator
    /// Scene phase widened by the background grace period; an Attach screen
    /// pauses its work on real suspensions only.
    let activity: AppActivityCoordinator
    /// A shell terminal chosen from the Terminals tab or Agent detail's
    /// drawer. It shares the detail column with the router's Agent path;
    /// only one is ever set.
    @State private var selectedTerminal: ConsoleTerminal?
    @State private var titleRename: AgentTitleRenameStore?
    /// Agents or Terminals, per window; empty until this window picks one.
    /// Waiting and Progress are tracked apart so neither is the tab a window
    /// comes back to.
    @SceneStorage("console.list-tab") private var sceneListTab = ""
    /// The last list tab any window picked: where a new window, or a
    /// relaunch that restored no scene state, starts.
    @AppStorage("console.last-list-tab") private var lastListTab: ConsoleTab = .agents
    /// The list tab this window shows, once it has picked one here. The
    /// tab bar reads it back within the tap that set it, and the two
    /// storages above can still answer with the old tab then: the bar
    /// reverted to it and then jumped forward again.
    @State private var listTab: ConsoleTab?
    /// Waiting or Progress while the tab bar shows one; nil while a list
    /// tab is on screen. Neither is a tab a window comes back to.
    @State private var pageTab: ConsoleTab?
    /// The Progress tab's stack, where Usage pushes.
    @State private var progressPath: [ArcProgressDestination] = []
    /// Folded on iPhone Duo: the sidebar is the home screen, beside the system's side bar.
    @State private var sidebarHasVerticalBar = false
    /// Collapsed beside the side bar; in landscape the detail's own side bar carries these.
    private var foldedHome: Bool { sidebarHasVerticalBar && !usesSidebarNavigation }
    /// Progress beside a sidebar, which has no tab bar: a sheet with its
    /// own stack.
    @State private var isShowingProgressSheet = false
    @State private var progressSheetPath: [ArcProgressDestination] = []
    /// Usage asked for from the Hosts or Settings sheet beside a sidebar:
    /// Progress waits for that sheet to close, as a sheet asked for while
    /// another one leaves never shows.
    @State private var opensProgressSheetAfterDismiss = false
    /// Which scope the Progress page opens on.
    @State private var progressScope = ArcProgressScope.project
    /// The Host the Usage page reads; nil reads every Host.
    @State private var usageScopeHostID: Host.ID?
    @State private var usageMetric = AgentUsageMetric.cost
    /// A Usage Limits widget's tap, until the Usage page shows them.
    @State private var usageLimitsRequested = false
    /// Hosts and Settings, in every width: sheets the list's toolbar presents.
    @State private var isShowingHostsSheet = false
    @State private var isShowingSettingsSheet = false
    @State private var isShowingAllArcProjects = false
    /// The project tile whose long press asked to rename its Workspace.
    @State private var arcRenamingProject: ArcProjectGroup.Project?
    @State private var arcNewTerminalFailure: String?
    /// A Host added in Settings, or one whose Host Helper Settings opens,
    /// waits for that sheet to close before the Hosts sheet can present
    /// onboarding and its trust alert.
    @State private var pendingSettingsHost: (id: Host.ID, opensHostHelper: Bool)?
    @State private var isShowingListMenu = false
    /// Where the sidebar's title sits in the window, for its choices to
    /// point at.
    @State private var listMenuTitleFrame: CGRect?
    @State private var isStartingTerminal = false
    @State private var terminalPresentation = TerminalListPresentationStore()
    /// Where the detail column's navigation bar sits, from the column's top
    /// edge. In regular width it starts just below the status bar; see
    /// `detailTopChromeInset`.
    @State private var detailBar = NavigationBarBand()
    /// The Agent whose detail shows Changes in place of its terminal; the
    /// window's chrome then follows the app, not the terminal theme.
    @State private var agentShowingChanges: ConsoleAgent.ID?
    /// The Workspace section about to fold, whose rows the fold takes away
    /// fade first, and the one that just folded, whose rows it brings in
    /// slide into place (`ConsoleFoldReveal`).
    @State private var leavingSection: ConsoleWorkspaceSection.ID?
    @State private var foldingSection: ConsoleWorkspaceSection.ID?
    @State private var foldGeneration = 0
    /// The Agent whose detail shows Chat in place of its terminal, for the
    /// same reason.
    @State private var agentShowingChat: ConsoleAgent.ID?
    /// The Shell Terminal pushed over the Agent on the path, kept here so a
    /// detail remounted by a size-class change still shows it.
    @State private var agentShellRoute: AgentShellRoute?
    /// Each list tab's last selection. In regular width both lists sit
    /// beside their own detail, so a list tab comes back to what it showed
    /// rather than to the other list's pick.
    @State private var rememberedSelections: [ConsoleTab: ParkedSelection] = [:]
    /// The core each detail in this window keeps to, past its views.
    @State private var detailCores = ConsoleDetailCores()
    /// Bumped by each pick that replaces a detail left on a gone core, at an address
    /// a new detail would otherwise reuse the old one's state for.
    @State private var detailOpening = 0
    /// A request to open the Hosts sheet on one Host's detail. Each request
    /// rebuilds the list so it lands there even when that Host is already
    /// on its stack.
    @State private var hostsTabRequest: HostsTabRequest?
    /// The New Agent sheet while it is up. An item rather than a flag, so
    /// the sheet reads the origin it was opened with.
    @State private var startAgentRequest: StartAgentRequest?
    @State private var connectionDetailRequest: ConnectionDetailRequest?
    /// The flat lists' summary opened: every Host problem in one sheet.
    @State private var isShowingHostIssues = false
    /// Per Host, the failure its pushed detail showed at Retry Now.
    @State private var hostIssuesLastFailures: [Host.ID: TransportError] = [:]
    /// Hosts whose Host-detail Reconnect request is in flight, including the
    /// 1.2 s visual-feedback hold after `retryHost` returns. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    /// Narrows both lists to selected Hosts; an empty set shows every Host.
    /// Filtering does not change grouping or catalog order.
    @State private var hostFilter: Set<Host.ID> = []
    @State private var filterPopoverTab: ConsoleTab?
    /// Each list's own search (#292, #316), after `hostFilter`. The field
    /// hides under the title until the list is pulled down.
    @State private var agentSearchText = ""
    @State private var terminalSearchText = ""
    @State private var isAgentSearchPresented = false
    @State private var isTerminalSearchPresented = false
    /// The list whose search field has focus.
    @FocusState private var focusedSearch: ConsoleTab?
    @State private var commandRegistry = ConsoleCommandRegistry()
    /// Row-level `tab.close` failure text; non-nil shows the error alert.
    @State private var tabCloseError: String?
    /// The Agent whose tab the swipe action would close; non-nil shows the
    /// close confirmation.
    @State private var pendingTabClose: ConsoleAgent?
    /// The saved Chat entry the swipe action would remove from this device;
    /// separate from a close, which asks the Host and says so.
    @State private var pendingSavedChatRemoval: ConsoleAgent?
    /// Owns presentation mode and Host/Workspace collapse state.
    @State private var listPresentation = ConsoleListPresentationStore()
    /// The desktop arc board's per-Host caches: what every Agent is doing
    /// now, and each project's board.
    @State private var arcBoard = ArcBoardStore()
    /// The project the arc list shows, by Host and Workspace id; empty until
    /// the list picks the first project that has Agents.
    @AppStorage("console.arc.selected-project") private var arcSelectionKey = ""
    /// Whether the arc list is falling back to the flat rows because a search
    /// or a status filter is on.
    private var arcIsNarrowed: Bool {
        !agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !listPresentation.statusFilter.isEmpty
    }
    /// Outlives the detail column's rebuilds, which is the whole point: it
    /// carries the raised keyboard from one Attach screen to the next.
    @State private var keyboardHandoff = TerminalKeyboardHandoff()
    /// Outlives those rebuilds for the same reason. A per-screen inset starts
    /// every switch at zero and only learns the keyboard's height once UIKit
    /// posts the next frame notification, so the terminal that inherits a
    /// raised keyboard would lay out full height first and shrink a moment
    /// later — an extra reflow, and a Connecting dialog that visibly jumps
    /// from the middle of the screen to the middle of the terminal.
    @State private var keyboardInset = TerminalKeyboardInset()
    /// Per list tab: hiding one list's sidebar leaves the other's alone, and
    /// a split view coming back on screen cannot overwrite a hide made in
    /// the other tab with its own stale state.
    @State private var splitVisibilities: [ConsoleTab: ConsoleSplitVisibilityState] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.sceneWindow) private var sceneWindow
    @State private var detailCrossfade = DetailCrossfade()
    @State private var tabBarRequest = ConsoleTabBarBridge.Request()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The window-aware entry into navigation; nil outside a scene root.
    @Environment(\.agentSceneRouting) private var sceneRouting

    var body: some View {
        tabs.modifier(ConsoleDetailCoresRetention(cores: detailCores, held: heldDetails))
    }

    private var tabs: some View {
        Group {
            if listPresentation.mode == .arc {
                splitView(for: .agents)
            } else {
                TabView(selection: tabViewSelection) {
                    Tab(ConsoleTab.agents.title, systemImage: ConsoleTab.agents.systemImage, value: ConsoleTab.agents) {
                        splitView(for: usesSidebarNavigation ? shownListTab : .agents)
                    }
                    Tab(ConsoleTab.waiting.title, systemImage: ConsoleTab.waiting.systemImage, value: ConsoleTab.waiting) {
                        waitingTab
                    }
                    .badge(arcBlockedCount)
                    Tab(ConsoleTab.progress.title, systemImage: ConsoleTab.progress.systemImage, value: ConsoleTab.progress) {
                        progressTab
                    }
                    Tab(value: ConsoleTab.terminals) {
                        // Beside an iPad's sidebar the Terminals list shows in the
                        // Agents tab's split view; see `tabViewSelection`.
                        if !usesSidebarNavigation {
                            splitView(for: .terminals)
                        } else {
                            // Still asking for the bar hidden: a tab's request
                            // vanishing reads to SwiftUI as asking for the bar, and
                            // one left by a compact detail would bring it back.
                            Color.clear.toolbarVisibility(.hidden, for: .tabBar)
                        }
                    } label: {
                        // The tab bar fills symbols; filled, this one is a solid
                        // block beside the other tabs' line icons.
                        Label(ConsoleTab.terminals.title, systemImage: "terminal")
                            .environment(\.symbolVariants, .none)
                    }
                }
            }
        }
        // `lastListTab` is every window's; this window keeps the list tab it
        // opened on even when another window picks a different one.
        .onAppear {
            if listTab == nil { listTab = shownListTab }
        }
        #if DEBUG && targetEnvironment(simulator)
        .task {
            guard DemoScreenshotMode.opensAgent else { return }
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                if let id = visibleAgentIDs.first { selectAgent(id); return }
            }
        }
        #endif
        // The board's now text, while the Console is on screen. A Host
        // without the board answers nothing, which reads as no text.
        .task {
            while !Task.isCancelled {
                await arcBoard.refreshNow(hosts: hosts.consoleHosts) { [console] id in
                    console.chatHostFiles(for: id)
                }
                do { try await Task.sleep(for: ArcBoardStore.nowInterval) } catch { return }
            }
        }
        // The detail's actions can present these even while the sidebar is hidden.
        .sheet(item: $titleRename) { store in
            AgentTitleRenameSheet(store: store)
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(item: $startAgentRequest) { request in
            ConsoleSheetContent(sheetPresentation) { presentation in
                // StartAgentView brings its own NavigationStack.
                StartAgentView(
                    hosts: hosts.consoleHosts.offeringNewItem(
                        listsTerminals: false, capabilities: { console.capabilities(for: $0.id) }),
                    console: console, origin: request.origin
                ) { id in
                    // A fresh launch lands in its own terminal, exactly
                    // as tapping the new row would, on the list that has it.
                    if currentTab != .agents { selectedTab.wrappedValue = .agents }
                    openAnew(.agent(id))
                    notificationRouter.path = [id]
                    detailDidOpenFromSidebar()
                }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: presentation, fitsContent: true))
            }
        }
        // An Agent row's swipe or context menu asks here before closing.
        .alert(tabCloseDialogTitle, isPresented: tabCloseDialogPresented) {
            Button(tabCloseConfirmLabel, role: .destructive) { confirmTabClose() }
            Button("Cancel", role: .cancel) { pendingTabClose = nil }
        } message: {
            Text(pendingTabClose.map(tabCloseMessage(for:)) ?? "")
        }
        .modifier(ConsoleNoticesAndResets(
            console: console,
            pendingSavedChatRemoval: $pendingSavedChatRemoval,
            savedChatRemovalMessage: savedChatRemovalMessage(for:),
            removeSavedChat: removeSavedChat,
            leaveUsage: leaveUsage))
        .alert("Could Not Close", isPresented: tabCloseErrorPresented) {
            Button("OK", role: .cancel) { tabCloseError = nil }
        } message: {
            Text(tabCloseError ?? "")
        }
        .sheet(isPresented: $isStartingTerminal) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                // NewTerminalView brings its own NavigationStack.
                NewTerminalView(
                    hosts: hosts.consoleHosts.offeringNewItem(
                        listsTerminals: true, capabilities: { console.capabilities(for: $0.id) }),
                    console: console,
                    initialHostID: hostFilter.count == 1 ? hostFilter.first : nil
                ) {
                    // A new shell lands in its terminal, as tapping its row would.
                    selectTerminal($0)
                    detailDidOpenFromSidebar()
                }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: presentation, fitsContent: true))
            }
        }
        .sheet(item: $connectionDetailRequest) { request in
            ConsoleSheetContent(sheetPresentation) { presentation in
                if let host = hosts.consoleHosts.first(where: { $0.id == request.id }),
                    let detail = connectionDetail(for: request)
                {
                    HostConnectionDetailView(
                        presentation: detail,
                        host: host,
                        catalog: hosts,
                        sheetPresentation: presentation,
                        isRetryInFlight: manualReconnectInFlightHostIDs.contains(host.id),
                        onStop: { Task { await console.cancelHostConnection(host.id) } }
                    ) {
                        // Holds the sheet open through the retry's dial, which a
                        // reconnecting Host makes without a standing failure.
                        connectionDetailRequest?.lastFailure = detail.failure
                        Task { await reconnectHost(host.id) }
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingHostIssues) {
            ConsoleSheetContent(sheetPresentation) { hostIssuesSheet(presentation: $0) }
        }
        .sheet(isPresented: $isShowingHostsSheet, onDismiss: {
            hostsTabRequest = nil
            openProgressSheetIfAsked()
        }) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                hostList(onDone: { isShowingHostsSheet = false })
                    .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
        .sheet(isPresented: $isShowingSettingsSheet, onDismiss: {
            openProgressSheetIfAsked()
            guard let pending = pendingSettingsHost else { return }
            pendingSettingsHost = nil
            presentHosts(pending.id, opensHostHelper: pending.opensHostHelper)
        }) {
            ConsoleSheetContent(sheetPresentation) { presentation in
                settingsView(onDone: { isShowingSettingsSheet = false })
                    .modifier(ConsoleSheetPresentationModifier(presentation: presentation))
            }
        }
        .sheet(isPresented: $isShowingAllArcProjects) {
            AirBuildAllProjectsView(
                groups: arcProjectGroups, selected: arcSelectedProjectID,
                onSelect: { arcSelect($0) })
        }
        .sheet(item: $arcRenamingProject) { project in
            RenameSheetView(
                title: String(localized: "Rename Workspace"),
                store: RenameStore.workspace(currentLabel: project.label) { [console] label in
                    try await console.renameWorkspace(
                        project.id.workspaceID, label: label, on: project.id.hostID)
                })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)))
        }
        .alert(
            "Couldn't Open Terminal",
            isPresented: Binding(
                get: { arcNewTerminalFailure != nil },
                set: { if !$0 { arcNewTerminalFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(arcNewTerminalFailure ?? "")
        }
        // Progress beside a sidebar; a project picked there opens in it.
        .sheet(isPresented: $isShowingProgressSheet, onDismiss: { progressSheetPath = [] }) {
            NavigationStack(path: $progressSheetPath) {
                progressPage { id in
                    isShowingProgressSheet = false
                    openProject(id)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingProgressSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        // A Usage widget's tap. ContentView routes `heeler://agent` links;
        // these land on this window's Usage tab.
        .onOpenURL { url in
            guard let link = UsageWidgetLink.target(from: url) else { return }
            openUsage(link)
        }
        // Retries answered, the Host no longer failing, drop what they saw.
        .onChange(of: hostIssuesSheetExplained) { _, explained in
            hostIssuesLastFailures = hostIssuesLastFailures.filter { explained.contains($0.key) }
        }
        .onChange(of: filteredHostIssues.isEmpty) { _, isEmpty in
            if isEmpty { isShowingHostIssues = false }
        }
        // Once the Host connects again (or leaves the catalog) the sheet has
        // nothing left to explain.
        .onChange(of: connectionDetailRequest.flatMap { connectionDetail(for: $0) }) {
            _, detail in
            if detail == nil { connectionDetailRequest = nil }
        }
        .modifier(
            ConsoleStatusBarModifier(
                scheme: terminalStatusBarColorScheme
            )
        )
        // Above the NavigationStack so a banner also shows over a pushed
        // Agent detail; a tap deep-links exactly like a push tap would.
        .overlay(alignment: .top) {
            if let banner = bannerStore.banner {
                AgentNotificationBannerView(banner: banner) {
                    bannerStore.dismiss()
                    openNotificationTarget(banner.target)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: bannerStore.banner)
        .onChange(of: notificationRouter.path) { old, path in
            if agentShellRoute?.agentID != path.last { agentShellRoute = nil }
            guard !path.isEmpty else { return }
            bringAgentForward(
                parking: old.last.map { .agent($0) } ?? selectedTerminal.map { .terminal($0) })
        }
        // A deep link to the Agent already on the path leaves it unchanged,
        // and must still come forward from Hosts, Settings or a sheet.
        .onChange(of: notificationRouter.repeatLandings) {
            bringAgentForward(parking: parkedSelection)
        }
        // A window widening past the tab bar (an iPhone Duo unfolding) has
        // no Waiting or Progress tab: Progress carries over into its sheet,
        // and the sidebar's list shows what waits.
        .onChange(of: usesSidebarNavigation) { _, usesSidebar in
            guard usesSidebar, let page = pageTab else { return }
            pageTab = nil
            if page == .progress {
                progressSheetPath = progressPath
                progressPath = []
                isShowingProgressSheet = true
            }
        }
        // Drop removed Hosts without losing remaining selections. Removing
        // the last selected Host falls back to All Hosts.
        .onChange(of: hosts.consoleHosts) { _, hosts in
            hostFilter.formIntersection(hosts.map(\.id))
        }
        .environment(\.consoleCommandRegistry, commandRegistry)
        .focusedSceneValue(\.consoleCommandTarget, commandTarget)
    }

    /// The TabView's selection: Waiting or Progress on top of the
    /// remembered list tab. Every way in lands here, so Hosts, Settings and
    /// Usage, which are no longer tabs, turn into what replaced them.
    private var selectedTab: Binding<ConsoleTab> {
        Binding(
            get: { pageTab ?? shownListTab },
            set: { requested in
                switch requested {
                case .hosts:
                    isShowingHostsSheet = true
                    return
                case .settings:
                    isShowingSettingsSheet = true
                    return
                case .usage:
                    // Usage turned off behind a screen that opened from it.
                    if console.isUsageEnabled { showUsage() }
                    return
                case .agents, .waiting, .progress, .terminals:
                    break
                }
                // Beside a sidebar Progress is a sheet and Waiting the
                // sidebar's own section.
                if usesSidebarNavigation, !requested.isList {
                    if requested == .progress { isShowingProgressSheet = true }
                    return
                }
                let tab = requested
                let leavingList = shownListTab
                // A search field keeping first responder through the switch
                // can leave the arriving tab blank; its query stays.
                if tab != currentTab { focusedSearch = nil }
                pageTab = tab.isList ? nil : tab
                guard tab.isList else { return }
                if tab != leavingList, horizontalSizeClass == .regular {
                    swapListSelection(from: leavingList, to: tab)
                }
                pinListTab(tab)
            })
    }

    private var currentTab: ConsoleTab { selectedTab.wrappedValue }

    /// The TabView's own selection. Beside a sidebar both lists share the
    /// Projects tab's split view, so switching lists keeps one sidebar and
    /// its bar rather than swapping in another tab's; there is no tab bar
    /// to pick anything else from.
    private var tabViewSelection: Binding<ConsoleTab> {
        Binding(
            get: { usesSidebarNavigation ? .agents : currentTab },
            set: { tab in
                guard !usesSidebarNavigation else { return }
                selectedTab.wrappedValue = tab
            })
    }

    /// Regular width, an iPad or an unfolded iPhone Duo alike, navigates
    /// from a sidebar instead of a tab bar; compact width keeps the bar.
    private var usesSidebarNavigation: Bool {
        horizontalSizeClass == .regular
    }

    /// Hosts, as a sheet. HostListView brings its own NavigationStack.
    private func hostList(onDone: (@MainActor () -> Void)? = nil) -> some View {
        HostListView(
            store: hosts,
            initialHostID: hostsTabRequest?.hostID,
            opensHostHelper: hostsTabRequest?.opensHostHelper ?? false,
            usageStore: console.isUsageEnabled ? { console.agentUsageStore(for: $0) } : nil,
            openUsage: { openUsage(for: $0) },
            showsSetupGuide: hostsTabRequest?.showsSetupGuide ?? false,
            connectionStatuses: console.hostStatuses,
            standingFailures: console.hostStandingFailures,
            latencies: console.hostLatencies,
            routeIDs: console.hostRouteIDs,
            syncIssues: console.hostSyncErrors,
            coreEnvironmentNotices: console.hostCoreEnvironmentNotices,
            harnessEdits: console,
            manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
            retryConnection: { await reconnectHost($0) },
            stopConnecting: { await console.cancelHostConnection($0) },
            onDone: onDone)
        .id(hostsTabRequest?.id)
    }

    /// Settings, as a sheet. SettingsView brings its own NavigationStack.
    private func settingsView(onDone: (@MainActor () -> Void)? = nil) -> some View {
        SettingsView(
            terminal: terminal,
            appearance: appearance,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            liveActivities: liveActivities,
            console: console,
            hosts: hosts.consoleHosts,
            onHostAdded: { openHostFromSettings($0) },
            openHostHelper: { openHostFromSettings($0, opensHostHelper: true) },
            onDone: onDone)
    }

    /// A Host page Settings asks for, once a Settings sheet is out of the way.
    private func openHostFromSettings(_ id: Host.ID, opensHostHelper: Bool = false) {
        if isShowingSettingsSheet {
            pendingSettingsHost = (id, opensHostHelper)
            isShowingSettingsSheet = false
        } else {
            presentHosts(id, opensHostHelper: opensHostHelper)
        }
    }

    /// The lists a sidebar's title menu switches between.
    private var shownSidebarLists: [ConsoleTab] { [.agents, .terminals] }

    /// Every Host the Usage page can read, in catalog order.
    private var usageEntries: [AgentUsageHostEntry] {
        hosts.consoleHosts.map(console.agentUsageEntry(for:))
    }

    /// Blocked Agents on every Host: the Waiting tab's badge.
    private var arcBlockedCount: Int {
        ArcWaitingList.entries(arcAllGroups, status: .blocked).count
    }

    /// The Waiting tab. Beside a sidebar there is no tab bar: the sidebar's
    /// list shows what waits.
    @ViewBuilder
    private var waitingTab: some View {
        if usesSidebarNavigation {
            // As the Terminals tab: still asking for the bar hidden.
            Color.clear.toolbarVisibility(.hidden, for: .tabBar)
        } else {
            waitingPage
        }
    }

    /// The Progress tab. Beside a sidebar the sidebar's toolbar presents
    /// Progress as a sheet instead.
    @ViewBuilder
    private var progressTab: some View {
        if usesSidebarNavigation {
            Color.clear.toolbarVisibility(.hidden, for: .tabBar)
        } else {
            NavigationStack(path: $progressPath) {
                progressPage { openProject($0) }
            }
        }
    }

    /// Every Host's Blocked conversations, then its Done ones. A row opens
    /// its Agent as the lists do.
    private var waitingPage: some View {
        let groups = arcAllGroups
        return NavigationStack {
            ArcWaitingPage(
                blocked: ArcWaitingList.entries(groups, status: .blocked),
                done: ArcWaitingList.entries(groups, status: .done),
                agentTitle: { arcAgentTitle($0) },
                now: { arcAgentNow($0) },
                onSelect: { id in
                    selectedTab.wrappedValue = .agents
                    selectAgent(id)
                })
        }
    }

    /// The Progress page, in its tab or its sheet; `onSelect` opens a
    /// project.
    private func progressPage(
        onSelect: @escaping (ConsoleWorkspaceSection.ID) -> Void
    ) -> some View {
        let rows = ArcProgressRow.rows(arcAllGroups) { arcAgentTitle($0) }
        // Progress beside a sidebar opens as a sheet, which has no tab bar.
        return ArcProgressPage(
            scope: $progressScope,
            rows: rows,
            selected: rows.first { $0.id == arcSelectedProjectID },
            board: arcSelectedProjectID.flatMap { ArcBoardLookup.board(for: $0, in: arcBoard.boards) },
            boards: arcBoard.boards,
            showsUsage: console.isUsageEnabled,
            onSelect: { id in
                progressScope = .project
                onSelect(id)
            },
            refresh: {
                await arcBoard.refreshBoards(hosts: hosts.consoleHosts) { [console] id in
                    console.chatHostFiles(for: id)
                }
            }
        ) {
            AgentUsageDashboard(
                entries: usageEntries, scopeHostID: $usageScopeHostID, metric: $usageMetric,
                limitsRequested: $usageLimitsRequested)
                .navigationTitle(ConsoleTab.usage.title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AgentUsageScopeMenu(entries: usageEntries, scopeHostID: $usageScopeHostID)
                    }
                }
                .environment(\.hostAccounts, HostAccountsProvider { [console] in console.hostAccountsStore(for: $0) })
        }
    }

    /// The arc list's light conversation row, wrapped in the same link as
    /// the full card so its detail, menu and swipes stay.
    private func arcAgentRow(_ agent: ConsoleAgent, projectName: String? = nil) -> some View {
        let readiness = console.savedChatEntries[agent.id]
        // A Host still connecting draws its saved entries as live rows; a
        // Host that stopped draws them as saved, with no status of their own.
        let shown = console.isHostConnecting(agent.hostID) ? nil : readiness
        return agentLink(
            agent, isSaved: readiness != nil,
            background: ConsoleRowSelectionBackground(
                isSelected: selectedItem.wrappedValue == .agent(agent.id))
        ) {
            ArcAgentRow(
                agent: agent, title: arcAgentTitle(agent),
                now: arcAgentNow(agent), projectName: projectName,
                isSelected: selectedItem.wrappedValue == .agent(agent.id))
        } preview: {
            AgentCardView(
                agent: agent,
                layout: console.rowLayout(for: agent.hostID),
                isPinned: console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID),
                qualifier: nil,
                saved: shown,
                hiddenTokens: [])
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .navigationLinkIndicatorVisibility(.hidden)
    }

    /// What the Agent is doing now, from its Host's board; nil where its
    /// Host never ran the board.
    private func arcAgentNow(_ agent: ConsoleAgent) -> String? {
        ArcAgentNowLookup.now(for: agent, in: arcBoard.now)?.text
    }

    /// An Agent's title as its list row heads it, beside a project the row
    /// names apart.
    private func arcAgentTitle(_ agent: ConsoleAgent) -> String {
        AgentCardPresentation(
            agent: agent, layout: console.rowLayout(for: agent.hostID), hiding: [.workspace],
            leadsWithMark: true
        ).switcherTitle
    }

    /// A project picked on Progress: the Projects tab, on that project.
    private func openProject(_ id: ConsoleWorkspaceSection.ID) {
        // A Host filter hiding the project would leave the pick unseen.
        if !hostFilter.isEmpty, !hostFilter.contains(id.hostID) { hostFilter = [] }
        arcSelect(id)
        selectedTab.wrappedValue = .agents
    }

    /// Usage, on Progress: pushed on the tab's stack, or on the sheet's
    /// beside a sidebar.
    private func showUsage() {
        if listPresentation.mode == .arc {
            progressSheetPath = [.usage]
            if isShowingHostsSheet || isShowingSettingsSheet {
                opensProgressSheetAfterDismiss = true
            } else {
                isShowingProgressSheet = true
            }
        } else if usesSidebarNavigation {
            progressSheetPath = [.usage]
            if isShowingHostsSheet || isShowingSettingsSheet {
                opensProgressSheetAfterDismiss = true
            } else {
                isShowingProgressSheet = true
            }
        } else {
            progressPath = [.usage]
            selectedTab.wrappedValue = .progress
        }
        isShowingHostsSheet = false
        isShowingSettingsSheet = false
    }

    private func openProgressSheetIfAsked() {
        guard opensProgressSheetAfterDismiss else { return }
        opensProgressSheetAfterDismiss = false
        isShowingProgressSheet = true
    }

    /// The Host detail's way into Usage, on that Host.
    private func openUsage(for hostID: Host.ID) {
        usageScopeHostID = hostID
        selectedTab.wrappedValue = .usage
    }

    /// A Usage widget's tap: Usage on the widget's scope, and for Usage
    /// Limits, that Host's limits. A Host since removed opens All Hosts.
    private func openUsage(_ link: UsageWidgetLink.Target) {
        guard console.isUsageEnabled else { return }
        let hostID = link.hostID.flatMap { id in hosts.consoleHosts.contains { $0.id == id } ? id : nil }
        usageScopeHostID = hostID
        selectedTab.wrappedValue = .usage
        usageLimitsRequested = link.showsLimits && hostID != nil
    }

    /// Usage turned off, from this window or another: nothing of it stays
    /// on screen or asked for, so turning it back on opens where it first did.
    private func leaveUsage() {
        progressPath.removeAll { $0 == .usage }
        progressSheetPath.removeAll { $0 == .usage }
        usageScopeHostID = nil
        usageLimitsRequested = false
    }

    private func switchList(to tab: ConsoleTab) {
        guard tab != currentTab else { return }
        let leaving = splitVisibility(for: currentTab)
        selectedTab.wrappedValue = tab
        splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
            .keepSidebar(from: leaving)
    }

    private func showHosts() { selectedTab.wrappedValue = .hosts }

    private func showSettings() { selectedTab.wrappedValue = .settings }

    /// The list tab on screen, or under Waiting or Progress. A tab saved
    /// before Hosts, Settings and Usage left the bar lands on Projects.
    private var shownListTab: ConsoleTab {
        listTab ?? ConsoleTab(saved: sceneListTab.isEmpty ? lastListTab.rawValue : sceneListTab)
    }

    private func pinListTab(_ tab: ConsoleTab) {
        listTab = tab
        sceneListTab = tab.rawValue
        lastListTab = tab
    }

    /// An Agent shows on the Agents list, whatever brought it on stage: the
    /// Terminals list has no row for it. The list it replaces keeps what it
    /// showed, as a tab switch would park it.
    private func showAgentsList(parking parked: ParkedSelection?) {
        let shown = shownListTab
        guard shown != .agents else { return }
        if horizontalSizeClass == .regular { rememberedSelections[shown] = parked }
        pinListTab(.agents)
    }

    /// Lands the path's Agent on Agent detail, even when one of the
    /// Console's sheets covers it. The only other push a sheet can cause is
    /// the new-agent flow's, which dismisses itself first, so clearing here
    /// is a no-op for it.
    private func bringAgentForward(parking parked: ParkedSelection?) {
        showAgentsList(parking: parked)
        selectedTerminal = nil
        // Waiting and Progress have no detail column; the Agent shows on its
        // list tab.
        pageTab = nil
        isShowingProgressSheet = false
        opensProgressSheetAfterDismiss = false
        startAgentRequest = nil
        isStartingTerminal = false
        connectionDetailRequest = nil
        isShowingHostIssues = false
        isShowingHostsSheet = false
        pendingSettingsHost = nil
        isShowingSettingsSheet = false
    }

    /// What the detail column shows, whatever the list marks.
    private var detailOnStage: ConsoleSelection? {
        if let id = notificationRouter.path.last { return .agent(id) }
        return selectedTerminal.map { .terminal($0.id) }
    }

    /// The details this window may come back to as they were.
    private var heldDetails: Set<ConsoleSelection> {
        var held = Set(rememberedSelections.values.map(\.selection))
        if let detailOnStage { held.insert(detailOnStage) }
        return held
    }

    /// Replaces a detail left on a gone core, if `selection` names one.
    private func openAnew(_ selection: ConsoleSelection) {
        if detailCores.openAnew(selection, console: console) { detailOpening += 1 }
    }

    /// What the detail shows, as a list tab parks it.
    private var parkedSelection: ParkedSelection? {
        if let id = notificationRouter.path.last { return .agent(id) }
        return selectedTerminal.map { .terminal($0) }
    }

    /// Parks the leaving list's selection and puts back the arriving one's,
    /// if what it showed may still be there. No crossfade: behind a tab bar
    /// the detail column belongs to the other tab's split view.
    private func swapListSelection(from leaving: ConsoleTab, to arriving: ConsoleTab) {
        rememberedSelections[leaving] = parkedSelection
        switch rememberedSelections[arriving] {
        case .agent(let id)
        where console.agents.contains(where: { $0.id == id })
            || console.departedAgents.contains(where: { $0.id == id }) || isUnreported(id):
            selectedTerminal = nil
            notificationRouter.path = [id]
        case .terminal(let parked) where isRestorable(parked):
            notificationRouter.path = []
            selectedTerminal = console.terminals.first(where: { $0.id == parked.id }) ?? parked
        default:
            notificationRouter.path = []
            selectedTerminal = nil
        }
    }

    /// A shell that has since started an Agent shows on the Agents list
    /// instead, so the Terminals list does not come back to it.
    private func isRestorable(_ parked: ConsoleTerminal) -> Bool {
        if let live = console.terminals.first(where: { $0.id == parked.id }) {
            return !live.isAgent
        }
        return isUnreported(ConsoleAgent.ID(hostID: parked.hostID, paneID: parked.paneID))
    }

    /// A pane missing from the lists only because its Host has not reported
    /// since (paused, reconnecting, failed, loading) rather than because it
    /// went. The detail keeps such a selection through a reconnect; a tab
    /// switch in the meantime must too.
    private func isUnreported(_ id: ConsoleAgent.ID) -> Bool {
        MissingAgentPresentation(agentID: id, console: console, hosts: hosts).cause != .paneGone
    }

    private func splitVisibility(for tab: ConsoleTab) -> ConsoleSplitVisibilityState {
        splitVisibilities[tab] ?? ConsoleSplitVisibilityState()
    }

    /// The split view's own reports land in its tab's state only.
    private func splitVisibilityBinding(
        for tab: ConsoleTab, presentation: ConsoleSplitPresentation
    ) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { splitVisibility(for: tab).visibility },
            set: {
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .systemDidChangeVisibility($0, presentation: presentation)
                // A window unfolding into a landscape split collapses the
                // sidebar once, before this state holds the new layout. The
                // policy has to be reasserted or the sidebar stays away.
                if splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .takeSidebarRestore()
                {
                    Task { @MainActor in
                        splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                            .showSidebar()
                    }
                }
            })
    }

    /// A wide iPhone's tab bar follows the terminal on stage, as the status
    /// bar does; in compact width the terminal is pushed clear of it.
    private var tabBarChromeScheme: ColorScheme? {
        horizontalSizeClass == .regular ? terminalStatusBarColorScheme : nil
    }

    /// A pushed detail owns the whole iPhone screen, as it did before the
    /// tab bar existed. A wide iPhone keeps the bar to switch lists; an
    /// iPad's sidebar switches them itself.
    private var hidesTabBar: Bool {
        usesSidebarNavigation
            || (horizontalSizeClass == .compact && selectedItem.wrappedValue != nil)
    }

    /// Beside an opaque sidebar, the detail's leading safe area lies under
    /// it, and its material would take on a terminal's color there. A glass
    /// sidebar floats over the terminal instead, which fills the window.
    private func detailSurfaceEdges(for tab: ConsoleTab) -> Edge.Set {
        !sidebarFloatsOverDetail && horizontalSizeClass == .regular
            && splitVisibility(for: tab).isSidebarVisible != false
            ? [.vertical, .trailing] : .all
    }

    /// iPadOS 26 draws the sidebar as glass over the detail column, so what
    /// lies behind it is the detail's; earlier releases give it an opaque
    /// column of its own, up to the window's top edge.
    private var sidebarFloatsOverDetail: Bool {
        if #available(iOS 26.0, *) { true } else { false }
    }

    /// Output starts below the detail's bar row, or below the whole bar
    /// while it carries the Show Sidebar button.
    private func detailTopInset(for tab: ConsoleTab) -> CGFloat {
        splitVisibility(for: tab).isSidebarVisible == false ? detailBar.bottom : detailBar.top
    }

    /// One tab's split view. A split view instead of a plain stack for the
    /// iPad's sake: regular width shows the list beside the Attach terminal;
    /// compact width collapses into the familiar push navigation. The
    /// router's path stays the single source of truth — the sidebar selection
    /// is a projection of it, so notification deep links keep working.
    private func splitView(for tab: ConsoleTab) -> some View {
        GeometryReader { geometry in
            let presentation = ConsoleSplitPresentation(
                horizontalSizeClass: horizontalSizeClass,
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets)
            NavigationSplitView(
                columnVisibility: splitVisibilityBinding(for: tab, presentation: presentation)
            ) {
                sidebarLists(showing: tab)
                    // The sidebar column reports a compact size class even
                    // beside a detail, so the lists are told outright.
                    .environment(\.isSidebarColumn, presentation.usesRegularColumns)
                    .environment(\.consoleListShowsDisclosure, !presentation.usesRegularColumns && listPresentation.mode != .arc)
                    .navigationTitle(listTitle(for: tab))
                    .navigationSplitViewColumnWidth(
                        min: usesAirBuildArcChrome(for: tab) ? 300 : presentation.sidebarWidth.minimum,
                        ideal: usesAirBuildArcChrome(for: tab) ? 300 : presentation.sidebarWidth.ideal,
                        max: usesAirBuildArcChrome(for: tab) ? 300 : presentation.sidebarWidth.maximum)
                    // A title menu shows only on an inline title; a large
                    // or inline-large one drops it.
                    .navigationBarTitleDisplayMode(
                        usesAirBuildArcChrome(for: tab) || usesSidebarNavigation ? .inline : .automatic)
                    .toolbar { toolbar(for: tab) }
                    .airBuildHomeBarControls(
                        isVisible: usesAirBuildArcChrome(for: tab) && foldedHome,
                        onNewAgent: offersNewItem(on: .agents)
                            ? {
                                startAgentRequest = StartAgentRequest(
                                    origin: arcSelectedProject.flatMap { arcNewAgentOrigin(for: $0) })
                            } : nil,
                        actions: AirBuildGlobalActions(openHosts: { showHosts() }, openSettings: { showSettings() }))
                    .background { VerticalToolbarProbe(usesVerticalToolbar: $sidebarHasVerticalBar) }
                    .readsVerticalToolbar()
                    // AirBuild's project grid replaces the list title.
                    .toolbar(removing: usesAirBuildArcChrome(for: tab) || usesSidebarNavigation ? .title : nil)
                    .bottomBar {
                        if (usesAirBuildArcChrome(for: tab) || usesSidebarNavigation), !foldedHome {
                            // shortcut: landscape stands in for "the system draws a vertical bar" (true on iPhone Duo,
                            // not on iPad); read the sidebar's own toolbar edge if Arc ships on iPad.
                            // Only an open Agent's detail draws the global bar; with a shell or
                            // nothing open, Hosts and Settings stay here or they'd be nowhere.
                            sidebarFooter(
                                for: tab,
                                detailHasGlobalBar: geometry.size.width > geometry.size.height
                                    && notificationRouter.path.last != nil)
                        }
                    }
                    // iPadOS 27 draws the system's button on its own glass;
                    // the sidebar has a bare one beside its others, and the
                    // detail one to bring the sidebar back. Removed here, it
                    // leaves the whole split view.
                    .toolbar(removing: usesSidebarNavigation ? .sidebarToggle : nil)
            } detail: {
                // Every tab keeps its split view alive; only the selected one
                // may mount the detail, or a terminal would attach twice.
                if tab == currentTab {
                    // An explicit stack, so a detail can push its own screens
                    // (Changes over an Agent) with the system's Back and swipe.
                    NavigationStack {
                        detail(in: tab)
                            .readsVerticalToolbar()
                            .environment(
                                \.detailTopChromeInset,
                                horizontalSizeClass == .regular ? detailTopInset(for: tab) : 0)
                            .environment(
                                \.detailBarRow, horizontalSizeClass == .regular ? detailBar : nil)
                            .environment(\.detailSurfaceEdges, detailSurfaceEdges(for: tab))
                            .environment(\.revealDetailSidebar, sidebarReveal(for: tab))
                            .environment(\.detailSidebarIsHidden, splitVisibility(for: tab).isSidebarVisible == false)
                            .environment(
                                \.airBuildGlobalActions,
                                usesAirBuildArcChrome(for: tab)
                                    ? AirBuildGlobalActions(
                                        openHosts: { showHosts() }, openSettings: { showSettings() })
                                    : nil)
                            .environment(
                                \.showsDetailBackButton, !presentation.usesRegularColumns)
                            .toolbar {
                                if usesSidebarNavigation,
                                    splitVisibility(for: tab).isSidebarVisible == false
                                {
                                    ToolbarItem(placement: .topBarLeading) {
                                        Button("Show Sidebar", systemImage: "sidebar.left") {
                                            withAnimation(reduceMotion ? nil : .snappy) {
                                                splitVisibilities[
                                                    tab, default: ConsoleSplitVisibilityState()
                                                ].showSidebar()
                                            }
                                        }
                                    }
                                }
                            }
                            .background {
                                if horizontalSizeClass == .regular {
                                    NavigationBarTopReader { detailBar = $0 }
                                }
                            }
                            .overlay(alignment: .top) {
                                if horizontalSizeClass == .regular, !terminalOwnsTopEdge {
                                    Color(uiColor: .systemBackground)
                                        .frame(height: detailBar.top)
                                        .ignoresSafeArea(.container, edges: .top)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
            }
            // Keep structural identity stable across rotation and size-class changes.
            .navigationSplitViewStyle(.automatic)

            // The detail column swapping its content dissolves from the
            // leaving screen to the arriving one; see `DetailCrossfade`.
            .environment(\.detailCrossfade, detailCrossfade)
            .onChange(of: presentation, initial: true) { _, presentation in
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .update(from: presentation)
            }
            // A sidebar's switch hands this split view the other list, whose
            // state may predate the layout.
            .onChange(of: tab) { _, tab in
                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                    .update(from: presentation)
            }
        }
        // Up to the window's top edge, as a split view alone in a window
        // runs: a terminal then reaches under the status bar, while the
        // columns' own bars still clear it.
        .ignoresSafeArea(.container, edges: horizontalSizeClass == .regular ? .top : [])
        // In every width, so a window turning compact drops the style.
        .background {
            ConsoleTabBarBridge(
                chromeScheme: tabBarChromeScheme, hidesBar: hidesTabBar, request: tabBarRequest)
        }
        .toolbarVisibility(hidesTabBar ? .hidden : .automatic, for: .tabBar)
    }

    /// Beside an iPad's sidebar both lists stay built, the one not shown
    /// out of sight and out of reach: a split view whose sidebar swaps its
    /// list rebuilds the whole column, its bar included, and each list keeps
    /// its scroll position and tucked search field across a switch.
    @ViewBuilder
    private func sidebarLists(showing tab: ConsoleTab) -> some View {
        if usesSidebarNavigation {
            ZStack {
                ForEach([ConsoleTab.agents, .terminals], id: \.self) { @Sendable list in
                    MainActorContent {
                        sidebar(for: list)
                            .modifier(SidebarListShown(isShown: tab == list))
                    }
                }
            }
            // One field for both lists, searching the one on show.
            .searchable(
                text: tab == .terminals ? $terminalSearchText : $agentSearchText,
                isPresented: tab == .terminals
                    ? $isTerminalSearchPresented : $isAgentSearchPresented,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: tab == .terminals ? String(localized: "Search Terminals") : String(localized: "Search Agents"))
            .searchFocused($focusedSearch, equals: tab)
            .sidebarSearchDrawer(following: tab, isDisabled: listPresentation.mode == .arc)
            // The title's list menu opens from here rather than from the
            // title: anything a bar item presents folds back onto the item's
            // frame, which lingers as a rectangle around a bare title for
            // about a second and a half after it closes.
            .overlay {
                GeometryReader { proxy in
                    let anchor = SidebarListMenu.anchor(
                        under: listMenuTitleFrame, in: proxy.frame(in: .global))
                    Color.clear
                        .frame(width: 1, height: 1)
                        .popover(isPresented: $isShowingListMenu, arrowEdge: .top) {
                            SidebarListChoices(
                                shown: tab, lists: shownSidebarLists,
                                isPresented: $isShowingListMenu, select: switchList(to:))
                        }
                        .position(anchor)
                }
                // Measured from the column's top, under the bar.
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
            }
        } else {
            sidebar(for: tab)
        }
    }

    @ViewBuilder
    private func sidebar(for tab: ConsoleTab) -> some View {
        switch tab {
        case .agents:
            content
                .modifier(ConsoleListSearch(
                    text: $agentSearchText, isPresented: $isAgentSearchPresented,
                    focus: $focusedSearch, tab: .agents,
                    prompt: "Search Agents", showsField: !usesSidebarNavigation))
                .scrollContentBackground(listPresentation.mode == .arc ? .hidden : .automatic)
                .background(listPresentation.mode == .arc ? Color(uiColor: .systemBackground) : Color.clear)
        case .terminals:
            if hosts.consoleHosts.isEmpty {
                noHostsView
            } else {
                TerminalListView(
                    hosts: hosts.consoleHosts,
                    console: console,
                    presentation: terminalPresentation,
                    filteredHostIDs: hostFilter,
                    searchQuery: terminalSearchText,
                    selection: selectedItem,
                    onOpen: { openTerminal($0, from: .terminals, bySidebar: true) },
                    onOpenHost: { openHostIssue($0) },
                    onShowHostIssues: { isShowingHostIssues = true },
                    onNewTerminal: { isStartingTerminal = true })
                .modifier(ConsoleListSearch(
                    text: $terminalSearchText, isPresented: $isTerminalSearchPresented,
                    focus: $focusedSearch, tab: .terminals,
                    prompt: "Search Terminals", showsField: !usesSidebarNavigation))
            }
        case .waiting, .progress, .usage, .hosts, .settings:
            // These show their own screens, not a split view.
            EmptyView()
        }
    }

    /// A filter is meaningless with a single Host.
    private var filtersByHost: Bool { hosts.consoleHosts.count > 1 }

    private func offersFilters(for tab: ConsoleTab) -> Bool {
        !hosts.consoleHosts.isEmpty && (tab == .agents || filtersByHost)
    }

    /// At the largest text sizes a bar cannot fit its title beside three
    /// buttons, so the filters join the presentation menu. An iPad
    /// sidebar keeps both menus at its foot, which has room for them.
    private var foldsListFilters: Bool {
        !usesSidebarNavigation && dynamicTypeSize >= .xxLarge
    }

    private func filterIsPresented(for tab: ConsoleTab) -> Binding<Bool> {
        Binding(
            get: { filterPopoverTab == tab },
            set: { shown in
                if shown {
                    filterPopoverTab = tab
                } else if filterPopoverTab == tab {
                    filterPopoverTab = nil
                }
            })
    }

    private func filterChoices(for tab: ConsoleTab) -> some View {
        ConsoleListFilterChoices(
            hosts: hosts.consoleHosts, hostFilter: $hostFilter,
            agentStatuses: tab == .agents ? listPresentation : nil,
            counts: statusFilterCounts)
            .presentationCompactAdaptation(.popover)
    }

    private func filterButton(for tab: ConsoleTab) -> some View {
        let isFiltered = !hostFilter.isEmpty || (tab == .agents && !listPresentation.statusFilter.isEmpty)
        return Button {
            filterPopoverTab = tab
        } label: {
            Label(
                tab == .agents ? "Filter Agents" : "Filter by Host",
                systemImage: isFiltered
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .accessibilityValue(isFiltered ? "Filtered" : "All")
        .popover(isPresented: filterIsPresented(for: tab)) {
            filterChoices(for: tab)
        }
    }

    @ViewBuilder
    private func presentationMenu(for tab: ConsoleTab) -> some View {
        if tab == .terminals {
            Menu {
                Picker("Terminal presentation", selection: terminalPresentationBinding) {
                    ForEach(TerminalListPresentationMode.allCases) { @Sendable mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                if foldsListFilters, offersFilters(for: tab) {
                    Section {
                        Button("Filter by Host", systemImage: "line.3.horizontal.decrease.circle") {
                            filterPopoverTab = tab
                        }
                    }
                }
            } label: {
                Label("Presentation", systemImage: terminalPresentation.mode.systemImage)
            }
            .accessibilityLabel("Terminal list presentation")
            .accessibilityValue(terminalPresentation.mode.title)
            .popover(isPresented: foldsListFilters ? filterIsPresented(for: tab) : .constant(false)) {
                filterChoices(for: tab)
            }
        } else {
            Menu {
                Picker("Presentation", selection: presentationModeBinding) {
                    ForEach(ConsoleListPresentationMode.allCases) { @Sendable mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }
                if foldsListFilters, offersFilters(for: tab) {
                    Section {
                        Button("Filter Agents", systemImage: "line.3.horizontal.decrease.circle") {
                            filterPopoverTab = tab
                        }
                    }
                }
            } label: {
                Label("Presentation", systemImage: listPresentation.mode.systemImage)
            }
            .accessibilityLabel("Agent list presentation")
            .accessibilityValue(listPresentation.mode.title)
            .popover(isPresented: foldsListFilters ? filterIsPresented(for: tab) : .constant(false)) {
                filterChoices(for: tab)
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(for tab: ConsoleTab) -> some ToolbarContent {
        if usesAirBuildArcChrome(for: tab) {
            if usesSidebarNavigation {
                ToolbarItem(placement: .topBarLeading) {
                    AirBuildGlassCapsule {
                        AirBuildIconButton(systemImage: "sidebar.left", label: "Hide Sidebar") {
                            withAnimation(reduceMotion ? nil : .snappy) {
                                splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                                    .hideSidebar()
                            }
                        }
                    }
                }
                .toolbarItemBackground(.hidden)
            }
            if !foldedHome {
            ToolbarItem(placement: .principal) {
                AirBuildGlassCapsule {
                    AirBuildHeelerLogo()
                        .frame(width: 40, height: 40)
                }
            }
            .toolbarItemBackground(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                AirBuildGlassCapsule {
                    // New Agent in one tap; computers have their own button in the footer.
                    Button {
                        startAgentRequest = StartAgentRequest(
                            origin: arcSelectedProject.flatMap { arcNewAgentOrigin(for: $0) })
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .disabled(!offersNewItem(on: .agents))
                    .accessibilityLabel("New Agent")
                }
            }
            .toolbarItemBackground(.hidden)
            }
        } else {
        // An iPad sidebar's title, always at the bar's leading edge: the
        // bar's own title centers itself wherever it fits, so it would move
        // as the list, and the title's width, changes.
        if usesSidebarNavigation {
            ToolbarItem(placement: .topBarLeading) {
                SidebarListMenu(
                    shown: tab, lists: shownSidebarLists,
                    isPresented: $isShowingListMenu, frame: $listMenuTitleFrame)
            }
            .toolbarItemBackground(.hidden)
        }
        // Without a tab bar to hold them, Projects keeps Hosts and Settings
        // in its own bar; a sidebar has them at its foot.
        if !usesSidebarNavigation, tab == .agents {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 0) {
                    Button(ConsoleTab.hosts.title, systemImage: ConsoleTab.hosts.systemImage) { showHosts() }
                    Button(ConsoleTab.settings.title, systemImage: ConsoleTab.settings.systemImage) {
                        showSettings()
                    }
                    // The project list's title names the project, so its New
                    // Agent sits here, starting in that project.
                    if !hosts.consoleHosts.isEmpty, offersNewItem(on: .agents) {
                        Button("New Agent", systemImage: "plus") {
                            startAgentRequest = StartAgentRequest(
                                origin: listPresentation.mode == .arc
                                    ? arcSelectedProject.flatMap { arcNewAgentOrigin(for: $0) } : nil)
                        }
                    }
                }
                .hoverEffect(.highlight)
            }
        }
        // A sidebar keeps its list menus at its foot; compact width keeps
        // them in the bar.
        if !usesSidebarNavigation, offersFilters(for: tab), !foldsListFilters {
            ToolbarItem(placement: .primaryAction) {
                filterButton(for: tab).hoverEffect(.highlight)
            }
        }
        if !usesSidebarNavigation, !hosts.consoleHosts.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                presentationMenu(for: tab).hoverEffect(.highlight)
            }
        }
        if usesSidebarNavigation {
            // One item, so the bar sets no gap between the two, and neither
            // folds into its overflow menu without the other: beside a
            // window's controls a sidebar at its narrowest has room for both
            // only this way.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 0) {
                    // No tab bar beside a sidebar: Progress opens as a sheet.
                    Button(ConsoleTab.progress.title, systemImage: ConsoleTab.progress.systemImage) {
                        isShowingProgressSheet = true
                    }
                    if !hosts.consoleHosts.isEmpty { newItemButton(for: tab) }
                    Button("Hide Sidebar", systemImage: "sidebar.left") {
                        withAnimation(reduceMotion ? nil : .snappy) {
                            splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                                .hideSidebar()
                        }
                    }
                }
                .buttonStyle(SidebarIconButtonStyle())
            }
            .toolbarItemBackground(.hidden)
        } else if !hosts.consoleHosts.isEmpty, tab != .agents {
            ToolbarItem(placement: .primaryAction) {
                newItemButton(for: tab).hoverEffect(.highlight)
            }
        }
        }
    }

    /// One button for both lists, so a sidebar switching lists keeps its
    /// bar as it is.
    @ViewBuilder
    private func newItemButton(for tab: ConsoleTab) -> some View {
        if offersNewItem(on: tab) {
            Button(tab == .terminals ? "New Terminal" : "New Agent", systemImage: "plus") {
                if tab == .terminals {
                    isStartingTerminal = true
                } else {
                    startAgentRequest = StartAgentRequest()
                }
            }
        }
    }

    private func offersNewItem(on tab: ConsoleTab) -> Bool {
        hosts.consoleHosts.offersNewItem(
            listsTerminals: tab == .terminals, capabilities: { console.capabilities(for: $0.id) })
    }

    /// Hosts, search and Settings flank the AirBuild list; other sidebars
    /// keep their existing list menus.
    @ViewBuilder
    private func sidebarFooter(for tab: ConsoleTab, detailHasGlobalBar: Bool) -> some View {
        if usesAirBuildArcChrome(for: tab) {
            // Hosts and Settings move to the detail's vertical bar where there is one.
            if !usesSidebarNavigation || !detailHasGlobalBar {
                HStack(spacing: 8) {
                    AirBuildGlassCapsule {
                        AirBuildIconButton(systemImage: "desktopcomputer", label: ConsoleTab.hosts.title) {
                            showHosts()
                        }
                    }
                    Spacer(minLength: 0)
                    AirBuildGlassCapsule {
                        AirBuildIconButton(systemImage: "gearshape", label: ConsoleTab.settings.title) {
                            showSettings()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        } else {
            HStack(spacing: 4) {
                Button(ConsoleTab.hosts.title, systemImage: "server.rack") { showHosts() }
                Button(ConsoleTab.settings.title, systemImage: "gearshape") { showSettings() }
                Spacer(minLength: 0)
                // A menu's pointer target is its own, not its button style's
                // label, so it takes the round highlight here.
                if offersFilters(for: tab), !foldsListFilters {
                    filterButton(for: tab).roundPointerHighlight()
                }
                if !hosts.consoleHosts.isEmpty {
                    presentationMenu(for: tab).roundPointerHighlight()
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(SidebarIconButtonStyle())
            .menuStyle(.button)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var terminalPresentationBinding: Binding<TerminalListPresentationMode> {
        Binding(
            get: { terminalPresentation.mode },
            set: { mode in
                withAnimation(reduceMotion ? nil : .snappy) { terminalPresentation.select(mode) }
            })
    }

    private var commandTarget: ConsoleCommandTarget {
        ConsoleCommandTarget(
            registry: commandRegistry,
            context: {
                .init(
                    // Hosts and Settings show no detail to act on.
                    selection: !currentTab.isList
                        ? nil
                        : notificationRouter.path.last ?? selectedTerminal.map {
                            ConsoleAgent.ID(hostID: $0.hostID, paneID: $0.paneID)
                        },
                    agents: visibleAgentIDs,
                    isSearchFocused: focusedSearch != nil,
                    // Tabs are navigation, not cover: only sheets and alerts
                    // are, including the ones Hosts, Settings and the
                    // Terminals list present, which register nowhere.
                    isCovered: startAgentRequest != nil || isStartingTerminal
                        || connectionDetailRequest != nil || isShowingHostIssues
                        || isShowingHostsSheet || isShowingSettingsSheet
                        || isPresentingOverConsole,
                    inputMode: inputMode.mode,
                    navigationAnchor: agentsListAnchor,
                    offersNewItem: offersNewItem(on: currentTab))
            },
            titles: ConsoleCommandTitles(
                listsTerminals: currentTab == .terminals,
                showsShell: currentTab.isList && notificationRouter.path.isEmpty
                    && selectedTerminal != nil),
            navigate: { id in
                // Agent shortcuts land on the Agents list from any tab.
                if currentTab != .agents { selectedTab.wrappedValue = .agents }
                guard id != notificationRouter.path.last else { return }
                if commandRegistry.terminal?.isFocused == true
                    || commandRegistry.composer?.isFocused == true
                {
                    keyboardHandoff.arm(for: id)
                }
                notificationRouter.path = [id]
            },
            focusSearch: {
                // Hosts and Settings have no search; ⌘F lands on Agents.
                let tab: ConsoleTab = currentTab == .terminals ? .terminals : .agents
                selectedTab.wrappedValue = tab
                // The field lives in the sidebar, which may be hidden.
                if horizontalSizeClass == .regular {
                    splitVisibilities[tab, default: ConsoleSplitVisibilityState()].showSidebar()
                }
                if tab == .terminals {
                    isTerminalSearchPresented = true
                } else {
                    isAgentSearchPresented = true
                }
                focusedSearch = tab
            },
            // ⌘N creates what the list on screen holds.
            newAgent: {
                if currentTab == .terminals {
                    isStartingTerminal = true
                } else {
                    startAgentRequest = StartAgentRequest()
                }
            },
            settings: { showSettings() },
            hosts: { presentHosts() },
            closeAgent: { clearSelection() })
    }

    /// The sidebar selection as a projection of the router's path, or of the
    /// drawer terminal on stage. Setting it (a row tap, or the collapsed
    /// stack popping) writes the path back, so user navigation and deep
    /// links keep one source of truth. A drawer terminal has no row, but it
    /// must still be *a* selection: on iPhone the split view shows the
    /// detail column only while this is non-nil, so clearing it to present
    /// a terminal would pop straight back to the Agent list.
    private var selectedItem: Binding<ConsoleSelection?> {
        Binding(
            get: {
                guard let shown = detailOnStage else { return nil }
                // Beside the list only: pushed over it, the row is out of reach.
                return horizontalSizeClass == .regular
                    ? detailCores.listSelection(for: shown, console: console) : shown
            },
            set: { selection in
                switch selection {
                case .agent(let id): selectAgent(id)
                case .terminal(let id):
                    if let terminal = console.terminals.first(where: { $0.id == id }) {
                        selectTerminal(terminal)
                    }
                case .leftBehind: break
                case nil: clearSelection()
                }
                if selection != nil { detailDidOpenFromSidebar() }
            })
    }

    /// A pick in portrait hides the sidebar shown for it, whether a row
    /// was tapped or something made from the sidebar opened.
    private func detailDidOpenFromSidebar() {
        withAnimation(reduceMotion ? nil : .snappy) {
            splitVisibilities[currentTab]?.selectionDidOpenDetail()
        }
    }

    /// A shell made from `tab` (its list's New Terminal row, or the drawer
    /// of a shell it shows) opens there. Made after the user moved to the
    /// other list, it waits as `tab`'s pick instead of replacing what that
    /// list shows.
    private func openTerminal(
        _ terminal: ConsoleTerminal, from tab: ConsoleTab, bySidebar: Bool = false
    ) {
        if shownListTab == tab {
            selectTerminal(terminal)
            if bySidebar, currentTab == tab { detailDidOpenFromSidebar() }
        } else if horizontalSizeClass == .regular, !terminal.isAgent {
            rememberedSelections[tab] = .terminal(terminal)
        }
    }

    /// Something the window presents over the Console that registers
    /// nowhere: a sheet or alert from Hosts, Settings or a list. An active
    /// search field presents on some layouts too, and is not cover.
    private var isPresentingOverConsole: Bool {
        guard let presented = sceneWindow?.window?.rootViewController?.presentedViewController
        else { return false }
        return !(presented is UISearchController)
    }

    /// Where previous and next start from off the Agents list: the Agent
    /// it keeps, on stage under Hosts or Settings or parked under Terminals.
    private var agentsListAnchor: ConsoleAgent.ID? {
        guard currentTab != .agents else { return nil }
        if shownListTab == .agents { return notificationRouter.path.last }
        if case .agent(let id) = rememberedSelections[.agents] { return id }
        return nil
    }

    private func shellRoute(over id: ConsoleAgent.ID) -> Binding<WorkspaceTerminalRoute?> {
        Binding(
            get: { agentShellRoute?.agentID == id ? agentShellRoute?.route : nil },
            set: { route in
                if let route {
                    agentShellRoute = AgentShellRoute(agentID: id, route: route)
                } else if agentShellRoute?.agentID == id {
                    agentShellRoute = nil
                }
            })
    }

    private func selectAgent(_ id: ConsoleAgent.ID) {
        changeSelection {
            openAnew(.agent(id))
            showAgentsList(parking: parkedSelection)
            selectedTerminal = nil
            notificationRouter.path = [id]
        }
    }

    private func selectTerminal(_ terminal: ConsoleTerminal) {
        if let agentID = terminal.agentID {
            selectAgent(agentID)
        } else {
            changeSelection {
                openAnew(.terminal(terminal.id))
                notificationRouter.path = []
                selectedTerminal = terminal
            }
        }
    }

    private func clearSelection() {
        changeSelection {
            notificationRouter.path = []
            selectedTerminal = nil
        }
    }

    /// A selection that replaces one detail screen with another dissolves
    /// between them. A first selection or a cleared one is the split view's
    /// own navigation and needs nothing from here.
    private func changeSelection(_ change: () -> Void) {
        let before = selectedItem.wrappedValue
        change()
        let after = selectedItem.wrappedValue
        guard let before, let after, before != after,
              let window = sceneWindow?.window
        else { return }
        detailCrossfade.beginSwap(in: window)
    }

    /// The split view owns the window's status-bar appearance on iPhone. A
    /// pushed terminal cannot reliably override it from the detail subtree.
    private var terminalStatusBarColorScheme: ColorScheme? {
        terminalOwnsTopEdge ? stagedTerminalChromeScheme : nil
    }

    /// A terminal reaches the window's top edge unless an opaque sidebar
    /// shares that edge and the two disagree: the status bar spans both
    /// columns and takes one scheme, so white text over a dark terminal
    /// would vanish over a light sidebar. The detail then keeps the app's
    /// own band above the terminal, with the status bar in it. A glass
    /// sidebar floats below the status bar, over the terminal. An iPhone
    /// wide enough for both columns shows no status bar in landscape.
    private var terminalOwnsTopEdge: Bool {
        horizontalSizeClass != .regular
            || UIDevice.current.userInterfaceIdiom != .pad
            || sidebarFloatsOverDetail
            || splitVisibility(for: currentTab).isSidebarVisible != true
            || stagedTerminalChromeScheme.map { $0 == colorScheme } ?? true
    }

    /// What going back from a regular-width detail does instead: the detail
    /// stands beside its list there, on an iPad or a wide iPhone alike, so
    /// the sidebar comes out rather than the detail leaving the screen. Nil
    /// in compact width, where the detail is pushed and goes back.
    private func sidebarReveal(for tab: ConsoleTab) -> (@MainActor @Sendable () -> Void)? {
        guard horizontalSizeClass == .regular else { return nil }
        return { [splitVisibilities = $splitVisibilities, reduceMotion] in
            withAnimation(reduceMotion ? nil : .snappy) {
                splitVisibilities.wrappedValue[tab, default: ConsoleSplitVisibilityState()]
                    .showSidebar()
            }
        }
    }

    /// The chrome scheme of the terminal the detail shows, if any.
    private var stagedTerminalChromeScheme: ColorScheme? {
        // Hosts and Settings keep the selection but show no terminal.
        guard currentTab.isList else { return nil }
        if selectedTerminal != nil {
            return terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme)
        }
        guard let id = notificationRouter.path.last, agentShowingChanges != id,
            agentShowingChat != id
        else { return nil }
        let showsTerminalSurface = console.agents.contains(where: { $0.id == id })
            || console.departedAgents.contains(where: { $0.id == id })
        let showsTerminalSyncSurface = !showsTerminalSurface
            && MissingAgentPresentation(agentID: id, console: console, hosts: hosts)
                .renderingMode == .progress
        guard showsTerminalSurface || showsTerminalSyncSurface else { return nil }
        return terminal.themes.selection(for: colorScheme)
            .chromeColorScheme(for: colorScheme)
    }

    /// The detail column. Not keyed off the live Agent list alone: the
    /// selection and terminal remain mounted while recovery temporarily empties
    /// the inventory. A fresh snapshot still decides whether the Agent exists.
    @ViewBuilder
    private func detail(in tab: ConsoleTab) -> some View {
        if let id = notificationRouter.path.last {
            if let receipt = matchingRemovedWorktreeReceipt(for: id) {
                removedWorktreeSurface(receipt)
            } else if let agent = console.detailAgent(for: id) {
                AgentDetailView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    inputMode: inputMode,
                    detailSurface: detailSurface,
                    hosts: hosts.consoleHosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    stage: AgentDetailStage(
                        // The router's truth, not SwiftUI's appear/disappear:
                        // only the screen still selected may rebuild its
                        // terminal on a spurious reappearance.
                        isVisible: { [notificationRouter] in
                            notificationRouter.path.last == id
                                && console.detailAgent(for: id) != nil
                                && currentTab == tab
                        },
                        hostID: id.hostID,
                        console: console,
                        sceneRouting: sceneRouting),
                    onSwitch: { selectAgent($0) },
                    onClosed: { clearSelection() },
                    onSelectTerminal: { selectTerminal($0) },
                    onShowsChanges: { shows in
                        if shows {
                            agentShowingChanges = id
                        } else if agentShowingChanges == id {
                            agentShowingChanges = nil
                        }
                    },
                    onShowsChat: { shows in
                        if shows {
                            agentShowingChat = id
                        } else if agentShowingChat == id {
                            agentShowingChat = nil
                        }
                    },
                    repeatLandings: notificationRouter.repeatLandings,
                    shellRoute: shellRoute(over: id),
                    composerSession: detailCores.session(for: agent, console: console),
                    arcProject: arcProject(for: agent),
                    arcBoard: arcBoardSnapshot(for: agent),
                    arcRefreshBoard: {
                        await arcBoard.refreshBoards(hosts: hosts.consoleHosts) { [console] id in
                            console.chatHostFiles(for: id)
                        }
                    },
                    onOpenUsage: console.isUsageEnabled ? { showUsage() } : nil)
                // Selecting another Agent must tear down the previous terminal
                // pipeline; without the explicit identity the detail column
                // would reuse the old view's state.
                .id(ConsoleDetailIdentity(shown: .agent(id), opening: detailOpening))
            } else {
                // The Agent is gone from the list, but not necessarily
                // because its pane went: a failed Host empties the list the
                // same way, and blaming the Agent for that hides the only
                // text that says what to do about it (#146).
                // The stores, not their contents: which collections this reads
                // is the part a test can then assert, and the part #146 got
                // wrong.
                let presentation = MissingAgentPresentation(
                    agentID: id, console: console, hosts: hosts)
                missingAgentSurface(presentation)
            }
        } else if let selectedTerminal {
            WorkspaceTerminalDetailView(
                terminal: console.terminals.first(where: { $0.id == selectedTerminal.id })
                    ?? selectedTerminal,
                console: console,
                corePin: detailCores.pin(for: selectedTerminal, console: console),
                settings: terminal,
                activity: activity,
                onSelectAgent: { selectAgent($0) },
                onSelectTerminal: { openTerminal($0, from: tab) },
                // The tab too: a tab switch remounts this in the next tab's
                // split view, and the leaving one must let the terminal go.
                isSelected: {
                    self.selectedTerminal?.id == selectedTerminal.id
                        && notificationRouter.path.isEmpty
                        && currentTab == tab
                },
                keyboardHandoff: keyboardHandoff,
                onBack: { clearSelection() })
                .id(ConsoleDetailIdentity(shown: .terminal(selectedTerminal.id), opening: detailOpening))
        } else {
            ConsoleEmptyDetailView(
                presentation: ConsoleEmptyDetailPresentation(
                    hasHosts: !hosts.consoleHosts.isEmpty,
                    showsAgentsAction: splitVisibility(for: tab).showsAgentsAction,
                    listsTerminals: tab == .terminals,
                    offersNewItem: offersNewItem(on: tab))
            ) { action in
                switch action {
                case .showAgents:
                    withAnimation(reduceMotion ? nil : .snappy) {
                        splitVisibilities[tab, default: ConsoleSplitVisibilityState()]
                            .showSidebar()
                    }
                case .newAgent:
                    if tab == .terminals {
                        isStartingTerminal = true
                    } else {
                        startAgentRequest = StartAgentRequest()
                    }
                case .hosts: presentHosts()
                }
            }
        }
    }

    /// A receipt is keyed by the Agent set captured at the authorized write.
    /// If the same pane id has already returned, require the live row to match
    /// the exact removed workspace/worktree identity before showing it.
    private func matchingRemovedWorktreeReceipt(
        for id: ConsoleAgent.ID
    ) -> WorktreeRemovalReceipt? {
        RemovedWorktreeSelection.receipt(
            for: id,
            agents: console.agents,
            receipts: console.removedWorktreesByAgent)
    }

    private func removedWorktreeSurface(
        _ receipt: WorktreeRemovalReceipt
    ) -> some View {
        ContentUnavailableView {
            Label("Worktree Removed", systemImage: "checkmark.circle")
        } description: {
            Text(
                "The checkout at \(receipt.request.identity.checkoutPath) was removed and its workspace was closed. No branch was deleted."
            )
        } actions: {
            Button("Back to Console") { notificationRouter.path = [] }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
        }
    }

    @ViewBuilder
    private func missingAgentSurface(_ presentation: MissingAgentPresentation) -> some View {
        if presentation.renderingMode == .progress {
            let theme = terminal.themes.selection(for: colorScheme)
            ZStack {
                theme.surfaceBackground(for: colorScheme)
                    .ignoresSafeArea(edges: detailSurfaceEdges(for: currentTab))
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: theme.palette(for: colorScheme),
                    dimsBackground: false)
            }
        } else {
            ContentUnavailableView(
                presentation.title, systemImage: presentation.systemImage,
                description: Text(presentation.message))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch agentsSurface {
        case .noHosts:
            noHostsView
        case .noAgents:
            ContentUnavailableView {
                Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
            } description: {
                Text("Agents detected on your Hosts appear here.")
            }
        case .noAgentsOnHost(let hostName):
            ContentUnavailableView {
                Label(
                    !hostName.isEmpty
                        ? String(localized: "No Agents on \(hostName)")
                        : hostFilter.count == 1
                            ? String(localized: "No Agents on this Host")
                            : String(localized: "No Agents on the Selected Hosts"),
                    systemImage: "line.3.horizontal.decrease.circle")
            } actions: {
                Button("Show All Hosts") { hostFilter.removeAll() }
                    .hoverEffect(.highlight)
            }
        case .noSearchResults:
            if agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No Matching Agents", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show All") { listPresentation.clearStatusFilter() }
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("agents.status-filter.clear-empty")
                }
            } else if !listPresentation.statusFilter.isEmpty {
                // The filter may be what hides the match, and it outlives the search.
                ContentUnavailableView {
                    Label("No Results for \u{201C}\(agentSearchText)\u{201D}", systemImage: "magnifyingglass")
                } description: {
                    Text("The status filter is on.")
                } actions: {
                    Button("Show All Statuses") { listPresentation.clearStatusFilter() }
                        .hoverEffect(.highlight)
                        .accessibilityIdentifier("agents.status-filter.clear-search")
                }
            } else {
                ContentUnavailableView.search(text: agentSearchText)
            }
        case .rows:
            List(selection: selectedItem) {
                switch listPresentation.mode {
                case .flat: flatAgentListRows
                case .grouped: groupedAgentListRows
                case .byWorkspace: workspaceAgentListRows
                case .arc: arcAgentListRows
                }
            }
            .modifier(
                ConsoleAgentListStyle(
                    showsCards: listPresentation.mode == .byWorkspace))
            .modifier(ConsoleSidebarListTint())
            .modifier(AirBuildScrollEdgeEffectStyle(isEnabled: listPresentation.mode == .arc))
            // Folded, the title leads the page and search waits under a pull, as on the home screen.
            .searchDrawerStartsTucked(isDisabled: listPresentation.mode == .arc && !foldedHome)
        }
    }

    private var noHostsView: some View {
        ContentUnavailableView {
            Label("No Hosts", systemImage: "server.rack")
        } description: {
            Text("Add a machine that runs herdr to see its Agents and Terminals here.")
        } actions: {
            Button("Add Host") { presentHosts() }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
            Button("Setup Guide") { presentHostSetupGuide() }
                .hoverEffect(.highlight)
        }
    }

    @ViewBuilder
    private var agentHostIssueRows: some View {
        if !visibleHostIssues.isEmpty {
            // On the Agent rows' edges and, as they are, without rules.
            ConsoleHostIssueList(
                issues: visibleHostIssues, onOpenHost: { openHostIssue($0) },
                onShowAll: { isShowingHostIssues = true })
                .modifier(ListRowVerticalInsets(0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var flatAgentListRows: some View {
        agentHostIssueRows
        let qualifiers = agentTitleQualifiers
        let saved = console.savedChatEntries
        ForEach(filteredAgents) { @Sendable agent in
            MainActorContent { agentRow(agent, qualifier: qualifiers[agent.id], saved: saved[agent.id]) }
        }
    }

    /// A search or a status filter keeps the arc list's own semantics out of
    /// the way, in the arc list's own look: the projects the words name as
    /// tiles, then each Agent the filter admits under its project's name.
    @ViewBuilder
    private var arcAgentListRows: some View {
        if arcIsNarrowed {
            agentHostIssueRows
            let query = agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let projects = query.isEmpty
                ? [] : arcProjectGroups.flatMap(\.projects).filter { AirBuildProjectSearch.matches($0.label, query: query) }
            if !projects.isEmpty {
                AirBuildProjectGrid(
                    projects: projects, selected: arcSelectedProjectID, limitsToTwoRows: false,
                    onSelect: { id in
                        arcSelect(id)
                        agentSearchText = ""
                        isAgentSearchPresented = false
                    },
                    actions: { arcProjectActions($0) })
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            ForEach(filteredAgents) { @Sendable agent in
                MainActorContent {
                    arcAgentRow(
                        agent,
                        projectName: agent.workspaceLabel.flatMap { $0.isEmpty ? nil : $0 } ?? agent.agent.workspaceID)
                        .listRowBackground(Color.clear)
                }
            }
        } else {
            // No brand title: the grid leads the page. The pages' last tile opens
            // the same list; this one needs no swiping to find, in every layout.
            Button("Show All") { isShowingAllArcProjects = true }
                .font(.system(size: 15, weight: .semibold))
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            AirBuildProjectGrid(
                projects: arcProjectGroups.flatMap(\.projects),
                selected: arcSelectedProjectID,
                onSelect: { arcSelect($0) },
                onShowAll: { isShowingAllArcProjects = true },
                actions: { arcProjectActions($0) })
                .listRowInsets(EdgeInsets(top: usesSidebarNavigation || foldedHome ? 8 : 44, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            agentHostIssueRows
            arcSelectedProjectRows
        }
    }

    /// A sidebar has no title of its own to switch projects with, so its
    /// first row does.
    @ViewBuilder
    private var arcSwitcherRow: some View {
        if usesSidebarNavigation, let project = arcSelectedProject {
            ArcProjectSwitcher(
                project: project, sections: ArcProjectMenu.sections(arcProjectGroups),
                onSelect: { arcSelect($0) },
                onNewAgent: offersNewItem(on: .agents)
                    ? { startAgentRequest = StartAgentRequest(origin: arcNewAgentOrigin(for: project)) }
                    : nil)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 6))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .selectionDisabled()
        }
    }

    /// The selected project's conversations, without a card around them.
    @ViewBuilder
    private var arcSelectedProjectRows: some View {
        if let project = arcSelectedProject {
            if project.agents.isEmpty && project.shells.isEmpty {
                ArcProjectEmptyRow {
                    startAgentRequest = StartAgentRequest(origin: arcNewAgentOrigin(for: project))
                }
                .listRowBackground(Color.clear)
            } else {
                // Agents first, then the project's plain shells, as herdr lists them.
                ForEach(project.agents) { @Sendable agent in
                    MainActorContent {
                        arcAgentRow(agent)
                            .listRowBackground(Color.clear)
                    }
                }
                ForEach(project.shells) { @Sendable shell in
                    MainActorContent {
                        NavigationLink(value: ConsoleSelection.terminal(shell.id)) {
                            ArcShellRow(
                                terminal: shell,
                                number: ArcShellRow.number(of: shell, among: project.shells),
                                isSelected: selectedItem.wrappedValue == .terminal(shell.id))
                                .modifier(ConsoleRowSelectionContent())
                        }
                        .modifier(
                            ConsoleRowSelectionBackground(
                                isSelected: selectedItem.wrappedValue == .terminal(shell.id)))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .navigationLinkIndicatorVisibility(.hidden)
                    }
                }
            }
        }
    }

    /// The other projects' Blocked Agents, under a count of them.
    @ViewBuilder
    private var arcWaitingRows: some View {
        let waiting = arcWaitingAgents
        if !waiting.isEmpty {
            Section {
                ForEach(waiting) { @Sendable agent in
                    MainActorContent {
                        // Another project's conversation; the row says which,
                        // with the label the workspace list gives it.
                        arcAgentRow(
                            agent,
                            projectName: agent.workspaceLabel.flatMap {
                                $0.isEmpty ? nil : $0
                            } ?? agent.agent.workspaceID)
                    }
                }
            } header: {
                ArcWaitingHeader(count: waiting.count)
            }
        }
    }

    @ViewBuilder
    private var workspaceAgentListRows: some View {
        if !visibleHostIssues.isEmpty {
            Section {
                // Off the cards, on the page: out to the cards' edges, as
                // in the Terminals list's By Workspace.
                ConsoleHostIssueList(
                    issues: visibleHostIssues, onOpenHost: { openHostIssue($0) },
                    onShowAll: { isShowingHostIssues = true })
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        let qualifiers = agentTitleQualifiers
        let saved = console.savedChatEntries
        ForEach(workspaceCards) { @Sendable card in
            MainActorContent {
                Section {
                    ForEach(card.rows) { @Sendable placed in
                        MainActorContent {
                            workspaceCardRow(placed, in: card, qualifiers: qualifiers, saved: saved)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceCardRow(
        _ placed: ConsoleWorkspaceCard.Placed, in card: ConsoleWorkspaceCard,
        qualifiers: [ConsoleAgent.ID: String], saved: [ConsoleAgent.ID: HostReadiness]
    ) -> some View {
        switch placed.row {
        case .header:
            let primary = card.primary
            let title = card.isRepository ? primary.checkout?.repoName ?? primary.title : primary.title
            ConsoleWorkspaceCardHeader(
                card: card, title: title,
                subtitle: [primary.hostName, primary.pathText].compactMap { $0 }.joined(separator: " · "),
                checkouts: card.isRepository && card.isCollapsed ? checkoutSummaries(card) : [],
                onToggle: { toggleWorkspaceSection(primary.id) }
            )
            .modifier(ConsoleWorkspaceCardRow(placed: placed, indent: .icon, top: 8, bottom: 4))
            .selectionDisabled()
        case .summary:
            ConsoleWorkspaceCardSummary(
                card: card,
                checkouts: card.isRepository ? checkoutSummaries(card) : [],
                onToggle: { toggleWorkspaceSection(card.primary.id) }
            )
            .modifier(foldReveal(placed, in: card))
            .modifier(
                ConsoleWorkspaceCardRow(
                    placed: placed, indent: .text, top: 0, bottom: 6, fillsShortestRow: false))
            .selectionDisabled()
        case .checkout(let section):
            ConsoleCheckoutHeader(
                section: section, title: checkoutTitle(section),
                onToggle: section.isNested ? { toggleWorkspaceSection(section.id) } : nil
            )
            .modifier(foldReveal(placed, in: card))
            .modifier(ConsoleWorkspaceCardRow(placed: placed, indent: .icon, top: 0, bottom: 0))
            .selectionDisabled()
        case .agent(let agent, let section, let standsAlone):
            agentLink(
                agent,
                isSaved: saved[agent.id] != nil,
                // A saved Agent's Workspace may be gone with its Host session,
                // and its detail's New Agent shows only where the Host starts Agents.
                newAgentOrigin: saved[agent.id] == nil && console.capabilities(for: agent.hostID).startsAgents
                    ? StartAgentStore.LaunchOrigin(beside: agent, in: console) : nil,
                background: ConsoleWorkspaceCardRow(
                    placed: placed, indent: .icon,
                    top: standsAlone ? (placed.followsHeader ? 0 : 6) : 2, bottom: standsAlone ? 6 : 4,
                    isSelected: notificationRouter.path.last == agent.id)
            ) {
                cardAgentLabel(
                    agent, of: section, standsAlone: standsAlone, in: card,
                    qualifier: qualifiers[agent.id], saved: saved[agent.id], readsChanges: true)
                .modifier(foldReveal(placed, in: card))
            } preview: {
                cardAgentLabel(
                    agent, of: section, standsAlone: standsAlone, in: card,
                    qualifier: qualifiers[agent.id], saved: saved[agent.id], readsChanges: false)
            }
        }
    }

    /// An Agent as its card shows it, its mark in the card's icon column:
    /// an Agent that is its checkout's or Workspace's only one takes that
    /// title and icon; a row leaves to the card what the card already says.
    private func cardAgentLabel(
        _ agent: ConsoleAgent, of section: ConsoleWorkspaceSection, standsAlone: Bool,
        in card: ConsoleWorkspaceCard, qualifier: String?, saved: HostReadiness?, readsChanges: Bool
    ) -> some View {
        let showsHost = standsAlone && !card.isRepository
        let heading = standsAlone
            ? AgentCardHeading(
                title: card.isRepository ? checkoutTitle(section) : ConsoleCheckoutTitle(title: section.title),
                isProminent: !card.isRepository,
                systemImage: ConsoleWorkspaceCardIcon.systemName(for: section.checkout))
            : nil
        return AgentCardView(
            agent: agent,
            layout: console.rowLayout(for: agent.hostID),
            isPinned: console.pins.isPinned(
                hostID: agent.hostID, paneID: agent.agent.paneID),
            changes: readsChanges ? console.rowChanges.store(for: agent) : nil,
            qualifier: standsAlone ? nil : qualifier,
            saved: saved,
            hiddenTokens: ConsoleWorkspaceCard.hiddenTokens(
                for: agent, checkoutPath: section.checkout?.checkoutPath, showsHost: showsHost),
            heading: heading,
            showsHost: showsHost,
            lead: .card)
    }

    /// A repository's checkout, titled by the branch its Agents' latest
    /// Changes reads found, or before any did, the branch saved from the
    /// last read.
    private func checkoutTitle(_ section: ConsoleWorkspaceSection) -> ConsoleCheckoutTitle {
        let reads = section.agents.compactMap { agent -> CheckoutChanges? in
            guard case .loaded(let changes) = console.rowChanges.store(for: agent)?.phase else { return nil }
            return changes
        }
        let path = section.checkout?.checkoutPath
        return ConsoleCheckoutTitle(
            label: section.title,
            isMainCheckout: section.checkout?.isLinkedWorktree != true,
            branch: ConsoleCheckoutTitle.branch(at: path, in: reads)
                ?? console.savedBranch(on: section.id.hostID, atCheckoutPath: path))
    }

    private func checkoutSummaries(_ card: ConsoleWorkspaceCard) -> [ConsoleCheckoutSummary] {
        card.checkouts.map { section in
            ConsoleCheckoutSummary(
                id: section.id, title: checkoutTitle(section), checkout: section.checkout,
                agents: section.agents)
        }
    }

    private func toggleWorkspaceSection(_ id: ConsoleWorkspaceSection.ID) {
        // A search opens every card holding a match, so a toggle then would
        // change nothing on screen.
        guard agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !reduceMotion else {
            listPresentation.toggleWorkspace(id)
            return
        }
        guard leavingSection == nil else { return }
        // Opening a worktree takes nothing away; every other fold first
        // fades the rows it takes, which the list would fade only slowly,
        // under the rows coming in.
        let opensWorktree = workspaceCards.lazy.flatMap(\.nested).first { $0.id == id }?.isCollapsed == true
        guard !opensWorktree else {
            fold(id)
            return
        }
        withAnimation(.easeOut(duration: 0.12)) { leavingSection = id }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            fold(id)
        }
    }

    private func fold(_ id: ConsoleWorkspaceSection.ID) {
        foldGeneration += 1
        let generation = foldGeneration
        // All in the fold's animation: a change outside it, made in the
        // same update, would take the list's animation away.
        withAnimation(.snappy) {
            leavingSection = nil
            foldingSection = id
            listPresentation.toggleWorkspace(id)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if foldGeneration == generation { foldingSection = nil }
        }
    }

    /// Whether folding `section` brings `placed` in or takes it away: a
    /// card's rows under its header when the card folds, a worktree's
    /// Agents when it does.
    private func fold(
        _ section: ConsoleWorkspaceSection.ID?, moves placed: ConsoleWorkspaceCard.Placed,
        in card: ConsoleWorkspaceCard
    ) -> Bool {
        guard let section else { return false }
        return switch placed.row {
        case .header: false
        case .summary, .checkout: section == card.id
        case .agent(_, let agentSection, _): section == card.id || section == agentSection.id
        }
    }

    /// How `placed` moves with a fold: out before the fold takes it, or in
    /// after the rows the fold brings in before it.
    private func foldReveal(_ placed: ConsoleWorkspaceCard.Placed, in card: ConsoleWorkspaceCard) -> ConsoleFoldReveal {
        let isLeaving = fold(leavingSection, moves: placed, in: card)
        guard fold(foldingSection, moves: placed, in: card) else {
            return ConsoleFoldReveal(isLeaving: isLeaving, isRevealing: false, delay: 0)
        }
        let order = card.rows.prefix { $0.id != placed.id }
            .filter { fold(foldingSection, moves: $0, in: card) }.count
        return ConsoleFoldReveal(isLeaving: isLeaving, isRevealing: true, delay: Double(order) * 0.04)
    }

    @ViewBuilder
    private var groupedAgentListRows: some View {
        let qualifiers = agentTitleQualifiers
        let saved = console.savedChatEntries
        ForEach(hostSections) { @Sendable section in
            MainActorContent {
                let opensDetail = connectionDetail(for: section.hostID) != nil
                Section {
                    if !section.isCollapsed && !opensDetail {
                        // As in the Terminals tab: an expanded Host with a
                        // condition says what it is before any Agents it lists.
                        if let issue = section.statusPresentation {
                            ConsoleHostIssueRow(issue: issue) { openHostIssue($0) }
                                .listRowSeparator(.hidden)
                        }
                        ForEach(section.agents) { @Sendable agent in
                            MainActorContent { agentRow(agent, qualifier: qualifiers[agent.id], saved: saved[agent.id]) }
                        }
                    }
                } header: {
                    ConsoleHostSectionHeaderView(
                        presentation: ConsoleHostSectionHeaderPresentation(
                            section: section, opensConnectionDetail: opensDetail)
                    ) {
                        if opensDetail {
                            openHostIssue(section.hostID)
                        } else {
                            toggleHostSection(section.hostID)
                        }
                    }
                    .textCase(nil)
                }
            }
        }
    }

    /// An Agent's row in the plain lists: no rules between rows, and closer
    /// together than the list would set them, as their marks set them apart.
    /// `hiding` drops fields an arc card's header already says.
    private func agentRow(
        _ agent: ConsoleAgent, qualifier: String?, saved: HostReadiness?,
        hiding hiddenTokens: Set<AgentRowToken> = []
    ) -> some View {
        agentLink(
            agent,
            isSaved: saved != nil,
            background: ConsoleRowSelectionBackground(
                isSelected: selectedItem.wrappedValue == .agent(agent.id))
        ) {
            AgentCardView(
                agent: agent,
                layout: console.rowLayout(for: agent.hostID),
                isPinned: console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID),
                changes: console.rowChanges.store(for: agent),
                qualifier: qualifier,
                saved: saved,
                hiddenTokens: hiddenTokens)
        } preview: {
            AgentCardView(
                agent: agent,
                layout: console.rowLayout(for: agent.hostID),
                isPinned: console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID),
                qualifier: qualifier,
                saved: saved,
                hiddenTokens: hiddenTokens)
        }
        .listRowSeparator(.hidden)
        .modifier(ListRowVerticalInsets(4))
    }

    /// An Agent's row: `label` opens its detail, with the row's pin, close,
    /// and window actions, and New Agent beside it when `newAgentOrigin` is
    /// set. `background` draws the row's place in the list; `preview` is
    /// what a lifted card shows (see `ConsoleRowContextMenu`).
    private func agentLink<RowContent: View, Background: ViewModifier, Preview: View>(
        _ agent: ConsoleAgent, isSaved: Bool, newAgentOrigin: StartAgentStore.LaunchOrigin? = nil,
        background: Background,
        @ViewBuilder label: () -> RowContent, @ViewBuilder preview: () -> Preview
    ) -> some View {
        let offers = ConsoleAgentRowOffers(
            capabilities: console.capabilities(for: agent.hostID),
            supportsMultipleWindows: supportsMultipleWindows)
        return NavigationLink(value: ConsoleSelection.agent(agent.id)) {
            label()
                .modifier(ConsoleRowSelectionContent())
        }
        // The list reads what it shows: a row on screen reads its Agent's
        // Checkout, and an exit from Working while none does waits for one.
        .onAppear { console.rowChanges.rowAppeared(agent) }
        .onDisappear { console.rowChanges.rowDisappeared(agent.id) }
        .onChange(of: agent.directory == nil) { _, lacksDirectory in
            if !lacksDirectory { console.rowChanges.agentReportedDirectory(agent) }
        }
        .modifier(background)
        .hoverEffect(.highlight)
        .modifier(
            ConsoleRowContextMenu {
                let pinned = console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID)
                Button(
                    pinned ? "Unpin" : "Pin",
                    systemImage: pinned ? "pin.slash" : "pin"
                ) {
                    console.togglePin(
                        hostID: agent.hostID, paneID: agent.agent.paneID)
                }
                if console.offersTitleRename(for: agent) {
                    Button("Rename", systemImage: "pencil") {
                        titleRename = console.titleRenameStore(for: agent)
                    }
                }
                // Never on iPhone, and not for the Agent this window already shows.
                if offers.opensInNewWindow, notificationRouter.path.last != agent.id {
                    Button("Open in New Window", systemImage: "plus.rectangle.on.rectangle") {
                        openInNewWindow(agent)
                    }
                }
                // In the Agent's Workspace and directory, as its detail's
                // New Agent starts one.
                if let newAgentOrigin {
                    Button("New Agent", systemImage: "plus") {
                        startAgentRequest = StartAgentRequest(origin: newAgentOrigin)
                    }
                }
                // Asks first, like the swipe. A menu item can be destructive:
                // the row stays put until the close succeeds.
                if isSaved {
                    Divider()
                    Button(SavedChatRemovalCopy.action, systemImage: "trash", role: .destructive) {
                        pendingSavedChatRemoval = agent
                    }
                } else if offers.closes {
                    Divider()
                    Button(
                        closeScope(for: agent).actionTitle, systemImage: "trash",
                        role: .destructive
                    ) {
                        pendingTabClose = agent
                    }
                }
            } preview: {
                preview()
            })
        .modifier(
            AgentWindowDrag(
                route: AgentRoute(agentID: agent.id),
                title: agent.agent.displayName,
                isEnabled: offers.opensInNewWindow))
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let pinned = console.pins.isPinned(
                hostID: agent.hostID, paneID: agent.agent.paneID)
            Button {
                togglePinAfterSwipe(agent)
            } label: {
                Label(
                    pinned ? "Unpin" : "Pin",
                    systemImage: pinned ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        // A full swipe makes closing one gesture away, so every close asks
        // first. No `.destructive` role: List would animate the row out
        // while the confirmation is still up, even if the user cancels.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if isSaved || offers.closes {
                Button {
                    if isSaved {
                        pendingSavedChatRemoval = agent
                    } else {
                        pendingTabClose = agent
                    }
                } label: {
                    Label(isSaved ? SavedChatRemovalCopy.confirm : String(localized: "Close"), systemImage: "trash")
                }
                .tint(.red)
            }
        }
    }

    /// Pinning moves the row. Reordering while the swipe is still closing
    /// tears the action button away from its row, and for a while after the
    /// collapse the swiped cell still cannot move: List removes and
    /// reinserts it instead, so it vanishes and pops in at the new slot.
    /// Measured on iOS 27 that settles after ~0.8 s; the wait keeps margin.
    private func togglePinAfterSwipe(_ agent: ConsoleAgent) {
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            withAnimation(reduceMotion ? nil : .snappy) {
                console.togglePin(hostID: agent.hostID, paneID: agent.agent.paneID)
            }
        }
    }

    private func closeTabNow(_ agent: ConsoleAgent) {
        Task {
            do {
                try await console.closeAgent(agent)
            } catch {
                tabCloseError = ConsoleStore.tabCloseFailureMessage(for: error)
            }
        }
    }

    /// Whether the close confirmation is up for whichever Agent the swipe
    /// or context menu queued.
    private var tabCloseDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingTabClose != nil },
            set: { shown in if !shown { pendingTabClose = nil } })
    }

    private var tabCloseErrorPresented: Binding<Bool> {
        Binding(
            get: { tabCloseError != nil },
            set: { shown in if !shown { tabCloseError = nil } })
    }

    private func confirmTabClose() {
        guard let agent = pendingTabClose else { return }
        pendingTabClose = nil
        closeTabNow(agent)
    }

    private func savedChatRemovalMessage(for agent: ConsoleAgent) -> String {
        SavedChatRemovalCopy.message(
            naming: AgentCardPresentation(
                agent: agent, layout: console.rowLayout(for: agent.hostID)
            ).switcherTitle)
    }

    /// An open detail goes with its entry, which it can no longer show.
    private func removeSavedChat(_ agent: ConsoleAgent) {
        let isSelected = notificationRouter.path.last == agent.id
        if console.removeSavedChat(agent), isSelected { clearSelection() }
    }

    /// What closing this Agent takes down, widest first.
    private func closeScope(for agent: ConsoleAgent) -> TerminalCloseScope {
        if console.closesWorkspaceWithTab(of: agent) { return .workspace }
        return console.closesTab(of: agent) ? .tab : .pane
    }

    /// The pending close's reach; a Tab's while the alert dismisses.
    private var pendingCloseScope: TerminalCloseScope {
        pendingTabClose.map(closeScope(for:)) ?? .tab
    }

    private var tabCloseDialogTitle: String { pendingCloseScope.confirmationTitle }

    private var tabCloseConfirmLabel: String { pendingCloseScope.actionTitle }

    /// Confirmation copy naming the Agent as its row does, and the
    /// workspace when it dies with the tab.
    private func tabCloseMessage(for agent: ConsoleAgent) -> String {
        let name = AgentCardPresentation(
            agent: agent, layout: console.rowLayout(for: agent.hostID)
        ).switcherTitle
        if console.closesWorkspaceWithTab(of: agent) {
            guard let workspace = agent.workspaceLabel else {
                return String(localized: "Are you sure you want to also close this workspace? It is the workspace's last tab.")
            }
            return String(localized: "Are you sure you want to also close workspace \(workspace)? It is the workspace's last tab.")
        }
        if console.closesTab(of: agent) {
            return String(localized: "Closes the tab running \u{201C}\(name)\u{201D}.")
        }
        return String(localized: "Closes the pane running \u{201C}\(name)\u{201D}. The tab's other panes stay open.")
    }

    /// A window already showing this Agent comes forward instead of a second
    /// one opening: two windows on one Agent would contend for its Host's
    /// single terminal channel.
    private func openInNewWindow(_ agent: ConsoleAgent) {
        if sceneRouting?.directory.activateScene(presenting: agent.id) == true { return }
        openWindow(value: AgentRoute(agentID: agent.id))
    }

    /// Deep links raised inside this window obey the same single-window rule
    /// as a notification tap.
    private func openNotificationTarget(_ target: AgentNotificationTarget?) {
        if let sceneRouting {
            sceneRouting.open(target)
        } else {
            notificationRouter.open(target)
        }
    }

    private var agentsSurface: ConsoleAgentsSurface {
        ConsoleAgentsSurface(
            hostCount: hosts.consoleHosts.count,
            filteredHostName: hostFilter.isEmpty ? nil : filteredHostName,
            filteredAgentCount: filteredAgents.count,
            visibleIssueCount: visibleHostIssues.count,
            presentationMode: listPresentation.mode,
            projectedSectionCount: hostSections.count,
            projectCount: arcProjectGroups.reduce(0) { $0 + $1.projects.count },
            searchQuery: agentSearchText,
            isStatusFiltered: !listPresentation.statusFilter.isEmpty)
    }

    private var hostSections: [ConsoleHostSection] {
        listPresentation.sections(
            hosts: hosts.consoleHosts,
            console: console,
            filteredHostIDs: hostFilter,
            searchQuery: agentSearchText)
    }

    private var workspaceCards: [ConsoleWorkspaceCard] {
        ConsoleWorkspaceCard.cards(
            listPresentation.workspaceSections(
                hosts: hosts.consoleHosts, console: console,
                filteredHostIDs: hostFilter, searchQuery: agentSearchText))
    }

    // MARK: Arc (Projects)

    private var arcProjectGroups: [ArcProjectGroup] {
        let scoped = hostFilter.isEmpty
            ? hosts.consoleHosts : hosts.consoleHosts.filter { hostFilter.contains($0.id) }
        return ArcProjectGroup.groups(
            hosts: scoped, agents: filteredAgents, workspacesByHost: arcWorkspacesByHost,
            terminals: console.terminals)
    }

    /// Every Host's projects, past the list's filters and search: what
    /// Waiting and Progress read.
    private var arcAllGroups: [ArcProjectGroup] {
        ArcProjectGroup.groups(
            hosts: hosts.consoleHosts, agents: console.chatDisplayAgents,
            workspacesByHost: arcWorkspacesByHost, terminals: console.terminals)
    }

    /// The live Workspace list, else the one the Host's last snapshot saved
    /// for a Host this launch has not proven yet. An invalidated snapshot
    /// leaves the live list empty rather than unknown.
    private var arcWorkspacesByHost: [Host.ID: [ConsoleWorkspace]] {
        var merged = console.savedWorkspacesByHost
        for (hostID, live) in console.workspacesByHost where !live.isEmpty {
            merged[hostID] = live
        }
        return merged
    }

    private func arcProject(for agent: ConsoleAgent) -> ArcProjectGroup.Project? {
        arcAllGroups.lazy.flatMap(\.projects).first {
            $0.id.hostID == agent.hostID && $0.id.workspaceID == agent.agent.workspaceID
        }
    }

    private func arcBoardSnapshot(for agent: ConsoleAgent) -> ArcProjectBoard? {
        ArcBoardLookup.board(
            for: .init(hostID: agent.hostID, workspaceID: agent.agent.workspaceID),
            in: arcBoard.boards)
    }

    /// The selected project's identity, read back from the saved key or, the
    /// first time, the first project with Agents.
    private var arcSelectedProjectID: ConsoleWorkspaceSection.ID? {
        let projects = arcProjectGroups.flatMap(\.projects)
        let saved = ConsoleWorkspaceSection.ID(arcSelectionKey)
        if let saved, projects.contains(where: { $0.id == saved }) { return saved }
        return projects.first { !$0.agents.isEmpty }?.id ?? projects.first?.id
    }

    private var arcSelectedProject: ArcProjectGroup.Project? {
        guard let id = arcSelectedProjectID else { return nil }
        return arcProjectGroups.lazy.flatMap(\.projects).first { $0.id == id }
    }

    private func arcSelect(_ id: ConsoleWorkspaceSection.ID) {
        arcSelectionKey = id.storedText
        // Beside the list the detail follows the project picked, so its chat
        // and Progress never show another project's (ios-app showing FRS).
        guard usesSidebarNavigation,
            let project = arcProjectGroups.flatMap(\.projects).first(where: { $0.id == id })
        else { return }
        if let shown = notificationRouter.path.last, project.agents.contains(where: { $0.id == shown }) { return }
        if let shown = selectedTerminal, project.shells.contains(where: { $0.id == shown.id }) { return }
        if let agent = project.agents.first(where: { $0.agent.status == .blocked }) ?? project.agents.first {
            selectAgent(agent.id)
        } else if let shell = project.shells.first {
            selectTerminal(shell)
        } else {
            clearSelection()
        }
    }

    private func usesAirBuildArcChrome(for tab: ConsoleTab) -> Bool {
        tab == .agents && listPresentation.mode == .arc
    }

    private func listTitle(for tab: ConsoleTab) -> String { tab.title }

    /// The other projects' Blocked Agents: the ones the waiting section
    /// lists, and nothing from the project on screen.
    private var arcWaitingAgents: [ConsoleAgent] {
        let selected = arcSelectedProjectID
        return filteredAgents.filter {
            $0.agent.status == .blocked
                && ConsoleWorkspaceSection.ID(hostID: $0.hostID, workspaceID: $0.agent.workspaceID)
                    != selected
        }
    }

    /// Where a project's New Agent starts: its Workspace, in its first
    /// Agent's directory, or the Workspace's own checkout when it has none.
    private func arcNewAgentOrigin(
        for project: ArcProjectGroup.Project
    ) -> StartAgentStore.LaunchOrigin? {
        guard console.capabilities(for: project.id.hostID).startsAgents else { return nil }
        return StartAgentStore.LaunchOrigin(
            hostID: project.id.hostID, workspaceID: project.id.workspaceID,
            cwd: arcProjectDirectory(project))
    }

    private func arcProjectDirectory(_ project: ArcProjectGroup.Project) -> String {
        let workspace = console.workspaces(for: project.id.hostID)
            .first { $0.id == project.id.workspaceID }
        let asked = project.agents.first?.agent.cwd ?? workspace?.checkoutPath ?? ""
        return console.launchDirectory(
            ofWorkspace: project.id.workspaceID, asked: asked, on: project.id.hostID)
    }

    /// A project tile's long press: what its page offers, without opening it first.
    private func arcProjectActions(_ project: ArcProjectGroup.Project) -> AirBuildProjectActions {
        let hostID = project.id.hostID
        let capabilities = console.capabilities(for: hostID)
        let directory = arcProjectDirectory(project)
        var actions = AirBuildProjectActions()
        if let origin = arcNewAgentOrigin(for: project) {
            actions.newAgent = { startAgentRequest = StartAgentRequest(origin: origin) }
        }
        if let request = capabilities.newTerminalRequest(
            workspaceID: project.id.workspaceID, cwd: directory) {
            actions.newTerminal = {
                Task { @MainActor in
                    do {
                        let identity = try await console.createShellTerminal(request, on: hostID)
                        guard let terminal = await console.waitForTerminal(identity, on: hostID) else {
                            arcNewTerminalFailure = String(
                                localized: "The terminal was created, but its Workspace hasn't refreshed yet.")
                            return
                        }
                        arcSelect(project.id)
                        openTerminal(terminal, from: .agents, bySidebar: true)
                    } catch {
                        arcNewTerminalFailure = AgentOpenTerminalStore.presentation(for: error).message
                    }
                }
            }
        }
        if capabilities.renameWorkspace(id: project.id.workspaceID) {
            actions.rename = { arcRenamingProject = project }
        }
        if !directory.isEmpty {
            actions.copyPath = { UIPasteboard.general.string = directory }
        }
        return actions
    }

    /// Where previous and next can land.
    private var visibleAgentIDs: [ConsoleAgent.ID] {
        switch listPresentation.mode {
        case .flat: filteredAgents.map(\.id)
        case .grouped: hostSections.filter { !$0.isCollapsed }.flatMap { $0.agents.map(\.id) }
        case .byWorkspace: workspaceCards.flatMap(\.visibleAgentIDs)
        case .arc:
            (arcSelectedProject?.agents.map(\.id) ?? []) + arcWaitingAgents.map(\.id)
        }
    }

    private var presentationModeBinding: Binding<ConsoleListPresentationMode> {
        Binding(
            get: { listPresentation.mode },
            set: { listPresentation.select($0) })
    }

    private func toggleHostSection(_ hostID: Host.ID) {
        // A search opens every Host holding a match, so a toggle then would
        // change nothing on screen, only what the list returns to after.
        guard agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if reduceMotion {
            listPresentation.toggleCollapsed(hostID)
        } else {
            withAnimation(.snappy) {
                listPresentation.toggleCollapsed(hostID)
            }
        }
    }

    private var hostFilteredAgents: [ConsoleAgent] {
        guard !hostFilter.isEmpty else { return console.chatDisplayAgents }
        return console.chatDisplayAgents.filter { hostFilter.contains($0.hostID) }
    }

    /// After the Host filter and the search, before the status filter: what
    /// the status menu counts.
    private var searchedAgents: [ConsoleAgent] {
        let hostFiltered = hostFilteredAgents
        let needle = agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return hostFiltered }
        return hostFiltered.filter { $0.matchesAgentSearch(needle) }
    }

    private var filteredAgents: [ConsoleAgent] {
        let statusFilter = listPresentation.statusFilter
        return searchedAgents.filter { statusFilter.admits($0) }
    }

    private var statusFilterCounts: [ConsoleAgentStatusFilter: Int] {
        Dictionary(grouping: searchedAgents.compactMap { ConsoleAgentStatusFilter($0.agent.status) }) { $0 }
            .mapValues(\.count)
    }

    /// Program names for rows whose cards would otherwise read the same.
    /// Judged before the search, so a row's title does not change as the
    /// user types.
    private var agentTitleQualifiers: [ConsoleAgent.ID: String] {
        // By Workspace rows leave fields to their card's titles.
        let isByWorkspace = listPresentation.mode == .byWorkspace
        let savedStructures = isByWorkspace ? console.savedWorkspaceStructures : [:]
        return AgentTitleQualifier.qualifiers(for: hostFilteredAgents) { agent in
            let checkoutPath = agent.checkoutPath
                ?? savedStructures[agent.hostID]?.first { $0.id == agent.agent.workspaceID }?.checkout.checkoutPath
            let card = AgentCardPresentation(
                agent: agent, layout: console.rowLayout(for: agent.hostID),
                hiding: isByWorkspace
                    ? ConsoleWorkspaceCard.hiddenTokens(for: agent, checkoutPath: checkoutPath, showsHost: false)
                    : [],
                leadsWithMark: true)
            return .init(title: card.headline, namesAgent: card.cardNamesAgent)
        }
    }

    /// Host issues shown in the list: all of them, or the selected Hosts'
    /// only — a filtered Console should not nag about other machines — and
    /// none while searching, where they would only bury the matches.
    private var visibleHostIssues: [ConsoleHostStatusPresentation] {
        guard agentSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return filteredHostIssues
    }

    /// Every Host problem under the Host filter, as the flat lists show
    /// them outside a search, and as their summary's sheet lists them.
    private var filteredHostIssues: [ConsoleHostStatusPresentation] {
        guard !hostFilter.isEmpty else { return hostIssues }
        return hostIssues.filter { hostFilter.contains($0.hostID) }
    }

    /// The one selected Host's name, which the empty state names; empty for
    /// several Hosts, or one no longer listed.
    private var filteredHostName: String {
        guard hostFilter.count == 1 else { return "" }
        return hosts.consoleHosts.first(where: { hostFilter.contains($0.id) })?.displayName ?? ""
    }

    private struct HostsTabRequest {
        let id = UUID()
        var hostID: Host.ID?
        /// Opens the Setup Guide over the Host list.
        var showsSetupGuide = false
        /// Opens the Host's Host Helper sheet over its page.
        var opensHostHelper = false
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC. A
    /// Host the Console has not published yet counts as connecting, as its
    /// own rebuild will say a moment later.
    private var hostIssues: [ConsoleHostStatusPresentation] {
        hosts.consoleHosts.compactMap { host in
            ConsoleHostStatusPresentation(
                host: host,
                status: console.hostStatuses[host.id] ?? .connecting,
                standingFailure: console.hostStandingFailures[host.id],
                isAwaitingSnapshot: console.hostsAwaitingSnapshot.contains(host.id),
                syncError: console.hostSyncErrors[host.id])
        }
    }

    /// How the Console's sheets present, resolved against this view.
    private var sheetPresentation: ConsoleSheetPresentation {
        ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass)
    }

    private func hostIssuesSheet(presentation sheetPresentation: ConsoleSheetPresentation)
        -> some View
    {
        ConsoleHostIssuesSheet(
            issues: filteredHostIssues,
            explained: hostIssuesSheetExplained,
            sheetPresentation: sheetPresentation,
            onOpenHost: { id in
                isShowingHostIssues = false
                presentHosts(id)
            }
        ) { id in
            if let host = hosts.consoleHosts.first(where: { $0.id == id }),
                let detail = hostIssuesSheetDetail(for: id)
            {
                HostConnectionDetailContent(
                    presentation: detail,
                    host: host,
                    catalog: hosts,
                    sheetPresentation: sheetPresentation,
                    isRetryInFlight: manualReconnectInFlightHostIDs.contains(id),
                    onStop: { Task { await console.cancelHostConnection(id) } }
                ) {
                    // As in the single Host's sheet: stays through the dial.
                    hostIssuesLastFailures[id] = detail.failure
                    Task { await reconnectHost(id) }
                }
            }
        }
    }

    private var hostIssuesSheetExplained: Set<Host.ID> {
        Set(filteredHostIssues.map(\.hostID).filter { hostIssuesSheetDetail(for: $0) != nil })
    }

    private func hostIssuesSheetDetail(for id: Host.ID) -> HostConnectionDetailPresentation? {
        connectionDetail(
            for: ConnectionDetailRequest(id: id, lastFailure: hostIssuesLastFailures[id]))
    }

    private struct ConnectionDetailRequest: Identifiable {
        let id: Host.ID
        /// The failure shown when the sheet's Retry Now was tapped.
        var lastFailure: TransportError?
    }

    private func connectionDetail(for id: Host.ID) -> HostConnectionDetailPresentation? {
        connectionDetail(for: ConnectionDetailRequest(id: id))
    }

    private func connectionDetail(
        for request: ConnectionDetailRequest
    ) -> HostConnectionDetailPresentation? {
        guard let host = hosts.consoleHosts.first(where: { $0.id == request.id }) else { return nil }
        return HostConnectionDetailPresentation(
            host: host,
            status: console.hostStatuses[request.id],
            standingFailure: console.hostStandingFailures[request.id],
            lastFailure: request.lastFailure)
    }

    /// A Host that cannot connect explains itself in a sheet; any other Host
    /// condition opens the Host in the Hosts tab.
    private func openHostIssue(_ id: Host.ID) {
        if connectionDetail(for: id) != nil {
            connectionDetailRequest = ConnectionDetailRequest(id: id)
        } else {
            presentHosts(id)
        }
    }

    /// Opens the Hosts sheet, on one Host's detail when `id` is given, with
    /// its Host Helper sheet up when asked.
    private func presentHosts(_ id: Host.ID? = nil, opensHostHelper: Bool = false) {
        if let id {
            hostsTabRequest = HostsTabRequest(hostID: id, opensHostHelper: opensHostHelper)
        }
        showHosts()
    }

    /// Hosts with the Setup Guide over it, so the guide's Scan to Pair and
    /// Add Manually run where every new Host is added.
    private func presentHostSetupGuide() {
        hostsTabRequest = HostsTabRequest(showsSetupGuide: true)
        showHosts()
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

extension ToolbarContent {
    /// The glass a toolbar item shares with its neighbors; before iOS 26
    /// items draw none.
    @ToolbarContentBuilder
    func toolbarItemBackground(_ visibility: Visibility) -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(visibility)
        } else {
            self
        }
    }
}

/// A list's search field under its title. An iPad's sidebar keeps one
/// field for both its lists instead; see `sidebarLists(showing:)`.
private struct ConsoleListSearch: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    var focus: FocusState<ConsoleTab?>.Binding
    let tab: ConsoleTab
    let prompt: LocalizedStringKey
    let showsField: Bool

    func body(content: Content) -> some View {
        if showsField {
            content
                .searchable(
                    text: $text, isPresented: $isPresented,
                    placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
                .searchFocused(focus, equals: tab)
        } else {
            content
        }
    }
}

/// Hosts scroll independently, so a long inventory never pushes status
/// choices off the bottom of the filter panel. Statuses can also scroll
/// when accessibility text or a short window needs more room.
struct ConsoleListFilterChoices: View {
    private enum HostScrollHint: Equatable {
        case fits, moreBelow, atEnd
    }

    let hosts: [Host]
    @Binding var hostFilter: Set<Host.ID>
    let agentStatuses: ConsoleListPresentationStore?
    let counts: [ConsoleAgentStatusFilter: Int]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostContentHeight: CGFloat = 220
    @State private var statusContentHeight: CGFloat = 220
    @State private var hostScrollHint = HostScrollHint.fits

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hosts.count > 1 {
                heading("Host")
                ScrollView {
                    VStack(spacing: 0) {
                        choice(String(localized: "All Hosts"), selected: hostFilter.isEmpty) { hostFilter.removeAll() }
                        ForEach(hosts) { @Sendable host in
                            MainActorContent {
                                choice(host.displayName, selected: hostFilter.contains(host.id)) {
                                    if !hostFilter.insert(host.id).inserted { hostFilter.remove(host.id) }
                                }
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { hostContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicatorsFlash(onAppear: true)
                .frame(minHeight: 44, idealHeight: min(hostContentHeight, 220), maxHeight: min(hostContentHeight, 220))
                .accessibilityIdentifier("console.filters.hosts")
                .onScrollGeometryChange(for: HostScrollHint.self) { geometry in
                    guard geometry.contentSize.height > geometry.containerSize.height + 1 else { return .fits }
                    return geometry.visibleRect.maxY < geometry.contentSize.height - 1 ? .moreBelow : .atEnd
                } action: { _, hint in
                    hostScrollHint = hint
                }
                // Keep the hint's space at the end, so scrolling never
                // moves the divider or the status choices beneath it.
                Image(systemName: "chevron.down.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: hostScrollHint == .fits ? 0 : 16)
                    .opacity(hostScrollHint == .moreBelow ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityLabel("More Hosts below")
                    .accessibilityHidden(hostScrollHint != .moreBelow)
                if agentStatuses != nil { Divider().padding(.vertical, 6) }
            }
            if let agentStatuses {
                heading("Agent Status")
                ScrollView {
                    VStack(spacing: 0) {
                        choice(String(localized: "All Status"), selected: agentStatuses.statusFilter.isEmpty) {
                            agentStatuses.clearStatusFilter()
                        }
                        .accessibilityIdentifier("agents.status-filter.all")
                        ForEach(ConsoleAgentStatusFilter.allCases) { @Sendable filter in
                            MainActorContent {
                                choice(
                                    filter.title(count: counts[filter] ?? 0),
                                    selected: agentStatuses.statusFilter.contains(filter)
                                ) {
                                    agentStatuses.toggleStatusFilter(filter)
                                }
                                .accessibilityIdentifier("agents.status-filter.\(filter.rawValue)")
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { statusContentHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: 44, idealHeight: min(statusContentHeight, 400), maxHeight: min(statusContentHeight, 400))
            }
        }
        .padding(.vertical, 8)
        .frame(width: 300)
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 16)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An iPad sidebar's title as its list menu, drawn as the bar's own title
/// menu: the list's name and a chevron in a small disc. It only asks for
/// the choices; `sidebarLists(showing:)` presents them.
private struct SidebarListMenu: View {
    let shown: ConsoleTab
    /// Every list the menu switches between.
    let lists: [ConsoleTab]
    @Binding var isPresented: Bool
    /// The button's frame in the window.
    @Binding var frame: CGRect?

    /// Where the choices point from, in a sidebar column whose frame in the
    /// window is `column`: under the title, just above its bottom edge. The
    /// bar sits lower in a floating sidebar (iPadOS 26) than in one flush
    /// with the top (iPadOS 27), so it follows the title's own frame, with
    /// a guess for the pass before the title reports one.
    static func anchor(under title: CGRect?, in column: CGRect) -> CGPoint {
        guard let title, !title.isEmpty else { return CGPoint(x: 44, y: 40) }
        return CGPoint(x: title.midX - column.minX, y: title.maxY - column.minY - 4)
    }

    var body: some View {
        // As wide as the widest title throughout: the bar lays its items
        // out again only a while after a title changes, so a wider one
        // would be clipped. The width is held outside the button, whose own
        // frame, which its pointer highlight follows, fits the title on show.
        ZStack(alignment: .leading) {
            ForEach(lists) { @Sendable list in SidebarListTitle(title: list.title).hidden() }
            Button { isPresented = true } label: { SidebarListTitle(title: shown.title) }
                // A style of its own keeps the label SwiftUI's: bridged to a
                // bar button, it would show only its image.
                .buttonStyle(SidebarListTitleButtonStyle())
                // On the button itself: set inside its label, the highlight
                // gives way to one over the bar item's whole frame.
                .contentShape(.hoverEffect, Capsule().inset(by: 4))
                .hoverEffect(.highlight)
                .accessibilityHint("Switches between Projects and Terminals")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    frame = $0
                }
        }
    }
}

/// The lists an iPad sidebar's title menu switches between, laid out as
/// a menu's rows.
private struct SidebarListChoices: View {
    let shown: ConsoleTab
    let lists: [ConsoleTab]
    @Binding var isPresented: Bool
    let select: (ConsoleTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lists) { @Sendable list in
                MainActorContent {
                    Button {
                        isPresented = false
                        select(list)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .opacity(list == shown ? 1 : 0)
                                .accessibilityHidden(true)
                            Image(systemName: list.systemImage)
                                .frame(width: 24)
                                .accessibilityHidden(true)
                            Text(list.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityAddTraits(list == shown ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
        .presentationCompactAdaptation(.popover)
    }
}

private struct SidebarListTitle: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        // Fixed, as the bar's own title is: a larger one would push the
        // trailing buttons into the bar's overflow menu.
        .dynamicTypeSize(.large)
        // The leading inset puts the name in line with the rows' own
        // leading edge, as the bar's title is. The trailing one only clears
        // the pointer highlight: beside a window's controls the bar has
        // little width to spare.
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

private struct SidebarListTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.35 : 1)
    }
}

/// One of an iPad sidebar's two lists, shown or kept out of sight, touch,
/// focus, and VoiceOver; see `sidebarLists(showing:)`.
private struct SidebarListShown: ViewModifier {
    let isShown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .disabled(!isShown)
            .accessibilityHidden(!isShown)
    }
}

/// An iPad sidebar's bare buttons and menus, in its bar and at its foot:
/// symbols as bar buttons draw them, each with a bar button's hit area.
private struct SidebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .imageScale(.large)
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.35 : 1)
            .roundPointerHighlight()
    }
}

extension View {
    /// The pointer highlight every icon in an iPad sidebar takes: round,
    /// as a bare bar button's is.
    fileprivate func roundPointerHighlight() -> some View {
        contentShape(.hoverEffect, .circle).hoverEffect(.highlight)
    }
}

extension View {
    /// Content pinned to the bottom edge that the list scrolls under, with
    /// the system's scroll edge effect where there is one.
    @ViewBuilder
    fileprivate func bottomBar(@ViewBuilder _ content: () -> some View) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom) { content().background(.bar) }
        }
    }
}

/// Sets a row's vertical insets and keeps the list's own side margins, so
/// the row's edges and chevron meet the other rows' at every width: the
/// margins are 20 points on the widest iPhones, not 16.
private struct ListRowVerticalInsets: ViewModifier {
    let length: CGFloat

    init(_ length: CGFloat) {
        self.length = length
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.listRowInsets(.vertical, length)
        } else {
            content.listRowInsets(EdgeInsets(top: length, leading: 16, bottom: length, trailing: 16))
        }
    }
}

private struct ConsoleStatusBarModifier: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarColorScheme(scheme, for: .statusBar)
        } else {
            content
                .toolbarColorScheme(scheme, for: .navigationBar)
        }
        #else
        content
            .toolbarColorScheme(scheme, for: .navigationBar)
        #endif
    }
}

/// What the detail column shows when the selected Agent is no longer in the
/// Console list. Six conditions empty that list and they need six answers
/// (#141, #146, #154, #155).
///
/// Read Host Connection Status first, then Standing Failure, then the Agent
/// Inventory. A Standing Failure changes only what `.connecting` looks like.
/// The inventory is consulted only under `.connected`.
struct MissingAgentPresentation: Equatable {
    /// Which situation emptied the list. Explicit so that collapsing them
    /// into a single message cannot happen by accident.
    enum Cause: Hashable {
        case hostSuspended
        case hostConnecting
        case hostReconnecting
        /// A stopped Host, or a `.connecting` Host that still carries a
        /// Standing Failure.
        case hostFailed
        /// The Host is Connected, but its first snapshot for this connection
        /// has not landed yet.
        case hostLoadingAgents
        case paneGone
    }

    enum RenderingMode: Equatable {
        case progress
        case staticUnavailable
    }

    let cause: Cause
    let title: String
    let systemImage: String
    let message: String

    var renderingMode: RenderingMode {
        switch cause {
        case .hostConnecting, .hostReconnecting, .hostLoadingAgents:
            .progress
        case .hostSuspended, .hostFailed, .paneGone:
            .staticUnavailable
        }
    }

    /// Resolves the Host from the selection rather than taking a status the
    /// caller looked up: the pane address alone is not unique across Hosts,
    /// so `ConsoleAgent.ID` carries the `hostID`, and keeping the resolution
    /// here means no call site can apply a *different* rule to it.
    ///
    /// This initializer takes the *contents* and so cannot police where they
    /// came from — passing an empty `hostStatuses` restores #146's defect
    /// outright, since every failed Host then falls back to the placeholder.
    /// The detail column therefore does not call it; it calls the store-taking
    /// initializer below, which is the one under test (#152).
    init(
        agentID: ConsoleAgent.ID,
        hostStatuses: [Host.ID: EventsSessionStatus],
        hosts: [Host],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostStandingFailures: [Host.ID: TransportError] = [:]
    ) {
        let host = hosts.first { $0.id == agentID.hostID }
        let hostName = host?.displayName
        let usesHerdrEndpoint = host?.herdrEndpoint != nil
        func named(_ text: String) -> String {
            hostName.map { "\($0): \(text)" } ?? text
        }
        func applyFailed(_ failure: TransportError) -> (
            Cause, String, String, String
        ) {
            (
                .hostFailed,
                String(localized: "Host Unavailable"),
                failure.isHostKeySecurityFailure
                    ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
                named(failure.presentation(usesHerdrEndpoint: usesHerdrEndpoint).message)
            )
        }
        let hostStatus = hostStatuses[agentID.hostID]
        let standingFailure = hostStandingFailures[agentID.hostID]
        switch hostStatus {
        case .suspended:
            cause = .hostSuspended
            title = String(localized: "Connection Paused")
            systemImage = "pause.circle"
            message = named(String(localized: "The connection is paused until Heeler becomes active."))
        case .connecting:
            if let standingFailure {
                (cause, title, systemImage, message) = applyFailed(standingFailure)
            } else {
                cause = .hostConnecting
                title = String(localized: "Connecting…")
                systemImage = "dot.radiowaves.left.and.right"
                message = named(String(localized: "Opening the connection."))
            }
        case .reconnecting(_, _, let failure):
            cause = .hostReconnecting
            title = String(localized: "Reconnecting…")
            systemImage = "arrow.trianglehead.2.clockwise"
            message = named(failure.presentation.summary)
        case .failed(let failure):
            (cause, title, systemImage, message) = applyFailed(failure)
        case .connected:
            if hostsAwaitingSnapshot.contains(agentID.hostID) {
                cause = .hostLoadingAgents
                title = String(localized: "Loading Agents…")
                systemImage = "hourglass"
                message = named(String(localized: "Fetching the latest Agents."))
            } else {
                cause = .paneGone
                title = String(localized: "Agent Gone")
                systemImage = "rectangle.on.rectangle.slash"
                message = Self.paneGoneMessage
            }
        case .ended, nil:
            // No live inventory says why: an ended session, or a deleted
            // Host whose projection is gone, where no Agent comes back.
            cause = .paneGone
            title = String(localized: "Agent Gone")
            systemImage = "rectangle.on.rectangle.slash"
            message = Self.unreportedMessage
        }
    }

    /// herdr drops an Agent whose program exits from a pane that stays, as
    /// it does one whose pane closed; the same pane rebinds when an Agent
    /// starts in it again.
    static let paneGoneMessage =
        String(localized: "The Agent in this pane has exited, or the pane was closed. It shows here again if an Agent starts in the pane.")

    static let unreportedMessage = String(localized: "This Agent's pane is no longer reported.")

    /// What the Console's detail column shows when the selected Agent is not
    /// in the list.
    ///
    /// This exists to be called from a test, and deleting it would cost real
    /// coverage rather than tidy up an unused overload. The defect it guards
    /// (#146) is *which collections the view reads*, not what the rule does
    /// with them, and that could not be reached: a hosted `NavigationSplitView`
    /// builds its columns and navigation bar but never the SwiftUI content
    /// inside them, so the detail column cannot be rendered in a test and
    /// asserted against (measured under #152).
    ///
    /// Taking the stores instead of their contents is what makes the seam
    /// worth having. The reader is now written once, here, where a test calls
    /// exactly what the view calls — rather than at a call site that no test
    /// can reach.
    @MainActor
    init(agentID: ConsoleAgent.ID, console: ConsoleStore, hosts: HostStore) {
        self.init(
            agentID: agentID,
            hostStatuses: console.hostStatuses,
            hosts: hosts.consoleHosts,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostStandingFailures: console.hostStandingFailures)
    }
}

/// One link of `ConsoleView.body`'s chain, which is at the type checker's limit.
private struct ConsoleNoticesAndResets: ViewModifier {
    let console: ConsoleStore
    @Binding var pendingSavedChatRemoval: ConsoleAgent?
    let savedChatRemovalMessage: (ConsoleAgent) -> String
    let removeSavedChat: (ConsoleAgent) -> Void
    let leaveUsage: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(ConsoleOutcomeNoticeAlert(console: console))
            .modifier(SavedChatRemovalAlert(
                pending: $pendingSavedChatRemoval,
                message: savedChatRemovalMessage,
                remove: removeSavedChat))
            .modifier(UsageTurnedOffReset(isEnabled: console.isUsageEnabled, reset: leaveUsage))
    }
}

private struct UsageTurnedOffReset: ViewModifier {
    let isEnabled: Bool
    let reset: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isEnabled) { _, enabled in
            if !enabled { reset() }
        }
    }
}

/// A saved Chat row's swipe or context menu asks here before removing it.
private struct SavedChatRemovalAlert: ViewModifier {
    @Binding var pending: ConsoleAgent?
    let message: (ConsoleAgent) -> String
    let remove: (ConsoleAgent) -> Void

    func body(content: Content) -> some View {
        content.alert(
            SavedChatRemovalCopy.question,
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } })
        ) {
            Button(SavedChatRemovalCopy.confirm, role: .destructive) {
                if let pending { remove(pending) }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending.map(message) ?? "")
        }
    }
}

/// Collapsible Host-section header for the grouped Console list (#245).
private struct ConsoleHostSectionHeaderView: View {
    let presentation: ConsoleHostSectionHeaderPresentation
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                HostStatusGlyph(tone: presentation.readiness.tone)
                Text(presentation.hostDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.readiness.nameEmphasis.color)
                    .lineLimit(1)
                // Rows under a Host that is not connected may be saved Chat
                // entry points; the header says why in words, not only in
                // the badge.
                if presentation.readiness.tone != .connected {
                    Text(presentation.readiness.text)
                        .font(.footnote)
                        .foregroundStyle(presentation.readiness.tone.tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if presentation.showsStatusPills {
                    ConsoleHostStatusCountPills(items: presentation.statusItems)
                        .accessibilityHidden(true)
                }
                // The Workspace chevrons' weight and ink: a header's
                // hierarchical secondary draws a level lighter than theirs.
                Image(systemName: presentation.disclosureSystemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 12, alignment: .center)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The two ways a selected Agent detail can be on stage. A window whose Host
/// channel is live in another window still shows its detail, so that detail's
/// presentations keep covering the window's keyboard commands, while its
/// Attach stays off stage until the window holds the channel again.
struct AgentDetailStage {
    /// The detail is the window's selected, still-listed Agent.
    let isVisible: () -> Bool
    let terminalAccess: () -> HostTerminalAccess

    /// Attach start, resize and rejoin: visible and holding the Host's channel.
    func isOnStage() -> Bool {
        isVisible() && terminalAccess() == .holds
    }
}

extension AgentDetailStage {
    /// A detail in a window of the app: whether it holds its Host's channel is
    /// the scene directory's say, on a Host that has one to hand over.
    @MainActor
    init(
        isVisible: @escaping () -> Bool,
        hostID: Host.ID,
        console: ConsoleStore,
        sceneRouting: AgentSceneRouting?
    ) {
        self.init(
            isVisible: isVisible,
            terminalAccess: {
                console.capabilities(for: hostID)
                    .terminalAccess(sceneRouting?.terminalAccess(for: hostID))
            })
    }
}

/// Mirrors the Live Activity count chips so a collapsed Host communicates
/// the same status distribution at a glance.
struct ConsoleHostStatusCountPills: View {
    let items: [ConsoleHostAgentStatusCount]
    /// Stacks the pills where one line cannot hold them, as a card's
    /// summary needs at large text sizes.
    var wraps = false

    var body: some View {
        if wraps {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) { pills }
                VStack(alignment: .leading, spacing: 4) { pills }
            }
        } else {
            HStack(spacing: 5) { pills }
        }
    }

    private var pills: some View {
        ForEach(items) { @Sendable item in
            Text(item.text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(item.status.inkUIColor))
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Color(item.status.tintUIColor).opacity(0.15),
                    in: Capsule())
        }
    }
}

/// The Agents list's style: plain rows, or for By Workspace an inset
/// grouped list of cards on the other presentations' page.
private struct ConsoleAgentListStyle: ViewModifier {
    let showsCards: Bool
    @Environment(\.isSidebarColumn) private var isSidebarColumn
    @Environment(\.defaultMinListRowHeight) private var minRowHeight

    func body(content: Content) -> some View {
        if showsCards {
            content
                // A card's rows keep the list's shortest row themselves, so
                // a collapsed card's summary can be shorter.
                .environment(\.defaultMinListRowHeight, 0)
                .environment(\.workspaceCardMinRowHeight, minRowHeight)
                .listStyle(.insetGrouped)
                .listSectionSpacing(.custom(ConsoleWorkspaceCardMetrics.gap))
                .scrollContentBackground(.hidden)
                // Beside the sidebar, its glass, as the plain list shows.
                .background(isSidebarColumn ? Color.clear : Color(uiColor: .systemBackground))
        } else {
            content.listStyle(.plain)
        }
    }
}

/// What the Console sidebar's split-view selection can hold. Only Agents
/// have rows; a terminal chosen from Agent detail's Workspace drawer takes
/// the `terminal` case so the detail column stays presented on iPhone
/// (see `ConsoleView.selectedItem`).
enum ConsoleSelection: Hashable {
    case agent(ConsoleAgent.ID)
    case terminal(ConsoleTerminal.ID)
    /// A detail left on a core its Host no longer serves. No row carries this: the
    /// row at its address is another Terminal (see `ConsoleDetailCores`).
    indirect case leftBehind(ConsoleSelection)
}

/// Lets the details this window can no longer come back to go.
private struct ConsoleDetailCoresRetention: ViewModifier {
    let cores: ConsoleDetailCores
    let held: Set<ConsoleSelection>

    func body(content: Content) -> some View {
        content.onChange(of: held) { _, held in cores.keep(only: held) }
    }
}

/// A detail's identity in the detail column.
private struct ConsoleDetailIdentity: Hashable {
    let shown: ConsoleSelection
    let opening: Int
}

/// One presentation of the New Agent sheet: beside `origin`'s Agent when a
/// card row's menu opened it, else on a Host the form asks for.
private struct StartAgentRequest: Identifiable {
    let id = UUID()
    var origin: StartAgentStore.LaunchOrigin?
}

/// What a list tab showed when the other list took the stage.
private enum ParkedSelection {
    case agent(ConsoleAgent.ID)
    /// The terminal itself, not its id: a reconnecting Host lists none of
    /// its terminals, and the tab still comes back to this one.
    case terminal(ConsoleTerminal)

    var selection: ConsoleSelection {
        switch self {
        case .agent(let id): .agent(id)
        case .terminal(let terminal): .terminal(terminal.id)
        }
    }
}

extension EnvironmentValues {
    /// How far a full-bleed detail screen must start below the detail
    /// column's top edge to clear the chrome above its navigation bar. Zero
    /// in compact width; the screens still clear the status bar themselves.
    @Entry var detailTopChromeInset: CGFloat = 0
    /// The detail column's navigation bar row in regular width, in the same
    /// coordinates as `detailTopChromeInset`; nil in compact width.
    @Entry var detailBarRow: NavigationBarBand? = nil
    /// The edges a detail screen's full-bleed surface fills past the safe
    /// area. Beside an opaque sidebar the leading one lies under the
    /// sidebar; every other edge, an iPhone's landscape insets included, is
    /// the surface's to fill.
    @Entry var detailSurfaceEdges: Edge.Set = .all
    /// A Console list shown as the sidebar beside a detail column, where it
    /// draws its own selection, focus ring, and lifted rows, sits on the
    /// sidebar's glass, and keeps its search field in view, or on an iPad
    /// searches from the sidebar's foot.
    @Entry var isSidebarColumn = false
    /// Brings out the sidebar beside a regular-width detail column. Back to
    /// Console calls it in place of going back, and a detail drops its own
    /// edge swipe for the split view's; nil where the detail has no sidebar
    /// to show.
    @Entry var revealDetailSidebar: (@MainActor @Sendable () -> Void)? = nil
    /// The regular-width sidebar is hidden, so the detail's top line offers its reveal control.
    @Entry var detailSidebarIsHidden = false
    /// The detail is pushed over the list, on an iPhone or in a compact iPad
    /// window, so its floating header carries a Back button. A window's
    /// resize edge takes touches near its side, so in a narrow iPad window an
    /// edge swipe alone would leave no way back. False in regular columns,
    /// including a large iPhone in landscape, where the sidebar stands beside
    /// the detail and the header keeps only its other buttons.
    @Entry var showsDetailBackButton = false
}

/// A navigation bar's vertical extent in its column's own coordinates.
struct NavigationBarBand: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

/// Reports where the enclosing navigation bar sits within its column, a
/// frame SwiftUI does not expose.
/// Says how a close or a removal ended when the screen that asked has gone.
private struct ConsoleOutcomeNoticeAlert: ViewModifier {
    let console: ConsoleStore

    func body(content: Content) -> some View {
        let notice = console.outcomeNotices.first
        content.alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0, let notice { console.dismissOutcomeNotice(notice) } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice?.message ?? "")
        }
    }
}

private struct NavigationBarTopReader: UIViewRepresentable {
    let onChange: @MainActor (NavigationBarBand) -> Void

    func makeUIView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: UIView {
        var onChange: @MainActor (NavigationBarBand) -> Void
        private var reported: NavigationBarBand?

        init(onChange: @escaping @MainActor (NavigationBarBand) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        /// Deferred: this runs inside layout, where SwiftUI state must not
        /// change.
        func report() {
            guard window != nil, let navigation = enclosingNavigationController() else {
                return
            }
            // The column's own space: the terminal pads from the column's
            // top edge, wherever the column sits in the window.
            let bar = navigation.navigationBar
            let frame = bar.convert(bar.bounds, to: navigation.view)
            let band = NavigationBarBand(top: frame.minY, bottom: frame.maxY)
            guard band != reported else { return }
            reported = band
            let onChange = onChange
            Task { @MainActor in onChange(band) }
        }

        private func enclosingNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController,
                    let navigation = controller.navigationController
                {
                    return navigation
                }
                responder = current.next
            }
            return nil
        }
    }
}
