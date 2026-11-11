import SwiftUI

/// One assistant message in AirBuild's avatar-and-bubble layout. The timeline
/// decides which consecutive message carries the name and the final avatar.
struct AirBuildAssistantBubble: View {
    let agent: ConsoleAgent
    let blocks: [ChatMarkdownBlock]
    let isMuted: Bool
    let showsHeader: Bool
    let showsAvatar: Bool
    /// The folded Duo's ~375 points left the text ~230 wide beside the avatar's
    /// gutter; there the avatar joins the name and the bubble takes the row.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isNarrow: Bool { sizeClass == .compact }

    private var title: String { AgentTerminalView.displayTitle(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHeader {
                HStack(spacing: 6) {
                    if isNarrow { AirBuildSessionAvatar(agent: agent, size: 22) }
                    (Text(verbatim: title)
                        .font(.system(size: 11.5, weight: .semibold))
                    + Text(verbatim: " @\(agent.agent.kind)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary))
                        .lineLimit(1)
                }
                .padding(.leading, isNarrow ? 0 : 46)
            }
            HStack(alignment: .bottom, spacing: 10) {
                if !isNarrow {
                    AirBuildSessionAvatar(agent: agent, size: 34)
                        .opacity(showsAvatar ? 1 : 0)
                        .accessibilityHidden(!showsAvatar)
                }
                ChatMarkdownView(blocks: blocks, isMuted: isMuted)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: isNarrow ? 0 : 44)
            }
        }
    }
}

/// The small iMessage tail outside the user's accent bubble.
struct AirBuildMessageTail: Shape {
    func path(in rect: CGRect) -> Path {
        // The tip at the bottom right, curving back into the bubble's edge
        // 6 points in; the old tip at the top right closed along a flat top
        // that stuck out past the bubble as a square block.
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - 8, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - 6, y: rect.minY),
            control: CGPoint(x: rect.maxX - 6, y: rect.maxY - 3))
        path.closeSubpath()
        return path
    }
}
