import XCTest
import MoleKit
@testable import Nora

/// Every process boundary is injected. These tests never install, update, scan or contact a server.
@MainActor
final class ClamAVManagementTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var suite: String!
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let tools = ClamAVTools(clamscan: URL(fileURLWithPath: "/fixture/bin/clamscan"),
                                    freshclam: URL(fileURLWithPath: "/fixture/bin/freshclam"), clamd: nil, clamdscan: nil)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nora-clamav-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "nora-clamav-tests-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func model(run: @escaping (ShellCommand, [String: String], TimeInterval?) async throws -> CommandResult,
                       brew: URL? = URL(fileURLWithPath: "/fixture/bin/brew"), managed: Bool = true) -> SecurityModel {
        var services = ClamAVManagementServices()
        services.locate = { self.tools }
        services.brew = { brew }
        services.isHomebrewManaged = { _, _ in managed }
        services.run = run
        services.now = { self.now }
        return SecurityModel(home: root, support: root, clamavServices: services, preferences: preferences)
    }

    private func success(_ output: String = "") -> CommandResult { CommandResult(status: 0, stdout: output, stderr: "") }
    private func catalog(version: String = "1.5.0", installed: String = "1.4.3", outdated: Bool = true) -> String {
        "{\"formulae\":[{\"name\":\"clamav\",\"versions\":{\"stable\":\"\(version)\"},\"revision\":0,\"installed\":[{\"version\":\"\(installed)\"}],\"outdated\":\(outdated),\"pinned\":false}]}"
    }

    func testInitialStateDoesNotClaimCurrentOrLaunchTools() {
        let model = model { _, _, _ in XCTFail("No command expected"); throw CancellationError() }
        XCTAssertNil(model.installedEngine)
        XCTAssertNil(model.engineCatalog)
        XCTAssertNil(model.engineCheckedAt)
        XCTAssertFalse(model.canUpgradeEngine)
    }

    func testReadOnlyVersionAndCatalogChecksAreBoundedLoggedAndDistinct() async throws {
        var commands: [ShellCommand] = []
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, environment, timeout in
            commands.append(command)
            XCTAssertNotNil(timeout)
            XCTAssertEqual(environment["TZ"], "UTC")
            XCTAssertEqual(environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
            if command.arguments.contains("--version") { return self.success("ClamAV 1.4.3/28000/Sat Oct 17 10:20:30 2026") }
            return self.success(self.catalog())
        }
        let task = try XCTUnwrap(model.checkEngineUpdate(app))
        XCTAssertTrue(model.checkingEngine)
        XCTAssertTrue(model.securityBusy)
        XCTAssertNil(model.updateDatabase(app), "Busy checks may not launch concurrent freshclam")
        await task.value
        XCTAssertEqual(model.installedEngine?.engine, "1.4.3")
        XCTAssertEqual(model.engineCatalog?.version, "1.5.0")
        XCTAssertEqual(model.engineCheckedAt, now)
        XCTAssertTrue(model.canUpgradeEngine)
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, ["--database", root.appendingPathComponent("clamav/database").path, "--version"])
        XCTAssertTrue(app.console.entries.allSatisfy { $0.owner == .security && $0.status == 0 })
        XCTAssertNil(model.lastEngineSuccess)
        XCTAssertNil(model.lastDatabaseSuccess)
    }

    func testFailedRecheckClearsPreviousAvailableVersion() async throws {
        var fail = false
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, _, _ in
            if command.arguments.contains("--version") { return self.success("ClamAV 1.4.3") }
            if fail { return CommandResult(status: 1, stdout: "", stderr: "network unavailable") }
            return self.success(self.catalog())
        }
        try await XCTUnwrap(model.checkEngineUpdate(app)).value
        XCTAssertTrue(model.canUpgradeEngine)
        fail = true
        try await XCTUnwrap(model.checkEngineUpdate(app)).value
        XCTAssertNil(model.engineCatalog)
        XCTAssertNil(model.engineCheckedAt)
        XCTAssertFalse(model.canUpgradeEngine)
        XCTAssertNotNil(model.engineResult)
        XCTAssertEqual(app.console.entries.last?.status, 1)
    }

    func testMissingHomebrewAndUnmanagedEngineCannotUpgrade() async throws {
        let app = AppModel(visualSnapshot: true, home: root)
        let missing = model(run: { _, _, _ in XCTFail("No command expected"); throw CancellationError() }, brew: nil)
        XCTAssertNil(missing.checkEngineUpdate(app))
        XCTAssertNotNil(missing.engineResult)
        XCTAssertNil(missing.upgradeEngine(app))
        let unmanaged = model(run: { command, _, _ in
            command.arguments.contains("--version") ? self.success("ClamAV 1.4.3") : self.success(self.catalog())
        }, managed: false)
        try await XCTUnwrap(unmanaged.checkEngineUpdate(app)).value
        XCTAssertFalse(unmanaged.canUpgradeEngine)
        XCTAssertNil(unmanaged.upgradeEngine(app))
    }

    func testUpgradeReprobesEngineAndDoesNotRunFreshclamOrChangeDefinitionSuccess() async throws {
        var upgraded = false
        var commands: [ShellCommand] = []
        let prior = now.addingTimeInterval(-100_000)
        preferences.set(prior, forKey: "security.clamav.lastUpdate")
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, environment, _ in
            commands.append(command)
            XCTAssertEqual(environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
            if command.arguments == ClamAVFormulaInfo.upgradeArguments { upgraded = true; return self.success() }
            if command.arguments.contains("--version") { return self.success(upgraded ? "ClamAV 1.5.0" : "ClamAV 1.4.3") }
            return self.success(self.catalog(installed: upgraded ? "1.5.0" : "1.4.3", outdated: !upgraded))
        }
        try await XCTUnwrap(model.checkEngineUpdate(app)).value
        model.watchActive = true
        XCTAssertFalse(model.canUpgradeEngine)
        XCTAssertNil(model.upgradeEngine(app))
        model.watchActive = false
        try await XCTUnwrap(model.upgradeEngine(app)).value
        XCTAssertEqual(model.installedEngine?.engine, "1.5.0")
        XCTAssertEqual(model.lastEngineSuccess, now)
        XCTAssertEqual(model.lastDatabaseSuccess, prior)
        XCTAssertFalse(commands.contains { $0.executable.hasSuffix("freshclam") })
        XCTAssertFalse(model.canUpgradeEngine)
    }

    func testExitZeroWithoutChangedEngineIsNotVerifiedSuccess() async throws {
        var upgraded = false
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, _, _ in
            if command.arguments == ClamAVFormulaInfo.upgradeArguments { upgraded = true; return self.success() }
            if command.arguments.contains("--version") { return self.success("ClamAV 1.4.3") }
            return self.success(self.catalog(installed: upgraded ? "1.5.0" : "1.4.3", outdated: !upgraded))
        }
        try await XCTUnwrap(model.checkEngineUpdate(app)).value
        try await XCTUnwrap(model.upgradeEngine(app)).value
        XCTAssertNil(model.lastEngineSuccess)
        XCTAssertNil(model.engineCatalog)
        XCTAssertNotNil(model.engineResult)
    }

    func testFreshclamFailurePreservesLastSuccessAndLogsPermissions() async throws {
        let prior = now.addingTimeInterval(-100_000)
        preferences.set(prior, forKey: "security.clamav.lastUpdate")
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, _, timeout in
            XCTAssertTrue(command.executable.hasSuffix("freshclam"))
            XCTAssertNil(timeout)
            return CommandResult(status: 1, stdout: "", stderr: "Permission denied")
        }
        try await XCTUnwrap(model.updateDatabase(app)).value
        XCTAssertEqual(model.lastDatabaseSuccess, prior)
        XCTAssertNil(model.lastEngineSuccess)
        XCTAssertNotNil(model.databaseResult)
        XCTAssertTrue(app.console.entries.last?.output.contains("Permission denied") == true)
    }

    func testFreshclamExitZeroRequiresDatabaseBeforeRecordingSuccess() async throws {
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { _, _, _ in self.success() }
        try await XCTUnwrap(model.updateDatabase(app)).value
        XCTAssertNil(model.lastDatabaseSuccess)
        XCTAssertFalse(model.databaseReady)
        XCTAssertNotNil(model.databaseResult)
    }

    func testSuccessfulFreshclamRecordsCheckWithoutPretendingOldDefinitionsAreFresh() async throws {
        let directory = root.appendingPathComponent("clamav/database")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("synthetic header".utf8).write(to: directory.appendingPathComponent("daily.cvd"))
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, _, _ in
            command.arguments.contains("--version") ? self.success("ClamAV 1.4.3/28000/Sat Oct 17 10:20:30 2026") : self.success("Database is up-to-date")
        }
        try await XCTUnwrap(model.updateDatabase(app)).value
        XCTAssertEqual(model.lastDatabaseSuccess, now)
        XCTAssertNil(model.lastEngineSuccess)
        XCTAssertEqual(ClamAVVersionInfo.freshness(hasDatabase: model.databaseReady, builtAt: model.installedEngine?.databaseDate, now: now), .old)
        XCTAssertEqual(app.console.entries.count, 2)
    }

    func testCancellationSettlesBusyStateAndDoesNotWriteSuccess() async throws {
        var started = false
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { _, _, _ in
            started = true
            try await Task.sleep(for: .seconds(30))
            return self.success()
        }
        let operation = try XCTUnwrap(model.updateDatabase(app))
        while !started { await Task.yield() }
        XCTAssertTrue(model.securityBusy)
        XCTAssertNil(model.checkEngineUpdate(app))
        model.cancelSetup()
        await operation.value
        XCTAssertFalse(model.securityBusy)
        XCTAssertFalse(model.updatingDatabase)
        XCTAssertNil(model.lastDatabaseSuccess)
        XCTAssertNotNil(model.databaseResult)
        XCTAssertNotNil(app.console.entries.last?.failure)
        XCTAssertNil(app.console.entries.last?.status)
    }
    func testCancelledRunnerReturningBuffersKeepsDiagnosticsWithoutSuccess() async throws {
        var started = false
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { _, _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) } catch {}
            return CommandResult(status: 143, stdout: "Download started", stderr: "Stopped before database replacement")
        }
        let operation = try XCTUnwrap(model.updateDatabase(app))
        while !started { await Task.yield() }
        model.cancelSetup()
        await operation.value
        XCTAssertNil(model.lastDatabaseSuccess)
        XCTAssertNil(app.console.entries.last?.status)
        XCTAssertNotNil(app.console.entries.last?.failure)
        XCTAssertTrue(app.console.entries.last?.output.contains("Download started") == true)
        XCTAssertTrue(app.console.entries.last?.output.contains("Stopped before database replacement") == true)
    }

    func testEngineMutationWaitsForStoppedDaemonAndInFlightScanSettlement() async throws {
        var mutations = 0
        let app = AppModel(visualSnapshot: true, home: root)
        let model = model { command, _, _ in
            if command.arguments.first == "upgrade" { mutations += 1 }
            return command.arguments.contains("--version") ? self.success("ClamAV 1.4.3") : self.success(self.catalog())
        }
        try await XCTUnwrap(model.checkEngineUpdate(app)).value
        XCTAssertTrue(model.canUpgradeEngine)
        var daemonRunning = true
        model.trackStoppingWatch { daemonRunning }
        var scanRelease: CheckedContinuation<Void, Never>?
        let scan = model.runWatchOperation {
            await withCheckedContinuation { scanRelease = $0 }
        }
        while scanRelease == nil { await Task.yield() }
        model.shutdown()
        XCTAssertTrue(model.watchStopping)
        XCTAssertFalse(model.canUpgradeEngine)
        XCTAssertNil(model.upgradeEngine(app))
        daemonRunning = false
        // A stopped daemon alone is not sufficient while its clamdscan client is settling.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.canUpgradeEngine)
        XCTAssertNil(model.install("clamav", app))
        scanRelease?.resume()
        await scan.value
        let deadline = Date().addingTimeInterval(2)
        while model.watchStopping && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.watchStopping)
        XCTAssertEqual(model.watchOperationCount, 0)
        XCTAssertTrue(model.canUpgradeEngine)
        XCTAssertEqual(mutations, 0)
    }

}
