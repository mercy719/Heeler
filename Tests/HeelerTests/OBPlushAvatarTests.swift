import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Heeler

/// The plush avatar's port of Bloub's deterministic face.
///
/// The expected values were read from OpenBot's own TypeScript (`bloub-avatar.ts` and
/// `plush-frames.ts` run against `@norbert_bodziony/bloub` 0.6.4), not from this port, so a
/// changed hash, order or modulo fails here rather than silently drawing another creature.
@Suite("OpenBot plush avatar")
struct OBPlushAvatarTests {
    /// Seed to shape, eyes and colour, as OpenBot's `bloubAvatarProfile(seed, null)` returns them.
    private static let profiles: [(seed: String, shape: String, face: String, color: String)] = [
        ("abc", "losange", "hilare", "#f0b429"),
        ("agent-1", "pentagone", "fier", "#f08a24"),
        ("开卡奖励助理", "squircle", "neutre", "#3b93f0"),
        ("x", "squircle", "mefiant", "#8b5cf6"),
        ("House of Bala", "pentagone", "confus", "#e152b0"),
        ("s1", "nuage", "somnolent", "#2fbfa0"),
        ("s2", "losange", "fier", "#f08a24"),
        ("s3", "carre", "timide", "#f0b429"),
        ("s4", "cercle", "confus", "#e152b0"),
        ("seed-9", "pentagone", "blase", "#3ecf8e"),
        ("", "capsule", "excite", "#e8483f"),
        ("🎉", "cercle", "colere", "#3ecf8e"),
        ("Ω≈ç√", "nuage", "somnolent", "#2fbfa0"),
    ]

    @Test func seedPicksTheSameShapeEyesAndColorAsOpenBot() {
        for expected in Self.profiles {
            let profile = OBPlushModel.profile(for: expected.seed)
            #expect(profile.shape == expected.shape, "shape of \(expected.seed)")
            #expect(profile.face.id == expected.face, "eyes of \(expected.seed)")
            #expect(profile.color == expected.color, "colour of \(expected.seed)")
        }
    }

    @Test func headColorIsTheOneOpenBotPaintsWithTheBubbles() {
        // `avatarHeadColor(seed, null)`: the seeded automatic colour, the one the plush wears.
        for expected in Self.profiles {
            #expect(OBPlushAvatar.color(for: expected.seed) == (Color(hex: expected.color) ?? .black))
        }
    }

    @Test func stableIndexHashesUTF16CodeUnitsLikeJavaScript() {
        // FNV-1a over UTF-16 code units, as `charCodeAt` walks them: an emoji is its surrogate
        // pair, and the hash folds with `Math.imul`'s 32-bit multiply.
        #expect(OBPlushModel.stableIndex("", count: 8) == 5)
        #expect(OBPlushModel.stableIndex("abc:shape", count: 11) == 9)
        // An emoji hashes as its surrogate pair; as code points it would land elsewhere.
        #expect(OBPlushModel.stableIndex("🎉:shape", count: 11) == 0)
        #expect(OBPlushModel.stableIndex("🎉:expression", count: 16) == 6)
        #expect(OBPlushModel.stableIndex("🎉:color", count: 8) == 3)
    }

    @Test func dropSilhouetteIsReplacedFromTheTenAvatarsDraw() {
        // No seed maps onto `goutte` in the app: it re-hashes with the ":replacement" segment.
        for seed in Self.profiles.map(\.seed) {
            #expect(OBPlushModel.profile(for: seed).shape != "goutte")
        }
        #expect(!OBPlushModel.silhouettes.contains("goutte"))
        #expect(OBPlushModel.silhouettes.count == 10)
    }

