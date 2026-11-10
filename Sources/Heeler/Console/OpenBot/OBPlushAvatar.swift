import SwiftUI

/// A session's OpenBot-style plush avatar, keyed by a stable seed.
/// shortcut: a hue-tinted circle until the plush renderer lands (task OB-2).
struct OBPlushAvatar: View {
    let seed: String
    var size: CGFloat = 54

    /// The avatar's head colour, which OpenBot also gives the user's bubbles
    /// and the voice button in that agent's chat.
    static func color(for seed: String) -> Color { ArcProjectColor.color(for: seed) }

    var body: some View {
        Circle()
            .fill(Self.color(for: seed).opacity(0.85))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
