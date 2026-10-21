import Darwin
import Foundation
import XCTest
@testable import Nora

/// Real child processes, with a shell script standing in for clamd. It records each start, writes its
/// pid, creates the socket file the way clamd does once its database is loaded, and then sleeps.
/// ClamAV itself is never used, and nothing here touches the user's Downloads or notifications.
@MainActor
final class ClamdIdleUnloadTests: XCTestCase {
    @MainActor private final class Counter { var value = 0 }

    private var dir: URL!
    private var layout: ClamAVLayout!
    private var starts: URL { dir.appendingPathComponent("starts.log") }
    private var scans: URL { dir.appendingPathComponent("scans.log") }
    private var pidFile: URL { dir.appendingPathComponent("clamd.pid") }
    /// Every pid the stub ever had, to count how many clamd processes are alive at once.
    private var pids: URL { dir.appendingPathComponent("pids.log") }

    private func livePids() -> [pid_t] {
        let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { pid_t($0) }.filter { kill($0, 0) == 0 }
    }

    override func setUp() async throws {
        let parent = URL(fileURLWithPath: String(cString: realpath(FileManager.default.temporaryDirectory.path, nil)))
        dir = parent.appendingPathComponent("clamd-stub-\(UUID().uuidString)", isDirectory: true)
        layout = ClamAVLayout(root: dir.appendingPathComponent("Nora/clamav", isDirectory: true))
        try FileManager.default.createDirectory(at: layout.database, withIntermediateDirectories: true)
        try Data().write(to: layout.database.appendingPathComponent("main.cvd"))
    }

