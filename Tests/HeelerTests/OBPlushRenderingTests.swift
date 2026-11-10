#if DEBUG
import CoreGraphics
import Testing
import SwiftUI
import UIKit

@testable import Heeler

/// The felt avatar on screen, not just its numbers: a bitmap of the grid, written where the
/// task asks for it, and a check that every silhouette and colour really drew.
@MainActor
@Suite("OpenBot plush rendering")
struct OBPlushRenderingTests {
    /// The picture the task compares against OpenBot's own screenshot.
    private static let output = URL(fileURLWithPath: "/Users/duola/Documents/ios-app/docs/status/ob2-plush-grid.png")

    @Test func gridRendersEverySilhouetteInItsSeedColor() async throws {
        let seeds = ["abc", "agent-1", "开卡奖励助理", "x", "House of Bala", "s1", "s2", "s3",
                     "s4", "seed-9", "arc-A", "ob-1", "nickname", "旅行助理", "影视助理", "包工头"]
        var views: [UIImage] = []
        var shapes: Set<String> = []
        for seed in seeds {
            let profile = OBPlushModel.profile(for: seed)
            shapes.insert(profile.shape)
            let pixels = OBPlushAvatar.pixelSize(54 * OBPlushGeometry.bodyScale, scale: 3)
            let loaded = await OBPlushArtStore.load(shape: profile.shape, color: profile.color, pixels: pixels)
            let art = try #require(loaded, "pictures of \(seed)")
            let frame = OBPlushGeometry.restFrame(shape: profile.shape, face: profile.face)
            views.append(OBPlushImage.render(frame, art: art, size: 54 * OBPlushGeometry.bodyScale, scale: 3))
        }
        #expect(shapes.count >= 6, "the grid should show most silhouettes, saw \(shapes)")
        // One working agent: its attentive face inside the orbit rings, held on their first frame.
        let busy = OBPlushAvatar.look(seed: "开卡奖励助理", mood: .busy)
        let busyPixels = OBPlushAvatar.pixelSize(54 * OBPlushGeometry.bodyScale, scale: 3)
        let busyArt = try #require(await OBPlushArtStore.load(shape: busy.shape, color: busy.color, pixels: busyPixels))
        let busyFace = OBPlushImage.render(
            OBPlushGeometry.restFrame(shape: busy.shape, face: busy.face),
            art: busyArt, size: 54 * OBPlushGeometry.bodyScale, scale: 3)
        let ringed = ImageRenderer(content: OBOrbitRings(size: 54, still: true) {
            Image(uiImage: busyFace)
                .resizable()
                .frame(width: 54 * OBPlushGeometry.bodyScale, height: 54 * OBPlushGeometry.bodyScale)
        }
        .frame(width: 74, height: 74))
        ringed.scale = 3
        views.append(try #require(ringed.uiImage, "the busy avatar with its rings"))
        let sheet = Self.sheet(views)
        try #require(sheet.pngData()).write(to: Self.output)
        // The sheet's corner keeps its dark background: no felt spills out of a cell.
        let corner = try #require(sheet.cgImage.map { Self.pixel($0, x: 2, y: 2) })
        #expect(corner.red < 40 && corner.green < 40 && corner.blue < 40, "the sheet corner should stay dark, saw \(corner)")
        // The first avatar's middle is felt in its seed colour, not the dark sheet.
        let firstMiddle = Int((16 + 37) * sheet.scale)
        let middle = try #require(sheet.cgImage.map { Self.pixel($0, x: firstMiddle, y: firstMiddle) })
        #expect(middle.red + middle.green + middle.blue > 3 * 60, "the first avatar's middle should be felt, saw \(middle)")
    }

    /// A dark sheet of the avatars, laid out four to a row, so the felt reads like the app's list.
    private static func sheet(_ images: [UIImage]) -> UIImage {
        let cell = CGSize(width: 74, height: 74)
        let columns = 4
        let rows = (images.count + columns - 1) / columns
        let margin: CGFloat = 16
        let size = CGSize(
            width: margin * 2 + cell.width * CGFloat(columns),
            height: margin * 2 + cell.height * CGFloat(rows))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.09, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, image) in images.enumerated() {
                let column = index % columns
                let row = index / columns
                let origin = CGPoint(
                    x: margin + CGFloat(column) * cell.width + (cell.width - image.size.width) / 2,
                    y: margin + CGFloat(row) * cell.height + (cell.height - image.size.height) / 2)
                image.draw(at: origin)
            }
        }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(
            x: -CGFloat(x), y: CGFloat(y) + 1 - CGFloat(image.height),
            width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }
}
#endif
