#if DEBUG
import SwiftUI

/// The plush avatars on one sheet, for comparing their felt against OpenBot's own screenshot.
///
/// Debug only: the renderer's look is checked here, and the sheet renders through `ImageRenderer`
/// so a headless test can write the same picture to disk.
struct OBPlushGridPreview: View {
    /// Sixteen seeds, so the grid shows every silhouette and most faces.
    static let seeds = [
        "abc", "agent-1", "开卡奖励助理", "x",
        "House of Bala", "s1", "s2", "s3",
        "s4", "seed-9", "arc-A", "ob-1",
        "nickname", "旅行助理", "影视助理", "包工头",
    ]

    var body: some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 20), count: 4), spacing: 20) {
                ForEach(Self.seeds, id: \.self) { seed in
                    OBPlushAvatar(seed: seed)
                        .frame(width: 54, height: 54)
                }
            }
            HStack(spacing: 24) {
                VStack(spacing: 6) {
                    OBPlushAvatar(seed: "abc", mood: .busy)
                    Text(verbatim: "busy").font(.caption2)
                }
                VStack(spacing: 6) {
                    OBPlushAvatar(seed: "开卡奖励助理", mood: .busy)
                    Text(verbatim: "busy").font(.caption2)
                }
                VStack(spacing: 6) {
                    OBPlushAvatar(seed: "s1", mood: .responded)
                    Text(verbatim: "responded").font(.caption2)
                }
            }
        }
        .padding(28)
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
    }
}

#Preview("Plush grid") {
    OBPlushGridPreview()
}
#endif
