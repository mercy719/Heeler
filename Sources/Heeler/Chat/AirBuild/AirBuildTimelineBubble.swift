import SwiftUI

/// One assistant message in AirBuild's avatar-and-bubble layout. The timeline
/// decides which consecutive message carries the name and the final avatar.
struct AirBuildAssistantBubble: View {
    let agent: ConsoleAgent
    let blocks: [ChatMarkdownBlock]
    let isMuted: Bool
    let showsHeader: Bool
    let showsAvatar: Bool

    private var title: String { AgentTerminalView.displayTitle(for: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsHeader {
                (Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                + Text(verbatim: " @\(agent.agent.kind)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary))
                    .padding(.leading, 46)
                    .lineLimit(1)
            }
            HStack(alignment: .bottom, spacing: 10) {
                AirBuildSessionAvatar(agent: agent, size: 34)
                    .opacity(showsAvatar ? 1 : 0)
                    .accessibilityHidden(!showsAvatar)
                ChatMarkdownView(blocks: blocks, isMuted: isMuted)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Spacer(minLength: 44)
            }
        }
    }
}

/// The small iMessage tail outside the user's accent bubble.
struct AirBuildMessageTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - 2, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
