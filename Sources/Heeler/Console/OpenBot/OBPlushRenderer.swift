import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// One eye of a plush frame, in Bloub viewBox units: the capsule's transform, its felt pieces,
/// and the lids of a blink.
struct OBPlushEye: Sendable {
    /// The six numbers of a `matrix(a,b,c,d,e,f)`, as SVG orders them.
    var matrix: [Double]
    var width: Double
    var height: Double
    var alpha: Double
    /// The matrix under `matrix` that removes the blink squash from the pad.
    var inner: [Double]?
    var pieces: [OBPlushPiece]
    /// The pad's opacity. A sleeping eye fades the pad out and the closed line in.
    var pad: Double
    var lid: OBPlushLid?
    /// The closed eye line of sleep: its capsule width and opacity.
    var closed: (width: Double, opacity: Double)?
}

/// One piece of a felt pad: where it goes on screen, and which part of its picture it shows.
struct OBPlushPiece: Sendable {
    /// 0 draws the lying pad, 1 the standing one.
    var source: Int
    var x, y, w, h: Double
    var sx, sy, sw, sh: Double
}

/// The fur of the body closing over a blinking eye: nested capsules over the pad.
struct OBPlushLid: Sendable {
    var cx, cy: Double
    /// The vertical squash of the lid about `cx`, `cy`.
    var s: Double
    var bands: [(w: Double, h: Double, r: Double, alpha: Double)]
}

/// Everything a plush draws on one frame, in Bloub viewBox units.
struct OBPlushFrame: Sendable {
    var eyes: [OBPlushEye]
    var dots: [OBPlushBall]
}

/// A felt ball: a square box in viewBox units, tinted in the agent's colour.
struct OBPlushBall: Sendable {
    var x, y, size, opacity: Double
}

/// The geometry of a plush: its silhouette and its face. The colour does not change the frame.
enum OBPlushGeometry {
    /// Bloub's `VIEW_BOX`: the drawing is this wide, centred on the origin.
    static let viewBox = 316.0
    static let halfViewBox = viewBox / 2
    static let bodyRadius = 100.0
    /// The soft fur edge makes the felt body look smaller than the flat one, so it draws larger.
    static let bodyScale = 1.15

    /// The still frame of a plush: the first frame of its animation loop.
    ///
    /// OpenBot samples this from Bloub's engine; here the same numbers are computed directly,
    /// because a settled pose is closed form: the look blends completely into the state's gaze,
    /// the head drifts with Bloub's `liveliness`, and the eyes sit where the offline eye fit puts
    /// them. The loop starts at 4 s so its still picture does not change with the swing.
    static func restFrame(shape: String, face: OBPlushFace, thinking: Bool = false) -> OBPlushFrame {
        frame(shape: shape, face: face, time: settled, decorTime: 0, thinking: thinking)
    }

    /// The engine time where loops start: the arrival in a state is over.
    static let settled = 4.0

