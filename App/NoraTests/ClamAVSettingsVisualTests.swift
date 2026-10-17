import AppKit
import MoleKit
import SwiftUI
import XCTest
@testable import Nora

/// Synthetic state plus production Settings rows. No real tools or network are used.
@MainActor
final class ClamAVSettingsVisualTests: XCTestCase {
    func testEngineDefinitionAndFailurePresentations() async throws {
        for state in ["installed", "outdated", "failed-check", "missing-homebrew", "missing-engine", "busy"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nora-clamav-visual-\(UUID().uuidString)")
            let suite = "nora-clamav-visual-\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("clamav/database"), withIntermediateDirectories: true)
            try Data("synthetic database".utf8).write(to: root.appendingPathComponent("clamav/database/daily.cvd"))
            defer {
                try? FileManager.default.removeItem(at: root)
                preferences.removePersistentDomain(forName: suite)
            }
            let app = AppModel(visualSnapshot: true, home: root)
            var calls = 0
            var services = ClamAVManagementServices()
            services.locate = {
                if state == "missing-engine" { return ClamAVTools(clamscan: nil, freshclam: nil, clamd: nil, clamdscan: nil) }
                return ClamAVTools(clamscan: URL(fileURLWithPath: "/fixture/bin/clamscan"),
                                            freshclam: URL(fileURLWithPath: "/fixture/bin/freshclam"), clamd: nil, clamdscan: nil) }
            services.brew = { state == "missing-homebrew" ? nil : URL(fileURLWithPath: "/fixture/bin/brew") }
            services.isHomebrewManaged = { _, _ in true }
            services.now = { Date(timeIntervalSince1970: 1_800_000_000) }
            var holdCheck = false
            var checkingPaused = false
            services.run = { command, _, _ in
                calls += 1
                if holdCheck {
                    checkingPaused = true
                    try await Task.sleep(for: .seconds(30))
                }
                if command.arguments.contains("--version") {
                    return CommandResult(status: 0, stdout: "ClamAV 1.4.3/28000/Sat Oct 17 10:20:30 2026", stderr: "")
                }
                if state == "failed-check" { return CommandResult(status: 1, stdout: "", stderr: "Synthetic network unavailable") }
                let outdated = state == "outdated"
                let version = outdated ? "1.5.0" : "1.4.3"
                return CommandResult(status: 0, stdout: "{\"formulae\":[{\"name\":\"clamav\",\"versions\":{\"stable\":\"\(version)\"},\"revision\":0,\"installed\":[{\"version\":\"1.4.3\"}],\"outdated\":\(outdated),\"pinned\":false}]}", stderr: "")
            }
            let model = SecurityModel(home: root, support: root, clamavServices: services, preferences: preferences)
            if state == "missing-engine" {
                XCTAssertNil(model.refreshClamAVStatus(app))
            } else if state == "missing-homebrew" {
                try await XCTUnwrap(model.refreshClamAVStatus(app)).value
                XCTAssertNil(model.checkEngineUpdate(app))
            } else { try await XCTUnwrap(model.checkEngineUpdate(app)).value }
            var pending: Task<Void, Never>?
            if state == "busy" {
                holdCheck = true
                pending = model.checkEngineUpdate(app)
                while !checkingPaused { await Task.yield() }
            }
            let callsBeforeRendering = calls
            let entriesBeforeRendering = app.console.entries.count
            for locale in ["en", "uk", "ru"] {
                for height in [580, 1600] {
                    let view = Form { SecuritySettingsSection(model: model) }
                        .formStyle(.grouped).environment(app)
                        .environment(\.locale, Locale(identifier: locale))
                        .preferredColorScheme(.dark).allowsHitTesting(false)
                    try capture(view, name: "clamav-\(state)-\(locale)-640x\(height)", size: CGSize(width: 640, height: height))
                }
            }
            XCTAssertEqual(calls, callsBeforeRendering, "Rendering must not run even an injected probe")
            XCTAssertEqual(app.console.entries.count, entriesBeforeRendering)
            if let pending {
                model.cancelSetup()
                await pending.value
            }
        }
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) throws {
        let host = NSHostingView(rootView: view)
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