    /// The eye matrices of the still idle frame, in OpenBot's own rounded output.
    private static let stillEyes: [(seed: String, matrices: [[Double]])] = [
        ("abc", [[0.92, 0.25, -0.3, 0.94, -23.64, -17.48], [0.86, -0.27, 0.34, 0.93, 32.45, -18.63]]),
        ("agent-1", [[0.94, 0.21, -0.27, 0.94, -20.06, -25.23], [0.87, -0.22, 0.32, 0.93, 35.61, -27.01]]),
        ("开卡奖励助理", [[0.88, -0.33, 0.43, 0.85, 20.37, -43.64], [0.65, -0.07, 0.43, 0.85, 70.33, -59.58]]),
        ("x", [[0.99, -0.14, 0.13, 0.99, -8.97, -9.57], [0.87, -0.08, 0.13, 0.99, 44.97, -14.82]]),
        ("House of Bala", [[0.86, -0.2, 0.13, 0.98, -50.47, -6.21], [0.93, 0.37, -0.37, 0.93, 6.94, 1.41]]),
        ("s1", [[0.99, -0.01, 0.04, 0.45, -16.48, 15.37], [0.92, -0.05, 0.04, 0.45, 37.41, 12.53]]),
        ("s2", [[0.94, 0.21, -0.27, 0.94, -20.97, -22.24], [0.87, -0.22, 0.32, 0.93, 31.68, -22.72]]),
        ("s3", [[0.83, -0.07, 0.2, 0.96, -51.55, 21.52], [0.98, -0.18, 0.2, 0.96, -4.76, 14.06]]),
        ("s4", [[0.86, -0.2, 0.13, 0.98, -50.2, -9.41], [0.93, 0.37, -0.37, 0.93, 4.48, -2.09]]),
        ("seed-9", [[0.79, -0.02, 0, 1, -59.06, -3.79], [1, 0, 0, 1, -8.79, -4.64]]),
        ("", [[0.96, -0.1, 0.15, 0.97, -30.13, 0.48], [0.88, 0.08, -0.17, 0.97, 30.88, 2.71]]),
        ("🎉", [[0.85, 0.46, -0.47, 0.88, -23.89, -12.09], [0.8, -0.47, 0.48, 0.87, 34.47, -12.69]]),
    ]

    @Test func stillFramePlacesTheEyesWhereOpenBotDoes() {
        for expected in Self.stillEyes {
            let profile = OBPlushModel.profile(for: expected.seed)
            let frame = OBPlushGeometry.restFrame(shape: profile.shape, face: profile.face)
            #expect(frame.eyes.count == expected.matrices.count, "eye count of \(expected.seed)")
            for (eye, matrix) in zip(frame.eyes, expected.matrices) {
                for (actual, wanted) in zip(eye.matrix, matrix) {
                    #expect(abs(actual - wanted) < 0.011, "\(expected.seed): \(actual) vs \(wanted)")
                }
            }
        }
    }

    @Test func eyePosesMatchOpenBotForTheRestingGaze() {
        // `eyePoses({yaw: 28.49, pitch: 28.62, roll: -13}, 100, 15.46)` from the package.
        let poses = OBPlushGeometry.eyePoses(
            gaze: OBPlushGaze(yaw: 28.49, pitch: 28.62, roll: -13), split: 15.46)
        let expected = [
            [18.899315, -40.902908, 0.887467, -0.318005, 0.420338, 0.855317, 0.892736],
            [61.815110, -51.430413, 0.664233, -0.062636, 0.420338, 0.855317, 0.594458],
        ]
        for (pose, wanted) in zip(poses, expected) {
            let actual = [pose.x, pose.y, pose.a, pose.b, pose.c, pose.d, pose.depth]
            for (value, target) in zip(actual, wanted) {
                #expect(abs(value - target) < 1e-5, "\(value) vs \(target)")
            }
        }
    }

    @Test func padPiecesSliceTheFeltWithoutStretchingIt() {
        // `padPieces(34, 13)` from OpenBot's plush-felt.ts.
        let pieces = OBPlushGeometry.padPieces(w: 34, h: 13)
        let expected: [[Double]] = [
            [0, -35.350885, -23.560993, 31.350885, 47.121986, 0, 0, 0.5, 1],
            [0, 4, -23.560993, 31.350885, 47.121986, 0.5, 0, 0.5, 1],
            [0, -4, -23.560993, 4, 47.121986, 0.5, 0, 0.063794, 1],
            [0, 0, -23.560993, 4, 47.121986, 0.436206, 0, 0.063794, 1],
        ]
        #expect(pieces.count == expected.count)
        for (piece, wanted) in zip(pieces, expected) {
            let actual = [Double(piece.source), piece.x, piece.y, piece.w, piece.h, piece.sx, piece.sy, piece.sw, piece.sh]
            for (value, target) in zip(actual, wanted) {
                #expect(abs(value - target) < 1e-5, "\(value) vs \(target)")
            }
        }
    }