    /// The frame of `face` on `shape`: its eyes at engine time `time`, which drifts the gaze and
    /// blinks on Bloub's schedule, and its felt decor at `decorTime`.
    ///
    /// `thinking` is OpenBot's `working` mood: the eyes look up towards three felt dots that
    /// pulse beside the head (`THINK_LOOK`, `thinkingDots`).
    static func frame(shape: String, face: OBPlushFace, time: Double, decorTime: Double, thinking: Bool) -> OBPlushFrame {
        let radii = OBPlushModel.radii(for: shape)
        let fit = OBPlushModel.eyeFit(shape: shape, faceID: face.id)
        let live = liveliness(at: time, wander: 0.4)
        let lid = blinkLid(at: time)
        // The look replaces the face's direction completely (`mix` 1) while thinking.
        let gaze = OBPlushGaze(
            yaw: (thinking ? 18 : face.gaze.yaw) + live.dYaw,
            pitch: (thinking ? 22 : face.gaze.pitch) + live.dPitch,
            roll: face.gaze.roll + live.dRoll)
        let poses = eyePoses(gaze: gaze, split: face.split)
        var eyes: [OBPlushEye] = []
        for index in 0..<2 {
            let pose = poses[index]
            guard pose.depth > 0.02 else { continue }
            let eye = face.eyes[index]
            let radius = radiusAt(radii, angle: atan2(pose.y, pose.x))
            let tilt = eye.tilt * .pi / 180
            let cosTilt = cos(tilt)
            let sinTilt = sin(tilt)
            let a = pose.a * cosTilt + pose.c * sinTilt
            let b = pose.b * cosTilt + pose.d * sinTilt
            let c = -pose.a * sinTilt + pose.c * cosTilt
            let d = -pose.b * sinTilt + pose.d * cosTilt
            let open = blinkOpen(min(lid, eye.open))
            let matrix = [
                round2(a), round2(b * open), round2(c), round2(d * open),
                round2(pose.x * radius + (live.driftX + fit.x) * bodyRadius),
                round2(pose.y * radius + (live.driftY + fit.y) * bodyRadius),
            ]
            let rest = blinkOpen(eye.open)
            let capsule = restCapsule(matrix: matrix, open: open, rest: rest, w: eye.w, h: eye.h)
            let pieces = padPieces(w: capsule.w * bodyRadius, h: capsule.h * bodyRadius)
            eyes.append(OBPlushEye(
                matrix: matrix,
                width: eye.w * bodyRadius,
                height: eye.h * bodyRadius,
                alpha: min(1, pose.depth / 0.12),
                // The pad goes under the matrix without the blink squash, so felt never turns
                // into a stick; the lids then close over it.
                inner: unsquash(matrix, open: open),
                pieces: pieces,
                pad: 1,
                lid: self.lid(
                    matrix: matrix, open: open, rest: rest,
                    capsule: (capsule.w * bodyRadius / 2, capsule.h * bodyRadius / 2),
                    pieces: pieces),
                closed: nil))
        }
        return OBPlushFrame(eyes: eyes, dots: thinking ? thinkingDots(at: decorTime) : [])
    }

    /// The three thinking dots beside the head at `t`, fully shown (`SHOWN_DECOR`).
    static func thinkingDots(at t: Double) -> [OBPlushBall] {
        let offsets = [-0.557, -0.013, 0.532]
        let scale = 0.6
        return offsets.enumerated().map { index, offset in
            let pulse = dotPulse(t, index: index)
            let radius = 0.165 * scale * (1 + 0.25 * pulse)
            // A felt ball fills 80% of its picture.
            let x = 0.62 + offset * scale
            let y = -1.3
            return OBPlushBall(
                x: (x - radius / 0.8) * bodyRadius,
                y: (y - radius / 0.8) * bodyRadius,
                size: 2 * radius / 0.8 * bodyRadius,
                opacity: 0.55 + 0.45 * pulse)
        }
    }

    /// Bloub's `dotPulse`: a wave that runs over the three dots, left to right, every 1.5 s.
    static func dotPulse(_ t: Double, index: Int) -> Double {
        let raw = ((t - Double(index) * 0.5) / 1.5).truncatingRemainder(dividingBy: 1)
        let phase = (raw + 1).truncatingRemainder(dividingBy: 1)
        let wave = phase < 0.5 ? 0.5 - 0.5 * cos(phase * 2 * .pi) : 0
        return min(max(wave * 2, 0), 1)
    }

    /// The matrix that removes a blink's vertical squash from the pad (`plush-felt.ts`).
    static func unsquash(_ matrix: [Double], open: Double) -> [Double]? {
        guard open < 1, open > 0 else { return nil }
        let (a, b, c, d) = (matrix[0], matrix[1], matrix[2], matrix[3])
        let bOpen = b / open
        let dOpen = d / open
        let det = a * d - b * c
        guard abs(det) > 1e-9 else { return nil }
        return [
            (d * a - c * bOpen) / det,
            (a * bOpen - b * a) / det,
            (d * c - c * dOpen) / det,
            (a * dOpen - b * c) / det,
            0,
            0,
        ]
    }

    /// Bloub's blink calendar: mulberry32 from seed 24301, with Bloub's own spacing.
    static let blinkTimes: [Double] = {
        var state: UInt32 = 24301
        func next() -> Double {
            state = state &+ 0x6d2b_79f5
            var value = (state ^ (state >> 15)) &* (1 | state)
            value = (value &+ ((value ^ (value >> 7)) &* (61 | value))) ^ value
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }
        var times: [Double] = []
        var at = 1.4
        while at < 900 {
            times.append(at)
            at += 1.9 + next() * 2.7
            if next() < 0.18 {
                times.append(at)
                at += 0.24
            }
        }
        return times
    }()

