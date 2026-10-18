import Darwin
import Foundation
import MoleKit
import XCTest
@testable import Nora

@MainActor
final class TrashIntegrationTests: XCTestCase {
    func testBlockedTrashPreventsRemovalPromptAndQuittingBeforeConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
        let app = AppModel(visualSnapshot: true, home: root, trash: trash)
        let item = try XCTUnwrap(InstalledApp.decodeList(Data("""
            [{"name":"Fixture","path":"/synthetic/Fixture.app"}]
            """.utf8)).first)
        app.apps.stage = .review
        app.apps.screen = .plans
        app.apps.plans = [.init(app: item, entries: [item.path])]
        app.apps.requestUninstall(app, isOpen: { _ in XCTFail("Blocked removal must stop before checking apps"); return true })
        XCTAssertFalse(app.apps.askingToQuitForRemoval)
        XCTAssertEqual(app.apps.error, AppModel.trashBusyMessage)
        app.apps.removalOpenApps = [item]
        app.apps.askingToQuitForRemoval = true
        app.apps.quitAndUninstall(app)
        XCTAssertEqual(app.apps.stage, .review)
        XCTAssertFalse(app.apps.quittingForRemoval)
        XCTAssertFalse(app.apps.askingToQuitForRemoval)
        XCTAssertTrue(app.console.entries.isEmpty)
    }

    func testUnknownTrashRecoveryBlocksCleanupAndAppUpgrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
        let app = AppModel(visualSnapshot: true, home: root, trash: trash)
        XCTAssertTrue(trash.blocksOtherMutations)
        XCTAssertFalse(app.beginExclusiveRun("fixture"))
        app.apps.upgrade(app)
        XCTAssertEqual(app.apps.updatesNote, AppModel.trashBusyMessage)
        XCTAssertFalse(app.apps.runningUpdates)
    }

    func testCentralRunnerRejectsBeforeLoggingOrProcessCreation() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = TrashReminderModel(services: .disabled, monitor: InertTrashDirectoryMonitor(), permitsMonitoring: false)
        let app = AppModel(visualSnapshot: true, home: root, trash: trash)
        do {
            _ = try await app.run(["fixture-never-executed"])
            XCTFail("Unknown Trash recovery must reject process creation")
        } catch {
            XCTAssertEqual(error.localizedDescription, AppModel.trashBusyMessage)
        }
        XCTAssertTrue(app.console.entries.isEmpty)
    }

    func testUnreadableLegacyHandoverBlocksTrash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(visualSnapshot: true, home: root)
        try Data("invalid journal".utf8).write(to: app.handover.url)
        guard case .recovery? = app.trash.externalBlocker() else {
            return XCTFail("Malformed legacy app-update journal must block Trash deletion")
        }
    }

    func testSymlinkAndFIFOJournalsFailClosedWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(visualSnapshot: true, home: root)
        let journal = app.handover.url
        let target = root.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: target)
        guard case .recovery? = app.trash.externalBlocker() else { return XCTFail("Symlink journal must block") }
        try FileManager.default.removeItem(at: journal)
        XCTAssertEqual(mkfifo(journal.path, 0o600), 0)
        guard case .recovery? = app.trash.externalBlocker() else { return XCTFail("FIFO journal must block without waiting for a writer") }
    }

    func testActiveCleanupBlocksTrashAndVisualHostIsInert() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(visualSnapshot: true, home: root)
        app.cleanup.stage = .running
        guard case .busy? = app.trash.externalBlocker() else {
            return XCTFail("A running cleanup must block the new Trash operation")
        }
        app.trash.start()
        XCTAssertFalse(app.trash.isMonitoring)
    }
}
