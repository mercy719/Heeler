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

/// The user's accent bubble: round corners with a small one at the bottom
/// trailing corner pointing at the sender. A drawn tail left a notch where
/// its curve met the bottom edge (2026-11-12), so there is none.
struct AirBuildUserBubbleShape: Shape {
    var radius: CGFloat = 20
    var pointRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        return UnevenRoundedRectangle(
            topLeadingRadius: r, bottomLeadingRadius: r,
            bottomTrailingRadius: min(pointRadius, r), topTrailingRadius: r,
            style: .continuous
        ).path(in: rect)
    }
}
