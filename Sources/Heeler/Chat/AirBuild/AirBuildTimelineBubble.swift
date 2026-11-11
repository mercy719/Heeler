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

/// The user's accent bubble and its iMessage tail as one outline, so no seam
/// or notch shows where a separate tail met the rounded corner. The tail
/// reaches `tail` points past the trailing edge at the bottom.
struct AirBuildUserBubbleShape: Shape {
    var radius: CGFloat = 16
    var tail: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 2)
        // The right edge runs straight to `r` above the bottom, then sweeps out to the tip.
        let sweep = min(r, rect.height - r)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - sweep))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + tail, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY - 1))
        // Back from the tip along a soft hook into the flat bottom edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r * 0.75, y: rect.maxY - 1.5),
            control: CGPoint(x: rect.maxX - 2, y: rect.maxY + 0.5))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r * 1.25, y: rect.maxY),
            control: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
