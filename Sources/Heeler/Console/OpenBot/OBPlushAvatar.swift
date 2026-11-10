import SwiftUI

/// What an agent is doing, as far as its face is concerned. The OpenBot console shows `idle`
/// and `busy`: a working agent looks up at three felt dots and turns its orbit rings.
enum OBAvatarMood: Sendable {
    case idle
    case busy
    /// A reply has just landed: the pleased face.
    case responded
}

/// A session's OpenBot-style plush avatar, keyed by a stable seed.
///
/// The seed picks the silhouette, the eyes and the colour exactly as OpenBot does
/// (`OBPlushModel.profile`), and the felt body draws from the pictures the bloub package ships.
/// A still plush is a bitmap rendered once per face, colour and size, so a long agent list costs
/// one shared image per row; only a busy or answering face animates.
struct OBPlushAvatar: View {
    let seed: String
    var size: CGFloat = 54
    /// The face an agent shows. Only `busy` turns the orbit rings.
    var mood: OBAvatarMood = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var art: OBPlushArt?

    var body: some View {
        let look = Self.look(seed: seed, mood: mood)
        let pixels = Self.pixelSize(size * OBPlushGeometry.bodyScale, scale: displayScale)
        OBOrbitRings(size: size, active: mood == .busy) {
            ZStack {
                if let art, art.key == OBPlushArtStore.key(shape: look.shape, color: look.color, pixels: pixels) {
                    if reduceMotion || mood == .idle {
                        StillPlush(look: look, thinking: mood == .busy, art: art, size: size, scale: displayScale)
                    } else {
                        AnimatedPlush(look: look, thinking: mood == .busy, art: art, size: size)
                    }
                }
            }
            .frame(width: size, height: size)
        }
        .task(id: "\(look.shape)|\(look.color)|\(pixels)") {
            art = await OBPlushArtStore.load(shape: look.shape, color: look.color, pixels: pixels)
        }
    }

    /// The avatar's head colour, which OpenBot also gives the user's bubbles and the voice button
    /// in that agent's chat (`avatarHeadColor(seed, null)`).
    static func color(for seed: String) -> Color {
        Color(hex: OBPlushModel.profile(for: seed).color) ?? .gray
    }

    /// The plush a seed and mood draw: its silhouette, its colour, and the face it wears.
    ///
    /// The faces come from OpenBot's `plushMood` table: `idle` keeps the seed's own resting face,
    /// `busy` wears `attentif`, and a fresh reply wears `heureux`.
    static func look(seed: String, mood: OBAvatarMood) -> (shape: String, color: String, face: OBPlushFace) {
        let profile = OBPlushModel.profile(for: seed)
        switch mood {
        case .idle: return (profile.shape, profile.color, profile.face)
        case .busy: return (profile.shape, profile.color, OBPlushModel.face("attentif"))
        case .responded: return (profile.shape, profile.color, OBPlushModel.face("heureux"))
        }
    }

    /// The side in device pixels, in steps of 32, so near sizes share their pictures.
    static func pixelSize(_ points: CGFloat, scale: CGFloat) -> Int {
        let step = 32.0
        return max(Int(step), Int((Double(points * scale) / step).rounded(.up)) * Int(step))
    }
}

/// A plush that holds still: one frame, rendered once into a shared image.
private struct StillPlush: View {
    let look: (shape: String, color: String, face: OBPlushFace)
    let thinking: Bool
    let art: OBPlushArt
    let size: CGFloat
    let scale: CGFloat

    var body: some View {
        let drawn = size * OBPlushGeometry.bodyScale
        Image(uiImage: OBPlushImage.still(
            key: "\(art.key)|\(look.face.id)|\(thinking)|\(drawn)|\(scale)",
            frame: OBPlushGeometry.restFrame(shape: look.shape, face: look.face, thinking: thinking),
            art: art, size: drawn, scale: scale))
            .resizable()
            .interpolation(.high)
            .frame(width: drawn, height: drawn)
    }
}

/// A plush whose gaze wanders and which blinks, as OpenBot's own loop does.
private struct AnimatedPlush: View {
    let look: (shape: String, color: String, face: OBPlushFace)
    let thinking: Bool
    let art: OBPlushArt
    let size: CGFloat

    var body: some View {
        let drawn = size * OBPlushGeometry.bodyScale
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let seconds = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.loop)
            Canvas { context, _ in
                let frame = OBPlushGeometry.frame(
                    shape: look.shape, face: look.face,
                    time: Self.lifeTime(seconds), decorTime: seconds, thinking: thinking)
                context.withCGContext { cg in
                    cg.translateBy(x: (size - drawn) / 2, y: (size - drawn) / 2)
                    OBPlushDraw.draw(frame, art: art, size: drawn, in: cg)
                }
            }
            .frame(width: size, height: size)
        }
    }

    /// One loop: a whole number of the dots' 1.5 s pulse.
    static let loop = 6.0

    /// OpenBot's loop clock: the engine time swings from 4 s to 5.6 s and back over the loop, so
    /// the picture closes without a jump and passes the blink at 5.2 s on the way out and back.
    static func lifeTime(_ seconds: Double) -> Double {
        OBPlushGeometry.settled + 0.8 * (1 - cos(seconds / loop * 2 * .pi))
    }
}