    @Test func blinkLidsCloseOverThePadLikeOpenBots() {
        // `plushEye({matrix, w: 34, h: 13, open: 0.4, rest: 1}, 0)` from OpenBot's plush-felt.ts.
        let matrix = [0.92, 0.25, -0.3, 0.94, -23.64, -17.48]
        let capsule = OBPlushGeometry.restCapsule(matrix: matrix, open: 0.4, rest: 1, w: 0.34, h: 0.13)
        let pieces = OBPlushGeometry.padPieces(w: capsule.w * 100, h: capsule.h * 100)
        let lid = OBPlushGeometry.lid(
            matrix: matrix, open: 0.4, rest: 1,
            capsule: (capsule.w * 50, capsule.h * 50), pieces: pieces)
        let bands = lid?.bands
        #expect(abs((lid?.s ?? 0) - 0.3617021276595745) < 1e-9)
        #expect(bands?.count == 4)
        #expect(abs((bands?.first?.w ?? 0) - 19.884896523372703) < 1e-6)
        #expect(abs((bands?.last?.h ?? 0) - 8.409896523372701) < 1e-6)
        #expect(bands?.map(\.alpha) == [0.25, 1.0 / 3, 0.5, 1])
        let inner = OBPlushGeometry.unsquash(matrix, open: 0.4) ?? []
        let expected = [1.119706320493722, 0.36709938284741445, 0.45009576505639487, 2.380293679506278, 0, 0]
        for (value, target) in zip(inner, expected) {
            #expect(abs(value - target) < 1e-9)
        }
        // An open eye has no lid at all.
        #expect(OBPlushGeometry.lid(matrix: matrix, open: 1, rest: 1, capsule: (17, 6.5), pieces: pieces) == nil)
    }

    @Test func radiusAtInterpolatesTheSilhouette() {
        let galet = OBPlushModel.radii(for: "galet")
        #expect(abs(OBPlushGeometry.radiusAt(galet, angle: 0) - 0.9765373800218335) < 1e-12)
        #expect(abs(OBPlushGeometry.radiusAt(galet, angle: .pi / 2) - 0.8985042811585323) < 1e-12)
        #expect(abs(OBPlushGeometry.radiusAt(galet, angle: .pi) - 1.009462158728916) < 1e-12)
        // The circle is the one silhouette with a single radius everywhere.
        let circle = OBPlushModel.radii(for: "cercle")
        for angle in stride(from: 0.0, to: 2 * .pi, by: 0.37) {
            #expect(abs(OBPlushGeometry.radiusAt(circle, angle: angle) - 1) < 1e-12)
        }
    }

    @Test func livelinessMatchesOpenBotsDrift() {
        // `liveliness(4, {wander: 0.4})` from the package.
        let drift = OBPlushGeometry.liveliness(at: 4, wander: 0.4)
        #expect(abs(drift.dYaw - 0.5153480080326333) < 1e-9)
        #expect(abs(drift.dPitch - 0.03295241776033553) < 1e-9)
        #expect(abs(drift.dRoll - -0.5888113887508226) < 1e-9)
        #expect(abs(drift.driftX - -0.0053086983786638986) < 1e-9)
        #expect(abs(drift.driftY - -0.006781808885412139) < 1e-9)
    }

    @Test func blinkCalendarIsBloubsOwn() {
        // The first blinks of Bloub's seeded calendar, and the lid curve between them.
        // Bloub's scan of its own calendar reads these to the nearest 2 ms (it steps by 0.002 s).
        let expected: [Double] = [1.4, 5.218, 9.688, 9.928]
        for (actual, wanted) in zip(OBPlushGeometry.blinkTimes.prefix(4), expected) {
            #expect(abs(actual - wanted) < 0.002, "\(actual) vs \(wanted)")
        }
        #expect(OBPlushGeometry.blinkLid(at: 4) == 1)
        #expect(abs(OBPlushGeometry.blinkLid(at: 5.3) - 0.0193) < 0.0002)
        #expect(abs(OBPlushGeometry.blinkLid(at: 5.35) - 0.5244) < 0.0002)
        #expect(OBPlushGeometry.blinkLid(at: 5.4) == 1)
    }

    @Test func tintRampTurnsGreyIntoTheAgentColor() {
        // The `#f08a24` ramp of OpenBot's plush-felt.ts at a few greys.
        let ramp = OBPlushArtStore.tintRamp("#f08a24")
        let sample = { (grey: Int) in (Int(ramp[grey * 4]), Int(ramp[grey * 4 + 1]), Int(ramp[grey * 4 + 2])) }
        #expect(sample(0) == (0, 0, 0))
        #expect(sample(64) == (155, 87, 19))
        #expect(sample(140) == (240, 138, 36))
        #expect(sample(200) == (255, 173, 63))
        #expect(sample(255) == (255, 204, 96))
        #expect(ramp[255 * 4 + 3] == 255)
    }

