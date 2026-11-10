import SwiftUI

/// The AirBuild chat chrome: a floating project mark, the existing detail
/// actions in one menu, and the progress inspector's button.
struct AirBuildChatHeader: View {
    static let height: CGFloat = 62

    let project: ArcProjectGroup.Project
    let isHostConnected: Bool
    var onBack: (() -> Void)?
    let onOpenTerminal: () -> Void
    var additionalActions: [AgentDetailHeaderAction] = []
    var onShowChanges: (() -> Void)?
    var onRename: (() -> Void)?
    let onShowProject: () -> Void
    let onClose: () -> Void
    let onTogglePanel: () -> Void
    var sessionSettings: AgentSessionSettings?
    var sessionControls: AgentSessionControls?
    @State private var showsModelGrid = false
    @State private var modelSelectionFeedback = 0

    private var projectLabel: some View {
        VStack(spacing: 2) {
            Text(verbatim: String(project.label.prefix(1)).uppercased())
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(
                    ArcProjectColor.color(for: project.label),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityLabel(Text(verbatim: project.label))
            HStack(spacing: 4) {
                Circle()
                    .fill(isHostConnected ? .green : Color(uiColor: .systemGray))
                    .frame(width: 6, height: 6)
                Text(verbatim: project.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color(uiColor: .systemGray4).opacity(0.92), in: Capsule())
            .accessibilityLabel(Text(verbatim: project.label))
            .accessibilityValue(isHostConnected ? Text("Connected") : Text("Not Connected"))
        }
        .frame(maxWidth: 160)
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack {
                if let onBack {
                    AirBuildGlassCapsule {
                        AirBuildIconButton(systemImage: "chevron.left", label: "Back", action: onBack)
                    }
                }
            }
            .frame(width: 80, alignment: .leading)
            Spacer(minLength: 0)
            if let sessionControls, let sessionSettings {
                Button { showsModelGrid = true } label: { projectLabel }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsModelGrid, arrowEdge: .top) {
                        AgentModelGrid(
                            settings: sessionSettings, controls: sessionControls,
                            isPresented: $showsModelGrid,
                            onSelect: { modelSelectionFeedback += 1 })
                        .presentationCompactAdaptation(.popover)
                    }
                    .sensoryFeedback(.selection, trigger: modelSelectionFeedback)
                    .accessibilityLabel("Agent settings")
                    .accessibilityValue(sessionSettings.modelLine ?? String(localized: "Model"))
                    .accessibilityHint("Select model and effort for \(project.label)")
                    .accessibilityIdentifier("agent-header-model")
            } else {
                projectLabel
            }
            Spacer(minLength: 0)
            AirBuildGlassCapsule {
                Menu {
                    Button("Open Terminal", systemImage: "terminal", action: onOpenTerminal)
                    ForEach(additionalActions) { @Sendable action in
                        MainActorContent {
                            Button(action.title, systemImage: action.systemImage, action: action.perform)
                        }
                    }
                    if let onShowChanges {
                        Button("Changes", systemImage: "arrow.triangle.branch", action: onShowChanges)
                    }
                    if let onRename {
                        Button("Rename", systemImage: "pencil", action: onRename)
                    }
                    Menu("Go to Project") {
                        Button("Show Project", systemImage: "folder", action: onShowProject)
                    }
                    Divider()
                    Button("Close Agent", systemImage: "xmark", role: .destructive, action: onClose)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
                AirBuildIconButton(systemImage: "sidebar.right", label: "Progress", action: onTogglePanel)
            }
            .frame(width: 80)
        }
        .frame(height: Self.height)
    }
}
