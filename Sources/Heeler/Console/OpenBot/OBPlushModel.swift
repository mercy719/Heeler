import CoreGraphics
import Foundation

/// A gaze direction in Bloub's head frame, in degrees.
struct OBPlushGaze: Equatable, Sendable {
    var yaw: Double
    var pitch: Double
    var roll: Double
}

/// One eye of a resting face: the capsule size in body radii, its own tilt, and how open it rests.
struct OBPlushEyeShape: Equatable, Sendable {
    var w: Double
    var h: Double
    var tilt: Double = 0
    var open: Double = 1
}

/// A resting face: where the head looks and how the two eyes are shaped.
struct OBPlushFace: Equatable, Sendable {
    var id: String
    var gaze: OBPlushGaze
    var split: Double
    var eyes: [OBPlushEyeShape]
}

/// One orbit ring of the working avatar, as Bloub's `ArcSeed` declares it.
struct OBOrbitRingSeed: Equatable, Sendable {
    var a: Double
    var k: Double
    var tilt: Double
    var speed: Double
    var phase: Double
    var sweep: Double
    var hue: Double
    var hueSpan: Double
    var width: Double
    var cy: Double
    var cx: Double = 0
}

/// The deterministic face an agent's seed draws, plus everything derived from it.
///
/// Ported line for line from OpenBot's `packages/brand/src/bloub-avatar.ts`: the same FNV-1a
/// hash, the same UTF-16 code units, the same modulo, so a seed picks the same shape, eyes
/// and colour in both apps.
enum OBPlushModel {
    /// Every Bloub silhouette, in the order Bloub lists them. The seed's first hash runs over
    /// this list, `goutte` included, or the modulo would pick a different shape.
    private static let allSilhouettes = [
        "cercle", "galet", "squircle", "capsule", "triangle", "hexagone",
        "nuage", "goutte", "carre", "losange", "pentagone",
    ]

    /// The silhouettes an avatar may draw, in the order Bloub lists them: `goutte` is not one.
    static let silhouettes = allSilhouettes.filter { $0 != "goutte" }

    /// The automatic colours, by Bloub colour id.
    private static let automaticColors = [
        "#e8483f", "#f08a24", "#f0b429", "#3ecf8e", "#2fbfa0", "#3b93f0", "#8b5cf6", "#e152b0",
    ]

    /// The face a seed draws, keyed by the seed alone.
    ///
    /// Shape comes from `${seed}:shape`, but a drop silhouette is replaced from the ten
    /// the app draws using `${seed}:shape:replacement`; eyes come from `${seed}:expression`
    /// and the automatic colour from `${seed}:color`.
    static func profile(for seed: String) -> (shape: String, face: OBPlushFace, color: String) {
        let stored = allSilhouettes[stableIndex("\(seed):shape", count: allSilhouettes.count)]
        let shape = stored == "goutte"
            ? silhouettes[stableIndex("\(seed):shape:replacement", count: silhouettes.count)]
            : stored
        let face = faces[stableIndex("\(seed):expression", count: faces.count)]
        let color = automaticColors[stableIndex("\(seed):color", count: automaticColors.count)]
        return (shape, face, color)
    }

    /// Bloub's `stableIndex`: FNV-1a over UTF-16 code units, folded with `Math.imul`, then modulo.
    static func stableIndex(_ value: String, count: Int) -> Int {
        var hash: UInt32 = 0x811c_9dc5
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % UInt32(count))
    }

    /// The 64 radii of a silhouette, or the circle's when the id is unknown.
    static func radii(for shape: String) -> [Double] {
        silhouetteRadii[shape] ?? silhouetteRadii["cercle"]!
    }

    /// The eye offset of a settled face on a silhouette, in body radii.
    static func eyeFit(shape: String, faceID: String) -> CGPoint {
        idleEyeFit["\(shape)|\(faceID)"] ?? .zero
    }

    /// A face by id, falling back to the neutral face the way Bloub's unknown ids do.
    static func face(_ id: String) -> OBPlushFace {
        faces.first { $0.id == id } ?? faces[0]
    }

    static let neutralFace = faces[0]
    static let asleepFaceID = "plush-asleep"
    static let failedFaceID = "plush-failed"
}
