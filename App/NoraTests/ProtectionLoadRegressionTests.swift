import XCTest
import MoleKit
@testable import Nora

/// All readers and writers are synthetic. No probe or user's configuration is accessed.
@MainActor
final class ProtectionLoadRegressionTests: XCTestCase {
    private nonisolated static func snapshot(_ marker: String = "new") -> ProtectionModel.Snapshot {
        ProtectionModel.Snapshot(home: URL(fileURLWithPath: "/fixture/home"), defaults: ["~/safe"],
                                 cleanLines: ["/fixture/home/safe", "~/\(marker)"],
                                 tasks: [("First", "first"), ("Second", "second")],
                                 optimizeLines: ["second", "future-task"], purgeLines: ["~/project"])
    }

    func testSlowReadDoesNotBlockMainActorAndCommitsOneCompleteSnapshot() async throws {
        var writes: [String] = []
        let model = ProtectionModel(write: { _, body in writes.append(body) })
        let pause = PausedProtectionRead()
        defer { pause.resume() }
        let snapshot = Self.snapshot()
        let task = try XCTUnwrap(model.load { cancellation in
            try pause.read(cancellation)
            return snapshot
        })
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        let started = await pause.waitUntilStarted()
        XCTAssertTrue(started, "The reader must start without occupying the MainActor")
        XCTAssertEqual(pause.ranOnMainThread, false)
        model.addPattern("~/during-read")
        model.setTask("first", excluded: true)
        model.addProjectFolder("/fixture/during-read")
        XCTAssertTrue(writes.isEmpty)
        XCTAssertTrue(model.loading)
        pause.resume()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.cleanupReady)
        XCTAssertEqual(model.defaults, ["~/safe"])
        XCTAssertEqual(model.custom, ["~/new"])
        XCTAssertTrue(model.cleanFileExists)
        XCTAssertEqual(model.excludedTasks, ["second"])
        XCTAssertEqual(model.projectFolders, ["~/project"])
        XCTAssertTrue(model.projectFileExists)
        model.setTask("first", excluded: true)
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(writes[0].contains("first\nsecond\nfuture-task\n"))
    }

    func testCancellingReturnedTaskPropagatesToSynchronousProbeAndDisablesEditing() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("Cancellation must not write") })
        let pause = PausedProtectionRead()
        defer { pause.resume() }
        let snapshot = Self.snapshot()
        let task = try XCTUnwrap(model.load { cancellation in
            try pause.read(cancellation)
            return snapshot
        })
        let started = await pause.waitUntilStarted()
        XCTAssertTrue(started)
        task.cancel()
        await task.value
        XCTAssertTrue(pause.wasCancelled)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertNil(model.message)
        model.addPattern("~/after-cancel")
        XCTAssertTrue(model.custom.isEmpty)
    }

    func testCancelledOlderLoadCannotClearNewLoadingStateOrCommitItsResult() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("A read must not write") })
        let older = PausedProtectionRead(observesCancellation: false)
        let newer = PausedProtectionRead()
        defer { older.resume(); newer.resume() }
        let oldSnapshot = Self.snapshot("old"), newSnapshot = Self.snapshot("latest")
        let oldTask = try XCTUnwrap(model.load { cancellation in
            try older.read(cancellation)
            return oldSnapshot
        })
        let oldStarted = await older.waitUntilStarted()
        XCTAssertTrue(oldStarted)
        let newTask = try XCTUnwrap(model.load { cancellation in
            try newer.read(cancellation)
            return newSnapshot
        })
        let newStarted = await newer.waitUntilStarted()
        XCTAssertTrue(newStarted)
        XCTAssertTrue(older.wasCancelled)
        older.resume()
        await oldTask.value
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertTrue(model.custom.isEmpty)
        XCTAssertNil(model.message)
        newer.resume()
        await newTask.value
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.custom, ["~/latest"])
    }

    func testLateFailureCannotReplaceSuccessfulRetry() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("A read must not write") })
        let older = PausedProtectionRead(observesCancellation: false)
        defer { older.resume() }
        let snapshot = Self.snapshot("retry")
        let oldTask = try XCTUnwrap(model.load { cancellation in
            try older.read(cancellation)
            throw CocoaError(.fileReadNoPermission)
        })
        let started = await older.waitUntilStarted()
        XCTAssertTrue(started)
        await model.load { _ in snapshot }?.value
        XCTAssertTrue(model.loaded)
        older.resume()
        await oldTask.value
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.cleanupReady)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.custom, ["~/retry"])
        XCTAssertNil(model.message)
    }

    func testLeavingScreenCancelsPendingLoadAndRejectsLateRead() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("A read must not write") })
        let pause = PausedProtectionRead(observesCancellation: false)
        defer { pause.resume() }
        let snapshot = Self.snapshot()
        let task = try XCTUnwrap(model.load { cancellation in
            try pause.read(cancellation)
            return snapshot
        })
        let started = await pause.waitUntilStarted()
        XCTAssertTrue(started)
        model.cancelLoad()
        XCTAssertTrue(pause.wasCancelled)
        XCTAssertFalse(model.loading)
        pause.resume()
        await task.value
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertTrue(model.custom.isEmpty)
    }

    func testExclusiveRunStartingDuringReadRejectsSnapshotAtCommit() async throws {
        var busy = false
        let model = ProtectionModel(write: { _, _ in XCTFail("A locked list must not write") })
        let pause = PausedProtectionRead()
        defer { pause.resume() }
        let snapshot = Self.snapshot()
        let task = try XCTUnwrap(model.load(busy: { busy }) { cancellation in
            try pause.read(cancellation)
            return snapshot
        })
        let started = await pause.waitUntilStarted()
        XCTAssertTrue(started)
        busy = true
        pause.resume()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertTrue(model.defaults.isEmpty)
        XCTAssertTrue(model.custom.isEmpty)
        XCTAssertNotNil(model.message)
        model.addPattern("~/locked")
    }

    func testBriefExclusiveRunInvalidatesSnapshotEvenAfterItEnds() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-transient-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = AppModel(visualSnapshot: true, home: home)
        let pause = PausedProtectionRead(observesCancellation: false)
        defer { pause.resume() }
        let snapshot = Self.snapshot("temporary-overlay")
        let task = try XCTUnwrap(app.protection.load(busy: { app.exclusiveRunActive }) { cancellation in
            try pause.read(cancellation)
            return snapshot
        })
        let started = await pause.waitUntilStarted()
        XCTAssertTrue(started)
        XCTAssertTrue(app.beginExclusiveRun("brief-fixture"))
        app.endExclusiveRun("brief-fixture")
        XCTAssertFalse(app.exclusiveRunActive)
        pause.resume()
        await task.value
        XCTAssertFalse(app.protection.loading)
        XCTAssertFalse(app.protection.loaded)
        XCTAssertFalse(app.protection.cleanupReady)
        XCTAssertTrue(app.protection.custom.isEmpty)
        XCTAssertTrue(app.protection.defaults.isEmpty)
    }

    func testAlreadyLockedListDoesNotStartReader() {
        let model = ProtectionModel(write: { _, _ in XCTFail("A locked list must not write") })
        let snapshot = Self.snapshot()
        let task = model.load(busy: { true }) { _ in
            XCTFail("An exclusive run must prevent reading its temporary whitelist")
            return snapshot
        }
        XCTAssertNil(task)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertNotNil(model.message)
    }

    func testFailedDefaultsRefreshRetainsPriorDataButBlocksEveryEdit() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("Failed defaults must block edits") })
        let snapshot = Self.snapshot("saved")
        await model.load { _ in snapshot }?.value
        XCTAssertTrue(model.loaded)
        let task = try XCTUnwrap(model.load { cancellation in
            try ProtectionModel.readSnapshot(home: snapshot.home, cancellation: cancellation,
                readDefaults: { throw CocoaError(.fileReadNoPermission) },
                readTasks: { XCTFail("Defaults must fail closed before other reads"); return [] },
                readClean: { XCTFail("Defaults must fail closed before other reads"); return nil },
                readOptimize: { [] }, readPurge: { nil })
        })
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertEqual(model.defaults, ["~/safe"])
        XCTAssertEqual(model.custom, ["~/saved"])
        XCTAssertNotNil(model.message)
        model.addPattern("~/blocked")
        model.setTask("first", excluded: true)
        model.addProjectFolder("/fixture/blocked")
        XCTAssertEqual(model.excludedTasks, ["second"])
        XCTAssertEqual(model.projectFolders, ["~/project"])
        await model.load { _ in snapshot }?.value
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.cleanupReady)
        XCTAssertNil(model.message)
    }

    func testUnreadableConfigurationDoesNotCommitNewDefaultsOrPartialState() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("A failed read must not write") })
        let snapshot = Self.snapshot("saved")
        await model.load { _ in snapshot }?.value
        let task = try XCTUnwrap(model.load { cancellation in
            try ProtectionModel.readSnapshot(home: snapshot.home, cancellation: cancellation,
                readDefaults: { ["~/different-default"] }, readTasks: { [] },
                readClean: { ["~/different-custom"] }, readOptimize: { [] },
                readPurge: { throw CocoaError(.fileReadNoPermission) })
        })
        await task.value
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.cleanupReady)
        XCTAssertEqual(model.defaults, snapshot.defaults)
        XCTAssertEqual(model.custom, ["~/saved"])
        XCTAssertEqual(model.tasks.map(\.id), ["first", "second"])
        XCTAssertEqual(model.excludedTasks, ["second"])
        XCTAssertEqual(model.projectFolders, ["~/project"])
        XCTAssertNotNil(model.message)
    }

    func testAbsentFilesAndGenuinelyEmptyDefaultsCanLoadSuccessfully() async throws {
        let model = ProtectionModel(write: { _, _ in XCTFail("A read must not write") })
        let task = try XCTUnwrap(model.load { cancellation in
            try ProtectionModel.readSnapshot(home: URL(fileURLWithPath: "/fixture/home"), cancellation: cancellation,
                readDefaults: { [] }, readTasks: { [] }, readClean: { nil },
                readOptimize: { [] }, readPurge: { nil })
        })
        await task.value
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.cleanupReady)
        XCTAssertFalse(model.cleanFileExists)
        XCTAssertFalse(model.projectFileExists)
        XCTAssertTrue(model.defaults.isEmpty)
        XCTAssertNil(model.message)
    }
}

/// A bounded pause on the detached reader. Tests await the start from another detached task,
/// so none of the synchronization blocks the MainActor or relies on a fixed number of yields.
private final class PausedProtectionRead: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let observesCancellation: Bool
    private var cancellation: MoleProbeCancellation?
    private var mainThread: Bool?

    init(observesCancellation: Bool = true) {
        self.observesCancellation = observesCancellation
    }

    var ranOnMainThread: Bool? { lock.withLock { mainThread } }
    var wasCancelled: Bool {
        guard let cancellation = lock.withLock({ cancellation }) else { return false }
        do { try cancellation.checkCancellation(); return false }
        catch { return true }
    }

    func read(_ cancellation: MoleProbeCancellation) throws {
        lock.withLock {
            self.cancellation = cancellation
            mainThread = Thread.isMainThread
        }
        started.signal()
        let deadline = Date().addingTimeInterval(5)
        while resumed.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if observesCancellation { try cancellation.checkCancellation() }
            guard Date() < deadline else { throw CocoaError(.fileReadUnknown) }
        }
    }

    func waitUntilStarted() async -> Bool {
        await Task.detached { [self] in
            started.wait(timeout: .now() + .seconds(3)) == .success
        }.value
    }

    func resume() { resumed.signal() }
}