    override func tearDown() async throws {
        for pid in livePids() { kill(pid, SIGKILL) }
        if let pid = currentPid() { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func clamdStub() throws -> URL {
        try script("clamd", """
        echo started >> "\(starts.path)"
        echo $$ >> "\(pids.path)"
        echo $$ > "\(pidFile.path)"
        : > "\(layout.socket.path)"
        exec sleep 600
        """)
    }

    /// Loads once like clamd does, then dies on every later start before its socket appears: a clamd that
    /// cannot come back after it was unloaded.
    private func clamdThatCannotReload() throws -> URL {
        try script("clamd", """
        seen=0
        [ -f "\(starts.path)" ] && seen=$(wc -l < "\(starts.path)" | tr -d ' ')
        echo started >> "\(starts.path)"
        [ "$seen" -ge 1 ] && exit 1
        echo $$ >> "\(pids.path)"
        echo $$ > "\(pidFile.path)"
        : > "\(layout.socket.path)"
        exec sleep 600
        """)
    }

    private func scanStub() throws -> URL {
        try script("clamdscan", "echo scan >> \"\(scans.path)\"\nexit 0")
    }

    private func lines(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func currentPid() -> pid_t? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func wait(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func makeSession() throws -> ClamdSession {
        ClamdSession(clamd: try clamdStub(), clamdscan: try scanStub(), layout: layout)
    }

    // MARK: - ClamdSession

    func testUnloadForIdleIsNotACrashAndTheSessionLoadsAgain() async throws {
        let session = try makeSession()
        let crashes = Counter()
        session.onExit = { crashes.value += 1 }
        try await session.ensureRunning()
        let first = try XCTUnwrap(currentPid())
        XCTAssertTrue(session.isRunning)

        session.unloadForIdle()
        try await wait { !self.isAlive(first) }
        XCTAssertFalse(isAlive(first), "Unloading gives the memory back")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(crashes.value, 0, "A stop on purpose must not be reported as clamd crashing: the watch would restart it at once")

        try await session.ensureRunning()
        XCTAssertEqual(lines(starts), 2)
        XCTAssertTrue(session.isRunning)
        let second = try XCTUnwrap(currentPid())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(isAlive(second))
        session.stop()
        try await wait { !self.isAlive(second) }
    }

    func testLoadingRightAfterAnUnloadIgnoresTheOldProcessExit() async throws {
        let session = try makeSession()
        let crashes = Counter()
        session.onExit = { crashes.value += 1 }
        try await session.ensureRunning()
        let first = try XCTUnwrap(currentPid())
        session.unloadForIdle()
        // No pause: the old process is still exiting when the next download wants clamd.
        try await session.ensureRunning()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(crashes.value, 0, "The late exit of the unloaded process is not the new clamd's exit")
        XCTAssertFalse(isAlive(first))
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(lines(starts), 2)
        session.stop()
    }

    func testRealCrashIsStillReported() async throws {
        let session = try makeSession()
        let crashes = Counter()
        session.onExit = { crashes.value += 1 }
        try await session.ensureRunning()
        let pid = try XCTUnwrap(currentPid())
        kill(pid, SIGKILL)
        try await wait { crashes.value > 0 }
        XCTAssertEqual(crashes.value, 1)
        session.stop()
    }

    func testConcurrentDownloadsShareOneStart() async throws {
        let session = try makeSession()
        async let first: Void = session.ensureRunning()
        async let second: Void = session.ensureRunning()
        async let third: Void = session.ensureRunning()
        _ = try await (first, second, third)
        XCTAssertEqual(lines(starts), 1, "Three checks at once load one clamd, not three copies of the database")
        session.stop()
        try await wait { self.currentPid().map { !self.isAlive($0) } ?? true }
    }

    func testChecksArrivingWhileTheUnloadedProcessIsStillExitingShareOneReplacement() async throws {
        let session = try makeSession()
        try await session.ensureRunning()
        session.unloadForIdle()
        // Three downloads land while the old clamd is still going away: waiting for it and starting the
        // replacement are one shared step, or each caller starts its own copy of the database.
        async let first: Void = session.ensureRunning()
        async let second: Void = session.ensureRunning()
        async let third: Void = session.ensureRunning()
        _ = try await (first, second, third)
        XCTAssertEqual(lines(starts), 2, "One start for the first load, one shared replacement")
        try await wait { self.livePids().count == 1 }
        XCTAssertEqual(livePids().count, 1, "Exactly one clamd is alive, none left outside the session's control")
        session.stop()
        try await wait { self.livePids().isEmpty }
        XCTAssertTrue(livePids().isEmpty)
    }

    func testClamdDyingWhileLoadingIsReportedAsACrashNotSwallowedByTheFailedStart() async throws {
        let dead = try script("clamd", "echo started >> \"\(starts.path)\"\nexit 1")
        let session = ClamdSession(clamd: dead, clamdscan: try scanStub(), layout: layout)
        let crashes = Counter()
        session.onExit = { crashes.value += 1 }
        do { try await session.ensureRunning(); XCTFail("clamd that dies while loading must fail the start") } catch {}
        try await wait { crashes.value > 0 }
        XCTAssertEqual(crashes.value, 1, "The failed start must not mark the exit as expected: the watch has to learn clamd died")
    }

    func testStopDuringALoadLeavesNoProcessAndNothingStartsAfterwards() async throws {
        let session = try makeSession()
        let loading = Task { try await session.ensureRunning() }
        await Task.yield()
        session.stop()
        _ = try? await loading.value
        if let pid = currentPid() { try await wait { !self.isAlive(pid) } ; XCTAssertFalse(isAlive(pid), "A stopped session leaves no orphan clamd") }
        let started = lines(starts)
        do { try await session.ensureRunning(); XCTFail("A stopped session must not start again") } catch {}
        XCTAssertEqual(lines(starts), started)
        XCTAssertFalse(session.isRunning)
    }

    // MARK: - SecurityModel

    func testDownloadIsKeptForRetryWhenClamdCannotReloadAfterIdle() async throws {
        let downloads = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var services = ClamAVManagementServices()
        let tools = ClamAVTools(clamscan: try scanStub(), freshclam: try scanStub(), clamd: try clamdThatCannotReload(), clamdscan: try scanStub())
        services.locate = { tools }
        services.brew = { nil }
        services.isHomebrewManaged = { _, _ in false }
        services.requestNotifications = {}
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "clamd-reload-\(UUID().uuidString)"))
        let app = AppModel(visualSnapshot: true, home: dir)
        let model = SecurityModel(home: dir, support: dir.appendingPathComponent("Nora", isDirectory: true),
                                  clamavServices: services, preferences: defaults)
        model.watchIdleDelay = .milliseconds(400)
        let preference = UserDefaults.standard.object(forKey: SecuritySettings.watchKey)
        defer {
            model.shutdown()
            if let preference { UserDefaults.standard.set(preference, forKey: SecuritySettings.watchKey) }
            else { UserDefaults.standard.removeObject(forKey: SecuritySettings.watchKey) }
        }

        model.setWatch(true, app)
        try await wait { model.watchActive }
        XCTAssertTrue(model.watchActive, model.watchError ?? "the watch did not start")
        let first = try XCTUnwrap(currentPid())
        try await wait { !self.isAlive(first) }

        // A download lands while clamd is unloaded, and clamd then dies on every start before its socket appears.
        try Data("fresh download".utf8).write(to: downloads.appendingPathComponent("tool.zip"))
        try await wait(timeout: 60) { !model.watchActive && model.watchError != nil }
        XCTAssertEqual(lines(scans), 0, "No scan can have run: clamd never came back")
        XCTAssertTrue(model.watchRetry.map(\.lastPathComponent).contains("tool.zip"),
                      "The download that triggered the failed reload must stay queued for the next watch, not vanish")
    }

    func testWatchUnloadsClamdWhenQuietAndLoadsItForTheNextDownload() async throws {
        let downloads = dir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var services = ClamAVManagementServices()
        let tools = ClamAVTools(clamscan: try scanStub(), freshclam: try scanStub(), clamd: try clamdStub(), clamdscan: try scanStub())
        services.locate = { tools }
        services.brew = { nil }
        services.isHomebrewManaged = { _, _ in false }
        services.requestNotifications = {}
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "clamd-idle-\(UUID().uuidString)"))
        let app = AppModel(visualSnapshot: true, home: dir)
        let model = SecurityModel(home: dir, support: dir.appendingPathComponent("Nora", isDirectory: true),
                                  clamavServices: services, preferences: defaults)
        model.watchIdleDelay = .milliseconds(500)
        // setWatch writes the real Downloads-watch preference (UserDefaults.standard, the installed Nora's domain).
        let preference = UserDefaults.standard.object(forKey: SecuritySettings.watchKey)
        defer {
            model.shutdown()
            if let preference { UserDefaults.standard.set(preference, forKey: SecuritySettings.watchKey) }
            else { UserDefaults.standard.removeObject(forKey: SecuritySettings.watchKey) }
        }

        model.setWatch(true, app)
        try await wait { model.watchActive }
        XCTAssertTrue(model.watchActive, model.watchError ?? "the watch did not start")
        XCTAssertEqual(lines(starts), 1)
        let first = try XCTUnwrap(currentPid())

        try await wait { !self.isAlive(first) }
        XCTAssertFalse(isAlive(first), "A quiet watch stops clamd to free its database")
        XCTAssertTrue(model.watchActive, "The watch itself stays on")
        XCTAssertFalse(model.watchStopping)
        XCTAssertFalse(model.watchStarting)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(lines(starts), 1, "An idle stop must not be answered by the crash restart")

        try Data("fresh download".utf8).write(to: downloads.appendingPathComponent("tool.zip"))
        try await wait(timeout: 30) { self.lines(self.scans) >= 1 }
        XCTAssertEqual(lines(scans), 1, model.watchError ?? "the download was not checked")
        XCTAssertEqual(lines(starts), 2, "The download loaded clamd again")

        let second = try XCTUnwrap(currentPid())
        try await wait { !self.isAlive(second) }
        XCTAssertFalse(isAlive(second), "After the check clamd idles out again")
        XCTAssertTrue(model.watchActive)
    }
}