    /// How closed the eyes are at `t`: 1 at the start of a blink, 0 at its middle, 1 after it.
    static func blinkLid(at t: Double) -> Double {
        let duration = 0.18
        for start in blinkTimes {
            if t < start { break }
            let progress = (t - start) / duration
            if progress >= 0, progress <= 1 {
                return progress < 0.45 ? 1 - progress / 0.45 : (progress - 0.45) / 0.55
            }
        }
        return 1
    }

    /// The fur of the body closing over an eye, `nil` when the eye is open.
    ///
    /// Only a blink draws it: OpenBot's loop blinks once at 5.2 s of its swing, so the pads of a
    /// busy avatar can show one.
    static func lid(
        matrix: [Double], open: Double, rest: Double,
        capsule: (x: Double, y: Double), pieces: [OBPlushPiece]
    ) -> OBPlushLid? {
        guard open < rest else { return nil }
        let s = min(max((open - 0.06) / (rest - 0.06), 0), 1)
        let short = min(capsule.x, capsule.y)
        let fringe = 30.0 / 205 * 2 * short
        var extentX = 0.0
        var extentY = 0.0
        for piece in pieces {
            extentX = max(extentX, abs(piece.x), abs(piece.x + piece.w))
            extentY = max(extentY, abs(piece.y), abs(piece.y + piece.h))
        }
        // The lid fits the capsule inside the pad, in the pad's full-size coordinates.
        extentY = max(0, extentY - (0.5 - 0.46) / 0.46 * short)
        let full = max(fringe, (pow(pow(extentX - capsule.x + short, 2) + pow(extentY - capsule.y + short, 2), 0.5)) - short)
        let margin = fringe + pow(s, 8) * (full - fringe)
        let soft = 0.1 * 2 * short
        var bands: [(w: Double, h: Double, r: Double, alpha: Double)] = []
        for band in stride(from: 3, through: 0, by: -1) {
            let grow = margin + soft * Double(band) / 4
            bands.append((w: capsule.x + grow, h: capsule.y + grow, r: short + grow, alpha: 1 / Double(band + 1)))
        }
        return OBPlushLid(cx: matrix[4], cy: matrix[5], s: s, bands: bands)
    }

    /// Bloub's `liveliness` at `t`: the slow drift of the resting gaze, in degrees.
    static func liveliness(at t: Double, wander: Double) -> (dYaw: Double, dPitch: Double, dRoll: Double, driftX: Double, driftY: Double) {
        let wave = { (period: Double, phase: Double) -> Double in
            let angle = t / period * 2 * .pi
            return 0.55 * sin(angle + phase) + 0.3 * sin(2 * angle + phase * 1.7 + 1.1) + 0.15 * sin(3 * angle + phase * 2.3 + 2.4)
        }
        return (
            dYaw: (wave(11.3, 0.4) * 5.5 + wave(3.7, 2.1) * 1.6) * wander,
            dPitch: (wave(9.1, 1.3) * 4.2 + wave(4.3, 0.7) * 1.3) * wander,
            dRoll: wave(13.7, 3.2) * 2.2 * wander,
            driftX: wave(7.9, 1.9) * 0.006,
            driftY: wave(5.3, 0.3) * 0.007)
    }

    /// The two eyes' tangent frames on the head sphere. Index 0 is the inner eye, 1 the outer.
    static func eyePoses(gaze: OBPlushGaze, split: Double) -> [(x: Double, y: Double, a: Double, b: Double, c: Double, d: Double, depth: Double)] {
        var normal = [0.0, 0.0, 1.0]
        var right = [1.0, 0.0, 0.0]
        var up = [0.0, 1.0, 0.0]
        (normal, right) = rotated(normal, right, by: gaze.yaw * .pi / 180)
        (up, normal) = rotated(up, normal, by: gaze.pitch * .pi / 180)
        (right, up) = rotated(right, up, by: gaze.roll * .pi / 180)
        func pose(_ side: Double) -> (x: Double, y: Double, a: Double, b: Double, c: Double, d: Double, depth: Double) {
            let (position, tangent) = rotated(normal, right, by: split * side * .pi / 180)
            return (
                x: position[0] * bodyRadius, y: position[1] * bodyRadius,
                a: tangent[0], b: tangent[1], c: up[0], d: up[1],
                depth: position[2])
        }
        return [pose(-1), pose(1)]
    }

