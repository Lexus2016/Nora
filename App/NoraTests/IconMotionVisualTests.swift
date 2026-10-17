import AppKit
import SwiftUI
import XCTest
@testable import Nora

/// Deterministic native PNG artifacts. These render only decorative components, not live models,
/// tool calls or deletion UI. Full-scene before/after coverage remains MenuVisualSmokeTests.
@MainActor
final class IconMotionVisualTests: XCTestCase {
    func testEveryModuleGlassAtFixedRestAndTurn() throws {
        for module in Module.allCases {
            XCTAssertNotNil(GlassLibrary.image(module.glass), "Missing or undecodable original glass asset: \(module.glass)")
        }
        for (name, time) in [("front", 0.0), ("turn", 1.2)] {
            for offset in [0, 6] {
                let modules = Array(Module.allCases.dropFirst(offset).prefix(6))
                let board = LazyVGrid(columns: Array(repeating: GridItem(.fixed(210)), count: 3), spacing: 20) {
                    ForEach(modules) { module in
                        VStack(spacing: 8) {
                            Glass3D(name: module.glass, size: 170, glow: module.palette.glow,
                                    snapshotTime: time)
                            Text(verbatim: module.titleText).font(.system(size: 13, weight: .semibold))
                        }
                        .frame(width: 210, height: 210)
                        .background(SceneBackground(palette: module.palette))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(20).background(Palette.window).foregroundStyle(.white)
                try capture(board, name: "icons-glass-\(offset)-\(name)", size: CGSize(width: 690, height: 480))
            }
        }
    }

    func testFeatureDiscsAtActualSizesAndStaticBusyOrb() throws {
        let board = VStack(spacing: 24) {
            ForEach([CGFloat(32), 34, 44], id: \.self) { size in
                HStack(spacing: 14) {
                    ForEach(Module.allCases) { module in
                        FeatureDisc(symbol: module.symbol, tint: module.palette.glow, size: size)
                    }
                }
            }
            HStack(spacing: 32) {
                ForEach([Module.smartCare, .cleanup, .applications, .performance], id: \.self) { module in
                    BottomOrb(action: OrbAction(title: "Stop", busy: true, action: {}), palette: module.palette)
                        .frame(width: 150, height: 150)
                }
            }
        }
        .padding(28).background(Palette.window)
        try capture(board, name: "icons-discs-and-busy-stop", size: CGSize(width: 770, height: 420))
    }

    func testTrashMascotRestWaveAndDisabledMotionAtApprovedSizes() throws {
        let board = VStack(spacing: 18) {
            ForEach([CGFloat(64), 76, 80], id: \.self) { size in
                HStack(spacing: 24) {
                    Text(verbatim: "\(Int(size)) pt").font(.system(size: 12)).frame(width: 44)
                    TrashMascot(size: size, snapshotWaveAngle: 0)
                    TrashMascot(size: size, snapshotWaveAngle: -18)
                    TrashMascot(size: size, snapshotWaveAngle: 18)
                    TrashMascot(size: size, animationEnabled: false)
                }
            }
        }
        .padding(20).foregroundStyle(.white).background(Palette.window)
        try capture(board, name: "trash-mascot-rest-wave-disabled", size: CGSize(width: 520, height: 320))
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).allowsHitTesting(false))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 4_096)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
