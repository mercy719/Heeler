import SwiftUI

/// A session's OpenBot-style plush avatar, keyed by a stable seed.
/// shortcut: a hue-tinted circle until the plush renderer lands (task OB-2).
struct OBPlushAvatar: View {
    let seed: String
    var size: CGFloat = 54

    var body: some View {
        Circle()
            .fill(ArcProjectColor.color(for: seed).opacity(0.85))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
