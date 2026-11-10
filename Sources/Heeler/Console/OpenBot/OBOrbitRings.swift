import SwiftUI

/// The orbit rings OpenBot turns around a working agent (`agent-orbit-rings.tsx`).
///
/// The half of each ring behind the body draws under the avatar and the other half over it, so
/// the rings read as orbits around the body rather than as a flat drawing. With Reduce Motion
/// on, or `still`, the rings hold their first frame, as OpenBot's do.
struct OBOrbitRings<Content: View>: View {
    /// The side of the avatar box the rings surround.
    let size: CGFloat
    /// Whether the rings show at all: OpenBot shows them while the agent works.
    var active: Bool = true
    /// Holds the rings on their first frame, for a snapshot.
    var still: Bool = false
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let holds = still || reduceMotion
        ZStack {
            if active {
                OrbitLayer(size: size, side: .back, holds: holds)
            }
            content
            if active {
                OrbitLayer(size: size, side: .front, holds: holds)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// OpenBot draws the face at 128% of the avatar box and the rings at 158%; the phone draws the
/// face in the box, so the rings reach past it by the same proportion.
private let orbitRingScale = 1.58 / 1.28

/// One half of every ring, drawn in Bloub viewBox units around the origin.
private struct OrbitLayer: View {
    let size: CGFloat
    let side: OrbitSide
    let holds: Bool

    var body: some View {
        if holds {
            layer(at: 0)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { timeline in
                layer(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func layer(at clock: Double) -> some View {
        let box = size * orbitRingScale
        return Canvas { context, canvasSize in
            context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.scaleBy(x: canvasSize.width / OBPlushGeometry.viewBox, y: canvasSize.height / OBPlushGeometry.viewBox)
            // OpenBot starts at 1.2 s into the pose, where every ring shows.
            let time = (clock + 1.2).truncatingRemainder(dividingBy: 3.6)
            for ring in OBPlushModel.orbitRings {
                let fade = clamp01(time / 0.8) * clamp01((3.6 - time) / 0.9)
                guard fade > 0.01, let path = arcPath(ring, at: time, side: side) else { continue }
                var shade = context
                shade.opacity = fade
                shade.stroke(
                    path,
                    with: .linearGradient(
                        Gradient(stops: ring.stops),
                        startPoint: ring.gradientStart,
                        endPoint: ring.gradientEnd),
                    style: StrokeStyle(lineWidth: ring.width * OBPlushGeometry.bodyRadius, lineCap: .round))
            }
        }
        .frame(width: box, height: box)
        .offset(x: (size - box) / 2, y: (size - box) / 2)
        .allowsHitTesting(false)
    }

    /// The arc of a ring on this side of the body. Bloub's own deep ordering, sampled at 64 steps.
    private func arcPath(_ ring: OBOrbitRingSeed, at time: Double, side: OrbitSide) -> Path? {
        let swept = ring.sweep * 2 * .pi
        let start = ring.phase + time * ring.speed * 2 * .pi
        let tiltCos = cos(ring.tilt)
        let tiltSin = sin(ring.tilt)
        let depth = (1 - ring.k * ring.k).squareRoot()
        var path = Path()
        var drawing = false
        for step in 0...64 {
            let angle = start + Double(step) / 64 * swept
            let cosine = cos(angle)
            let sine = sin(angle)
            let x = ring.a * (cosine * tiltCos - sine * tiltSin * ring.k) + ring.cx
            let y = ring.a * (cosine * tiltSin + sine * tiltCos * ring.k) + ring.cy
            let behind = ring.a * sine * depth < 0
            guard (side == .back) == behind else {
                drawing = false
                continue
            }
            let point = CGPoint(x: x * OBPlushGeometry.bodyRadius, y: y * OBPlushGeometry.bodyRadius)
            if drawing {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                drawing = true
            }
        }
        return path.isEmpty ? nil : path
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private enum OrbitSide {
    case back, front
}

extension OBOrbitRingSeed {
    /// The three tints along a ring: Bloub's hue wheel at its own saturation and lightness.
    var stops: [Gradient.Stop] {
        [
            Gradient.Stop(color: hueColor(hue), location: 0),
            Gradient.Stop(color: hueColor(hue + hueSpan * 0.5), location: 0.5),
            Gradient.Stop(color: hueColor(hue + hueSpan), location: 1),
        ]
    }

    var gradientStart: CGPoint {
        CGPoint(
            x: (cx - cos(tilt) * a) * OBPlushGeometry.bodyRadius,
            y: (cy - sin(tilt) * a) * OBPlushGeometry.bodyRadius)
    }

    var gradientEnd: CGPoint {
        CGPoint(
            x: (cx + cos(tilt) * a) * OBPlushGeometry.bodyRadius,
            y: (cy + sin(tilt) * a) * OBPlushGeometry.bodyRadius)
    }

    private func hueColor(_ degrees: Double) -> Color {
        let hue = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let chroma = (1 - abs(2 * 0.62 - 1)) * 0.55
        let secondary = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let match: (r: Double, g: Double, b: Double)
        switch hue {
        case ..<60: match = (chroma, secondary, 0)
        case ..<120: match = (secondary, chroma, 0)
        case ..<180: match = (0, chroma, secondary)
        case ..<240: match = (0, secondary, chroma)
        case ..<300: match = (secondary, 0, chroma)
        default: match = (chroma, 0, secondary)
        }
        let base = 0.62 - chroma / 2
        return Color(red: match.r + base, green: match.g + base, blue: match.b + base)
    }
}
