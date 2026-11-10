import CoreGraphics
import Foundation
import UIKit

/// Draws one plush frame, as OpenBot's `plush-draw.ts` does with Skia.
enum OBPlushDraw {
    /// Draws `frame` in a square of `size` points, in a UIKit (y down) context.
    ///
    /// The body picture covers the whole Bloub viewBox; the eyes carry their own transform and
    /// their felt pieces, which sit under the fur of a blink and the closed line of sleep.
    static func draw(_ frame: OBPlushFrame, art: OBPlushArt, size: CGFloat, in context: CGContext) {
        let scale = size / OBPlushGeometry.viewBox
        context.saveGState()
        context.translateBy(x: size / 2, y: size / 2)
        context.scaleBy(x: scale, y: scale)
        draw(art.body, source: nil, in: CGRect(
            x: -OBPlushGeometry.halfViewBox, y: -OBPlushGeometry.halfViewBox,
            width: OBPlushGeometry.viewBox, height: OBPlushGeometry.viewBox), in: context)
        for eye in frame.eyes {
            drawEye(eye, art: art, in: context)
        }
        for dot in frame.dots {
            context.saveGState()
            context.setAlpha(dot.opacity)
            draw(art.ball, source: nil, in: CGRect(x: dot.x, y: dot.y, width: dot.size, height: dot.size), in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// One eye: the felt pad in pieces that add up in their own layer, under the fur of a blink,
    /// then the closed line of sleep.
    private static func drawEye(_ eye: OBPlushEye, art: OBPlushArt, in context: CGContext) {
        let opacity = eye.alpha * eye.pad
        if opacity > 0.001 {
            context.saveGState()
            // A blinking eye keeps only the pad under its lids, so the pad and the lids share a layer.
            let lidded = eye.lid != nil
            if lidded { context.beginTransparencyLayer(auxiliaryInfo: nil) }
            concatenate(eye.matrix, in: context)
            if let inner = eye.inner {
                concatenate(inner, in: context)
            }
            // The pieces add up (`plus`) among themselves in their own layer, which then lies over
            // the body at the eye's opacity, as Skia's `saveLayer` does: added onto the body they
            // would bleach the felt to white.
            context.saveGState()
            context.setAlpha(opacity)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if eye.pieces.count > 1 {
                context.setBlendMode(.plusLighter)
            }
            for piece in eye.pieces {
                let image = piece.source == 0 ? art.padLying : art.padStanding
                let source = CGRect(
                    x: piece.sx * Double(image.width), y: piece.sy * Double(image.height),
                    width: piece.sw * Double(image.width), height: piece.sh * Double(image.height))
                draw(
                    image, source: source,
                    in: CGRect(x: piece.x, y: piece.y, width: piece.w, height: piece.h), in: context)
            }
            context.endTransparencyLayer()
            context.restoreGState()
            if let lid = eye.lid {
                // The fur closes over the pad: nested capsules, kept only where the pad is.
                context.saveGState()
                context.setBlendMode(.destinationIn)
                context.translateBy(x: lid.cx, y: lid.cy)
                context.scaleBy(x: 1, y: lid.s)
                context.translateBy(x: -lid.cx, y: -lid.cy)
                concatenate(eye.matrix, in: context)
                if let inner = eye.inner {
                    concatenate(inner, in: context)
                }
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                for band in lid.bands {
                    context.setAlpha(band.alpha)
                    let box = CGRect(x: -band.w, y: -band.h, width: 2 * band.w, height: 2 * band.h)
                    context.addPath(CGPath(
                        roundedRect: box, cornerWidth: band.r, cornerHeight: band.r, transform: nil))
                    context.fillPath()
                }
                context.restoreGState()
            }
            context.restoreGState()
            if lidded { context.endTransparencyLayer() }
        }
        if let closed = eye.closed, closed.opacity > 0.001 {
            context.saveGState()
            concatenate(eye.matrix, in: context)
            let width = closed.width
            context.setStrokeColor(CGColor(srgbRed: 0.1098, green: 0.1020, blue: 0.1137, alpha: 1))
            context.setAlpha(eye.alpha * closed.opacity)
            context.setLineWidth(width * 0.2)
            context.setLineCap(.round)
            let line = CGMutablePath()
            line.move(to: CGPoint(x: -width / 2, y: 0))
            line.addQuadCurve(to: CGPoint(x: width / 2, y: 0), control: CGPoint(x: 0, y: width * 0.42))
            context.addPath(line)
            context.strokePath()
            context.restoreGState()
        }
    }

    /// A `matrix(a,b,c,d,e,f)` of Bloub, applied the way SVG applies it.
    private static func concatenate(_ matrix: [Double], in context: CGContext) {
        guard matrix.count == 6 else { return }
        context.concatenate(CGAffineTransform(
            a: matrix[0], b: matrix[1], c: matrix[2], d: matrix[3], tx: matrix[4], ty: matrix[5]))
    }

    /// Draws part of `image` into `rect`, or all of it, in a y-down context (UIKit or SwiftUI).
    ///
    /// `CGContext.draw` lays an image out bottom-up, so in a y-down context it would land upside
    /// down; the local flip keeps the felt upright, and the source rect counts from the top as
    /// Skia's does.
    private static func draw(_ image: CGImage, source: CGRect?, in rect: CGRect, in context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let shown = source ?? CGRect(x: 0, y: 0, width: width, height: height)
        guard shown.width > 0, shown.height > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / shown.width, y: -rect.height / shown.height)
        context.draw(image, in: CGRect(x: -shown.minX, y: shown.maxY - height, width: width, height: height))
        context.restoreGState()
    }
}

/// Renders a whole frame to a bitmap, for the still avatars a list shows.
@MainActor
enum OBPlushImage {
    /// Still pictures by face, colour and size: a list of twenty agents draws each once.
    private static var stills: [String: UIImage] = [:]
    private static var order: [String] = []
    private static let limit = 64

    /// The still picture under `key`, rendering `frame` the first time it shows.
    static func still(key: String, frame: @autoclosure () -> OBPlushFrame, art: OBPlushArt, size: CGFloat, scale: CGFloat) -> UIImage {
        if let cached = stills[key] { return cached }
        let image = render(frame(), art: art, size: size, scale: scale)
        stills[key] = image
        order.append(key)
        if order.count > limit {
            stills[order.removeFirst()] = nil
        }
        return image
    }

    /// `frame` `size` points wide, at `scale` device pixels per point.
    static func render(_ frame: OBPlushFrame, art: OBPlushArt, size: CGFloat, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            OBPlushDraw.draw(frame, art: art, size: size, in: context.cgContext)
        }
    }
}