    @Test func busyAndAnsweredFacesComeFromTheMoodTable() {
        let busy = OBPlushAvatar.look(seed: "abc", mood: .busy)
        #expect(busy.face.id == "attentif")
        #expect(busy.shape == "losange")
        let answered = OBPlushAvatar.look(seed: "abc", mood: .responded)
        #expect(answered.face.id == "heureux")
        let idle = OBPlushAvatar.look(seed: "abc", mood: .idle)
        #expect(idle.face.id == "hilare")
    }

    @Test func nearSizesShareTheirPicturesIn32PixelSteps() {
        // OpenBot's `plushPixels`: the drawn side in device pixels, rounded up to a 32 pixel step.
        #expect(OBPlushAvatar.pixelSize(10, scale: 2) == 32)
        #expect(OBPlushAvatar.pixelSize(54 * OBPlushGeometry.bodyScale, scale: 3) == 192)
        #expect(OBPlushAvatar.pixelSize(54 * OBPlushGeometry.bodyScale, scale: 2) == 128)
        #expect(OBPlushAvatar.pixelSize(60 * OBPlushGeometry.bodyScale, scale: 3) == 224)
        #expect(OBPlushAvatar.pixelSize(62 * OBPlushGeometry.bodyScale, scale: 3) == 224)
    }

    @Test func busyFaceLooksUpAtThreePulsingFeltDots() {
        // OpenBot's `working` mood: `plushRestFrame(plushGeometry(seed, "working"))`.
        let expected: [(seed: String, matrices: [[Double]])] = [
            ("abc", [[0.98, -0.17, 0.19, 0.92, 2.29, -39.04], [0.82, 0.03, 0.19, 0.92, 48.59, -35.28]]),
            ("开卡奖励助理", [[0.98, -0.17, 0.19, 0.92, 1.88, -33.42], [0.82, 0.03, 0.19, 0.92, 59.81, -43.19]]),
            ("s1", [[0.98, -0.17, 0.19, 0.92, 1.18, -23.87], [0.82, 0.03, 0.19, 0.92, 43.82, -31.92]]),
        ]
        for row in expected {
            let look = OBPlushAvatar.look(seed: row.seed, mood: .busy)
            let frame = OBPlushGeometry.restFrame(shape: look.shape, face: look.face, thinking: true)
            for (eye, matrix) in zip(frame.eyes, row.matrices) {
                for (actual, wanted) in zip(eye.matrix, matrix) {
                    #expect(abs(actual - wanted) < 0.011, "\(row.seed): \(actual) vs \(wanted)")
                }
            }
            #expect(frame.dots.count == 3)
        }
        // `thinkingDots(SHOWN_DECOR, t)` at the start of the loop and at 2.3 s.
        let start = OBPlushGeometry.thinkingDots(at: 0)
        let startExpected: [[Double]] = [
            [16.205, -142.375, 24.75, 0.55], [48.845, -142.375, 24.75, 0.55], [78.45125, -145.46875, 30.9375, 1],
        ]
        let later = OBPlushGeometry.thinkingDots(at: 2.3)
        let laterExpected: [[Double]] = [
            [16.205, -142.375, 24.75, 0.55], [46.70727132634749, -144.5127286736525, 29.02545734730501, 0.8609423525312736],
            [81.545, -142.375, 24.75, 0.55],
        ]
        for (dots, wanted) in [(start, startExpected), (later, laterExpected)] {
            #expect(dots.count == wanted.count)
            for (dot, values) in zip(dots, wanted) {
                for (actual, target) in zip([dot.x, dot.y, dot.size, dot.opacity], values) {
                    #expect(abs(actual - target) < 1e-6, "\(actual) vs \(target)")
                }
            }
        }
        // Idle and answered faces have no decor.
        let idle = OBPlushAvatar.look(seed: "abc", mood: .idle)
        #expect(OBPlushGeometry.restFrame(shape: idle.shape, face: idle.face).dots.isEmpty)
    }

    @Test func everySilhouetteHasRadiiAndEveryFaceHasAFit() {
        #expect(OBPlushModel.silhouettes.count == 10)
        for shape in OBPlushModel.silhouettes {
            #expect(OBPlushModel.radii(for: shape).count == 64, "radii of \(shape)")
        }
        #expect(OBPlushModel.faces.count == 16)
        #expect(OBPlushModel.face("nope").id == "neutre")
    }
}
