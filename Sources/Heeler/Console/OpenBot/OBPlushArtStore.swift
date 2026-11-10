import CoreGraphics
import Foundation
import UIKit

/// The felt pictures of one plush: the tinted body, the shared eye pads and a felt ball.
struct OBPlushArt {
    /// The pictures' identity: shape, colour and pixel size.
    let key: String
    let body: CGImage
    let padLying: CGImage
    let padStanding: CGImage
    let ball: CGImage
}

/// Loads, tints and caches the felt pictures.
///
/// The bloub bodies are grey; a body is tinted once for each shape, colour and pixel size and
/// reused, so a list of twenty avatars decodes ten silhouettes at most. Everything but the
/// decode and the tint runs on the caller, and a face draws as soon as its pictures are ready.
enum OBPlushArtStore {
    private static let cache = ArtCache()
    private static let sources = SourceImages()

    static func key(shape: String, color: String, pixels: Int) -> String {
        "\(shape)|\(color)|\(pixels)"
    }

    /// The pictures of `shape` in `color`, `pixels` wide, or `nil` until they are ready.
    static func cached(shape: String, color: String, pixels: Int) -> OBPlushArt? {
        cache.value(for: key(shape: shape, color: color, pixels: pixels))
    }

    /// The pictures, loading and tinting `shape` in `color` if they are not cached yet.
    static func load(shape: String, color: String, pixels: Int) async -> OBPlushArt? {
        let key = key(shape: shape, color: color, pixels: pixels)
        if let ready = cache.value(for: key) { return ready }
        let made = await Task.detached(priority: .userInitiated) {
            build(shape: shape, color: color, pixels: pixels, key: key)
        }.value
        guard let made else { return nil }
        cache.store(made, for: key)
        return made
    }

    private static func build(shape: String, color: String, pixels: Int, key: String) -> OBPlushArt? {
        guard
            let grey = sources.image("forme-\(shape)"),
            let padLying = sources.image("fred-oeil0-x"),
            let padStanding = sources.image("fred-oeil0-y"),
            let feltBall = sources.image("boule"),
            let body = tinted(grey, color, pixels)
        else { return nil }
        // A felt ball is at most a fifth of the avatar.
        let ball = max(16, Int((Double(pixels) * 0.2).rounded(.up)))
        guard let dot = tinted(feltBall, color, ball) else { return nil }
        return OBPlushArt(
            key: key,
            body: body,
            padLying: reduced(padLying, longestSide: padPixels),
            padStanding: reduced(padStanding, longestSide: padPixels),
            ball: dot)
    }

    /// The longest side of a pad. A 144 point avatar draws one at about 150 pixels.
    private static let padPixels = 512

    private static func reduced(_ image: CGImage, longestSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > longestSide else { return image }
        let scale = Double(longestSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = makeContext(width: width, height: height) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// The grey body `image` in `hex`, `pixels` square.
    ///
    /// Bloub bakes the felt as a grey photo and tints it, so one picture serves every colour:
    /// each grey becomes the agent colour through `tintRamp`.
    private static func tinted(_ image: CGImage, _ hex: String, _ pixels: Int) -> CGImage? {
        guard
            let context = makeContext(width: pixels, height: pixels),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let grey = context.makeImage() else { return nil }

        let ramp = tintRamp(hex)
        var premultiplied = [UInt8](repeating: 0, count: pixels * pixels * 4)
        guard let read = premultiplied.withUnsafeMutableBytes({ buffer in
            CGContext(
                data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: pixels * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        read.draw(grey, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

        var out = [UInt8](repeating: 0, count: pixels * pixels * 4)
        for index in stride(from: 0, to: premultiplied.count, by: 4) {
            let alpha = Int(premultiplied[index + 3])
            guard alpha > 0 else { continue }
            let level = min(255, (Int(premultiplied[index]) * 255 + alpha / 2) / alpha)
            let entry = level * 4
            out[index] = UInt8(Int(ramp[entry]) * alpha / 255)
            out[index + 1] = UInt8(Int(ramp[entry + 1]) * alpha / 255)
            out[index + 2] = UInt8(Int(ramp[entry + 2]) * alpha / 255)
            out[index + 3] = UInt8(alpha)
        }
        return out.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: pixels * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// The tint ramp of `hex`: for each grey 0...255, the colour it becomes.
    ///
    /// Bloub's curve, in linear light: the colour times the distance in luminance from the
    /// median, gamma corrected, then blended towards white for the sheen of the felt's highlight.
    static func tintRamp(_ hex: String) -> [UInt8] {
        let value = UInt32(hex.dropFirst().prefix(6), radix: 16) ?? 0
        let ink = [
            linear(Double((value >> 16) & 255) / 255),
            linear(Double((value >> 8) & 255) / 255),
            linear(Double(value & 255) / 255),
        ]
        let median = linear(0.55)
        var ramp = [UInt8](repeating: 0, count: 256 * 4)
        for grey in 0..<256 {
            let level = Double(grey) / 255
            let light = pow(linear(level) / median, 0.6)
            let sheen = 0.08 * pow(max(0, (level - 0.55) / 0.45), 2)
            for channel in 0..<3 {
                let tinted = min(1, ink[channel] * light)
                ramp[grey * 4 + channel] = UInt8((srgb(tinted + (1 - tinted) * sheen) * 255).rounded())
            }
            ramp[grey * 4 + 3] = 255
        }
        return ramp
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func srgb(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

/// The decoded felt pictures, shared by every plush of the app.
private final class SourceImages: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var missing: Set<String> = []

    func image(_ name: String) -> CGImage? {
        lock.lock()
        let known = images[name]
        let absent = missing.contains(name)
        lock.unlock()
        if let known { return known }
        guard !absent else { return nil }
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "webp", subdirectory: "OpenBotPlush"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            lock.lock()
            missing.insert(name)
            lock.unlock()
            return nil
        }
        lock.lock()
        images[name] = image
        lock.unlock()
        return image
    }
}

/// The tinted bodies, kept in the order they were last shown so the oldest leaves first.
private final class ArtCache: @unchecked Sendable {
    private let lock = NSLock()
    private var arts: [String: OBPlushArt] = [:]
    private var order: [String] = []
    private static let limit = 32

    func value(for key: String) -> OBPlushArt? {
        lock.lock()
        defer { lock.unlock() }
        guard let art = arts[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return art
    }

    func store(_ art: OBPlushArt, for key: String) {
        lock.lock()
        arts[key] = art
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit, let oldest = order.first {
            order.removeFirst()
            arts[oldest] = nil
        }
        lock.unlock()
    }

}