    /// Rotates the pair of axes (`axis`, `other`) about each other by `angle` radians.
    private static func rotated(_ axis: [Double], _ other: [Double], by angle: Double) -> ([Double], [Double]) {
        let c = cos(angle)
        let s = sin(angle)
        let first = [axis[0] * c + other[0] * s, axis[1] * c + other[1] * s, axis[2] * c + other[2] * s]
        let second = [other[0] * c - axis[0] * s, other[1] * c - axis[1] * s, other[2] * c - axis[2] * s]
        return (first, second)
    }

    /// The silhouette's radius at an angle, interpolated between the 64 sampled radii.
    static func radiusAt(_ radii: [Double], angle: Double) -> Double {
        let count = radii.count
        let turns = angle / (2 * .pi)
        let wrapped = turns - (turns.rounded(.down))
        let position = wrapped * Double(count)
        let index = Int(position.rounded(.down))
        let fraction = position - Double(index)
        let from = radii[index % count]
        let to = radii[(index + 1) % count]
        return from + (to - from) * fraction
    }

    /// Bloub's `blinkScale`: a closed eye keeps 6% of its height, an open one all of it.
    static func blinkOpen(_ lid: Double) -> Double {
        0.06 + 0.94 * min(max(lid, 0), 1)
    }

    /// The capsule an eye half closed at rest shows (`somnolent`): shorter, never squashed.
    static func restCapsule(matrix: [Double], open: Double, rest: Double, w: Double, h: Double) -> (w: Double, h: Double) {
        guard rest < 1 else { return (w, h) }
        let bOpen = matrix[1] / open
        let dOpen = matrix[3] / open
        return (
            w: w * (matrix[0] * matrix[0] + bOpen * bOpen * rest * rest).squareRoot() / (matrix[0] * matrix[0] + bOpen * bOpen).squareRoot(),
            h: h * (matrix[2] * matrix[2] + dOpen * dOpen * rest * rest).squareRoot() / (matrix[2] * matrix[2] + dOpen * dOpen).squareRoot())
    }

    /// The round felt pad, in short sides: it measures `kw` by `kh` of the fitted capsule's short
    /// side. The pad picture is a 0.46 x 0.5 eye baked as two capsules, so the standing one loses
    /// the 0.04 it had over the short side.
    private static let padWidth = 1.7586780224155572 / 0.46
    private static let padHeight = 1.667393362265376 / 0.46
    private static let standingPadHeight = padHeight - (0.5 - 0.46) / 0.46
    private static let bar = 0.5

    /// The pieces of a felt pad on a capsule of `w` by `h`: sections of the pad, never stretched,
    /// each half showing its round end and the straight part in mirrored sections so the grain stays.
    static func padPieces(w: Double, h: Double) -> [OBPlushPiece] {
        let short = min(w, h)
        let lying = w >= h
        let extra = (max(w, h) - short) / 2
        let round = (lying ? padWidth : standingPadHeight) * short
        let across = (lying ? padHeight : padWidth) * short
        let barLength = bar * short
        let length = round + 2 * barLength
        var pieces: [OBPlushPiece] = []
        func piece(_ from: Double, _ to: Double, _ start: Double, _ end: Double) -> OBPlushPiece {
            lying
                ? OBPlushPiece(source: 0, x: from, y: -across / 2, w: to - from, h: across,
                               sx: start / length, sy: 0, sw: (end - start) / length, sh: 1)
                : OBPlushPiece(source: 1, x: -across / 2, y: from, w: across, h: to - from,
                               sx: 0, sy: start / length, sw: 1, sh: (end - start) / length)
        }
        func pair(_ from: Double, _ to: Double, _ start: Double, _ end: Double) {
            pieces.append(piece(from, to, start, end))
            pieces.append(piece(-to, -from, length - end, length - start))
        }
        let step = max(barLength, extra / 3)
        if step == barLength {
            pair(-extra - round / 2, min(-extra + barLength, 0), 0, round / 2 + min(extra, barLength))
        } else {
            pair(-extra - round / 2, -extra, 0, round / 2)
        }
        var index = step == barLength ? 1 : 0
        while Double(index) * step < extra - 1e-9 * short {
            let from = -extra + Double(index) * step
            let to = min(from + step, 0)
            let start = round / 2 + Double(index % 2) * barLength
            pair(from, to, start, start + ((to - from) / step) * barLength)
            index += 1
        }
        return pieces
    }

    /// Bloub rounds every matrix entry to two decimals, so the frames match its own output.
    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
