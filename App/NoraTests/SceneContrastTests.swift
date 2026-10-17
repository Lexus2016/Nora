import AppKit
import SwiftUI
import XCTest
@testable import Nora

/// Card text must stay readable on every module scene. Each scene is rendered with a card fill
/// over its whole area; the brightest point under the cards is the worst case for white text.
@MainActor
final class SceneContrastTests: XCTestCase {
    /// WCAG AA 4.5:1 for every small text on a card: details (fg2) and hints (muted) alike.
    func testCardTextContrastOnEveryScene() throws {
        var report: [String] = []
        for module in Module.allCases {
            let worst = try brightestCardPixel(module.palette)
            let title = Contrast.ratio(.white, over: worst)
            let body = Contrast.ratio(Contrast.blend(.white, alpha: 0.82, over: worst), over: worst)
            let muted = Contrast.ratio(Contrast.blend(.white, alpha: Palette.mutedOpacity, over: worst), over: worst)
            report.append("\(module): title \(Self.fmt(title)) body \(Self.fmt(body)) muted \(Self.fmt(muted))")
            XCTAssertGreaterThanOrEqual(body, 4.5, "\(module) body text on cards")
            XCTAssertGreaterThanOrEqual(muted, 4.5, "\(module) muted text on cards")
        }
        print(report.joined(separator: "\n"))
    }

    /// Text that sits on the scene itself: the header subtitle over HeaderShade, the command line
    /// on its dark chip, and notices on their glass chip.
    func testTextOnSceneContrast() throws {
        let size = CGSize(width: 1180, height: 780)
        let criticalColor = try XCTUnwrap(NSColor(Palette.crit).usingColorSpace(.sRGB))
        let critical = Contrast.RGB(r: Double(criticalColor.redComponent), g: Double(criticalColor.greenComponent),
                                   b: Double(criticalColor.blueComponent))
        for module in Module.allCases {
            let palette = module.palette
            let header = ZStack(alignment: .top) {
                SceneBackground(palette: palette)
                HeaderShade(palette: palette)
            }
            .frame(width: size.width, height: size.height)
            let headWorst = try brightest(header, x: 180...1150, y: 60...150)
            let subtitle = Contrast.ratio(Contrast.blend(.white, alpha: 0.82, over: headWorst), over: headWorst)
            XCTAssertGreaterThanOrEqual(subtitle, 4.5, "\(module) header subtitle")

            let plain = SceneBackground(palette: palette).frame(width: size.width, height: size.height)
            let sceneWorst = try brightest(plain, x: 110...1150, y: 200...700)
            let chip = Contrast.blend(Contrast.RGB(r: 0, g: 0, b: 0), alpha: CommandPreview.chipOpacity, over: sceneWorst)
            let command = Contrast.ratio(Contrast.blend(.white, alpha: 0.82, over: chip), over: chip)
            XCTAssertGreaterThanOrEqual(command, 4.5, "\(module) command line")

            let noticeBackground = try brightestCardPixel(palette, additionalScrim: Notice.additionalScrimOpacity)
            let warn = Contrast.ratio(Contrast.RGB(r: 1, g: 0.827, b: 0.431), over: noticeBackground)
            let error = Contrast.ratio(critical, over: noticeBackground)
            XCTAssertGreaterThanOrEqual(warn, 4.5, "\(module) warning notice on its chip")
            XCTAssertGreaterThanOrEqual(error, 4.5, "\(module) critical notice on its chip")
            print(String(format: "TEXT %@: subtitle %.2f command %.2f notice %.2f error %.2f", "\(module)", subtitle, command, warn, error))
        }
    }

    private func brightest(_ view: some View, x: ClosedRange<Int>, y: ClosedRange<Int>) throws -> Contrast.RGB {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let pixels = try Contrast.pixels(try XCTUnwrap(renderer.cgImage))
        var worst = Contrast.RGB(r: 0, g: 0, b: 0)
        for py in stride(from: y.lowerBound, through: y.upperBound, by: 6) {
            for px in stride(from: x.lowerBound, through: x.upperBound, by: 6) {
                let p = pixels(px, py)
                if Contrast.luminance(p) > Contrast.luminance(worst) { worst = p }
            }
        }
        return worst
    }

    /// Renders the scene with a card fill over the content area and returns the brightest pixel
    /// in the region where cards sit (right of the rail, below the title).
    private func brightestCardPixel(_ palette: ScenePalette, additionalScrim: Double = 0) throws -> Contrast.RGB {
        let size = CGSize(width: 1100, height: 760)
        let view = ZStack {
            SceneBackground(palette: palette)
            VolumeFill(radius: 0).environment(\.scenePalette, palette)
                .overlay(Color.black.opacity(additionalScrim))
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let pixels = try Contrast.pixels(image)
        var worst = Contrast.RGB(r: 0, g: 0, b: 0)
        for y in stride(from: 150, to: Int(size.height) - 40, by: 8) {
            for x in stride(from: 40, to: Int(size.width) - 40, by: 8) {
                let p = pixels(x, y)
                if Contrast.luminance(p) > Contrast.luminance(worst) { worst = p }
            }
        }
        return worst
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// WCAG 2.x relative luminance and contrast ratio in sRGB.
enum Contrast {
    struct RGB {
        var r: Double, g: Double, b: Double
        static let white = RGB(r: 1, g: 1, b: 1)
    }

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    static func ratio(_ fg: RGB, over bg: RGB) -> Double {
        let a = luminance(fg), b = luminance(bg)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func blend(_ fg: RGB, alpha: Double, over bg: RGB) -> RGB {
        RGB(r: fg.r * alpha + bg.r * (1 - alpha), g: fg.g * alpha + bg.g * (1 - alpha), b: fg.b * alpha + bg.b * (1 - alpha))
    }

    /// Reads an image as sRGB bytes and returns a pixel lookup.
    static func pixels(_ image: CGImage) throws -> (Int, Int) -> RGB {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let copy = data
        return { x, y in
            let i = (y * width + x) * 4
            return RGB(r: Double(copy[i]) / 255, g: Double(copy[i + 1]) / 255, b: Double(copy[i + 2]) / 255)
        }
    }
}

final class RailLayoutTests: XCTestCase {
    /// Every module and Settings fit the window's minimum height (620 pt).
    @MainActor func testRailFitsMinimumWindowHeight() {
        let count = 12
        let item = Rail.itemHeight(for: 620, count: count)
        XCTAssertGreaterThanOrEqual(item, 32)
        let used = 50 + 50 + 16 + 6 * CGFloat(count + 2) + item * CGFloat(count)
        XCTAssertLessThanOrEqual(used, 620)
        XCTAssertEqual(Rail.itemHeight(for: 1000, count: count), 52)
    }
}
