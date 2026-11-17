import AppKit
import SwiftUI
import XCTest
@testable import Nora

/// Native PNG evidence for CI. All states are synthetic; controls cannot execute, animate, or scan.
@MainActor
final class TrashPromptVisualTests: XCTestCase {
    func testApprovedPanelStatesInAllSupportedLanguages() throws {
        let snapshot = TrashReminderSnapshot(contentIdentity: "visual-only", topLevelItemCount: 8,
                                             entryCount: 31, logicalBytes: 1_400_000_000)
        for locale in ["en", "uk", "ru"] {
            for phase in [TrashReminderModel.Phase.review, .scanning, .cleaning, .unavailable, .recoveryRequired, .finished] {
                let model = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
                model.setSnapshotFixture(phase: phase, snapshot: [.unavailable, .recoveryRequired].contains(phase) ? nil : snapshot,
                    outcome: phase == .finished ? .init(status: .cancelled, deletedEntryCount: 5,
                                                       detail: "Synthetic partial result. Nothing was executed.") : nil)
                try capture(TrashPromptView(model: model, animationEnabled: false)
                    .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                    name: "trash-panel-\(phase)-\(locale)-520x260", size: CGSize(width: 520, height: 260))
                XCTAssertFalse(model.isMonitoring)
                let busy = phase == .scanning || phase == .cleaning
                XCTAssertEqual(model.isWorking, busy)
                XCTAssertEqual(model.canCancelOperation, busy)
                XCTAssertFalse(model.stopRequested)
                XCTAssertFalse(model.snapshotFixtureHasScheduledWork)
                XCTAssertFalse(model.isPresented)
            }
            let empty = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            empty.setSnapshotFixture(phase: .review, snapshot: .init(contentIdentity: "empty", topLevelItemCount: 0, entryCount: 0, logicalBytes: 0))
            try capture(TrashPromptView(model: empty, animationEnabled: false)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-panel-empty-\(locale)-520x260", size: CGSize(width: 520, height: 260))
        }
    }

    func testStoppingAndRecoveryInProgressPresentations() throws {
        let snapshot = TrashReminderSnapshot(contentIdentity: "visual-stopping-only", topLevelItemCount: 8,
                                             entryCount: 31, logicalBytes: 1_400_000_000)
        for locale in ["en", "uk", "ru"] {
            let stopping = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            stopping.setSnapshotFixture(phase: .cleaning, snapshot: snapshot, operation: .cleaning, stopRequested: true)
            try capture(TrashPromptView(model: stopping, animationEnabled: false)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-panel-stopping-\(locale)-520x260", size: CGSize(width: 520, height: 260))
            XCTAssertTrue(stopping.isWorking)
            XCTAssertTrue(stopping.canCancelOperation)
            XCTAssertTrue(stopping.stopRequested)
            XCTAssertFalse(stopping.snapshotFixtureHasScheduledWork)

            let recovering = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            recovering.setSnapshotFixture(phase: .recoveryRequired, snapshot: nil, operation: .recovering)
            try capture(TrashPromptView(model: recovering, animationEnabled: false)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-panel-recovery-in-progress-\(locale)-520x260", size: CGSize(width: 520, height: 260))
            try capture(Form { TrashReminderSettingsSection(model: recovering) }
                .formStyle(.grouped).preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-settings-recovery-in-progress-\(locale)-640x420", size: CGSize(width: 640, height: 420))
            XCTAssertTrue(recovering.isWorking)
            XCTAssertFalse(recovering.canCancelOperation, "Safe restoration has no pretend Cancel action")
            XCTAssertFalse(recovering.stopRequested)
            XCTAssertTrue(recovering.recoveryPending)
            XCTAssertFalse(recovering.snapshotFixtureHasScheduledWork)
            XCTAssertFalse(recovering.isMonitoring)
            XCTAssertFalse(recovering.isPresented)
        }
    }

    /// The states added for audit items C1 and C2: a cleanup that did not finish, the way out of a recovery
    /// Nora cannot finish, and the question before quitting. Written to NoraVisualSmoke as PNGs too.
    func testFailureAndRecoveryWayOutPresentations() throws {
        let snapshot = TrashReminderSnapshot(contentIdentity: "visual-failure-only", topLevelItemCount: 8,
                                             entryCount: 31, logicalBytes: 1_400_000_000)
        let failure = "Home Trash: Nora could not remove 3 items and left them where they were. The Trash on Backup must be emptied in Finder."
        let folder = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Nora/TrashRecovery-preserved-20261117-183045", isDirectory: true)
        for locale in ["en", "uk", "ru"] {
            let failed = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            failed.setSnapshotFixture(phase: .finished, snapshot: snapshot,
                                      outcome: .init(status: .failed, deletedEntryCount: 3, detail: failure), diagnostic: failure)
            try capture(TrashPromptView(model: failed, animationEnabled: false)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-panel-failed-\(locale)-520x260", size: CGSize(width: 520, height: 260))
            XCTAssertTrue(failed.diagnostic?.hasPrefix("Home Trash") == true)

            let stuck = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            stuck.setSnapshotFixture(phase: .recoveryRequired, snapshot: nil,
                                     diagnostic: "Home: unrecognized recovery entry \"notes.txt\"")
            try capture(Form { TrashReminderSettingsSection(model: stuck) }
                .formStyle(.grouped).preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-settings-recovery-way-out-\(locale)-640x560", size: CGSize(width: 640, height: 560))

            let moved = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
            moved.setSnapshotFixture(phase: .unavailable, snapshot: nil,
                                     notice: String(localized: "The recovery data was moved aside and nothing was deleted. Review the Trash again."),
                                     diagnostic: "The recovery data was moved to \(folder.path). Nothing was deleted.", preservedFolder: folder)
            try capture(Form { TrashReminderSettingsSection(model: moved) }
                .formStyle(.grouped).preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: locale)).allowsHitTesting(false),
                name: "trash-settings-recovery-moved-\(locale)-640x420", size: CGSize(width: 640, height: 420))
            XCTAssertEqual(moved.preservedFolder, folder)
            XCTAssertFalse(moved.blocksOtherMutations)
        }
        let running = ["/opt/homebrew/bin/mo clean --dry-run", "brew upgrade --cask visual-studio-code"]
        assertAlertContent(QuitGuard.makeAlert(commands: running), lists: running)
    }

    func testDecorativeMascotRestAndWaveFrames() throws {
        for angle in [0.0, 18.0, -18.0] {
            try capture(TrashMascot(size: 76, animationEnabled: false, snapshotWaveAngle: angle)
                .padding(12).background(Color(hex: 0x0C4744)).allowsHitTesting(false),
                name: "trash-mascot-wave-\(Int(angle))", size: CGSize(width: 100, height: 100))
        }
    }

    func testLowerLeftPlacementUsesVisibleFrameIncludingSideDockAndNegativeDisplayCoordinates() {
        for visible in [NSRect(x: 0, y: 80, width: 1440, height: 790),
                        NSRect(x: 90, y: 0, width: 1350, height: 870),
                        NSRect(x: -1440, y: -200, width: 1440, height: 870)] {
            let origin = TrashPromptController.origin(in: visible, panelSize: NSSize(width: 520, height: 260))
            XCTAssertEqual(origin.x, visible.minX + 16)
            XCTAssertEqual(origin.y, visible.minY + 16)
            XCTAssertTrue(visible.contains(NSRect(origin: origin, size: NSSize(width: 520, height: 260))))
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
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try record(bitmap, name: name)
    }

    /// The system's own alert window cannot be drawn without being shown, so it is checked as words: the
    /// message, the explanation and both buttons are really in the window, in the language of this run.
    private func assertAlertContent(_ alert: NSAlert, lists commands: [String]) {
        alert.layout()
        let view = alert.window.contentView!
        view.layoutSubtreeIfNeeded()
        let words = Self.texts(in: view)
        for expected in [String(localized: "Nora is still working"), String(localized: "Keep Working"),
                         String(localized: "Stop and Quit")] {
            XCTAssertTrue(words.contains(expected), "\(expected) is missing from \(words)")
        }
        XCTAssertTrue(words.contains { $0.contains(commands[0]) }, "the running command is named: \(words)")
    }

    private static func texts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField { found.append(field.stringValue) }
        if let button = view as? NSButton { found.append(button.title) }
        for sub in view.subviews { found += texts(in: sub) }
        return found
    }

    private func record(_ bitmap: NSBitmapImageRep, name: String) throws {
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_024)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoraVisualSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
