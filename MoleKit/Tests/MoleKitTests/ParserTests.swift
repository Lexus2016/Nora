import XCTest
@testable import MoleKit

/// Parsers against synthetic output shaped like Mole 1.59.1 (no real paths or app lists).
final class ParserTests: XCTestCase {
    func testSizes() {
        XCTAssertEqual(MoleSize.parse("738.8MB"), 738_800_000)
        XCTAssertEqual(MoleSize.parse("2.48GB"), 2_480_000_000)
        XCTAssertEqual(MoleSize.parse("18KB"), 18_000)
        XCTAssertEqual(MoleSize.parse("0B"), 0)
        XCTAssertEqual(MoleSize.parse("74KB+"), 74_000)
        XCTAssertNil(MoleSize.parse("--"))
    }

    func testCleanPreview() {
        let list = """
        # Mole Cleanup Preview - 2026-01-01 10:00:00
        #   /Users/*/Library/Caches/com.example.app

        === User essentials ===
        /Users/u/Library/Caches/ExampleCache  # 52.6MB
        /Users/u/Library/Logs/Example Logs  # 0B

        === Browsers ===
        /Users/u/Library/Caches/Browser/GPUCache  # 6.4MB
        """
        let stdout = """
        \u{1B}[1m➤ User essentials\u{1B}[0m
          → User app cache · 22 items, 738.8MB dry
          ◎ Trash · skipped, grant Full Disk Access to your terminal
        ◎ System caches need sudo, run sudo -v && mo clean --dry-run for full preview
        ➤ Large files
          ⊙ Docker Desktop data · 175.49GB · ~/Library/Containers/com.docker.docker/Data
        Potential space: 2.48GB | Items: 967 | Categories: 6
        """
        let p = CleanPreview.parse(cleanList: list, stdout: stdout)
        XCTAssertEqual(p.items.count, 3)
        XCTAssertEqual(p.items[1].path, "/Users/u/Library/Logs/Example Logs")
        XCTAssertEqual(p.sections, ["User essentials", "Browsers"])
        XCTAssertEqual(p.items[0].size, 52_600_000)
        XCTAssertEqual(p.potentialSize, 2_480_000_000)
        XCTAssertTrue(p.needsSudoForSystem)
        XCTAssertEqual(p.notes.count, 3)
        XCTAssertEqual(p.notes.last?.section, "Large files")
    }

    func testPurgePreview() {
        let out = """
        → DRY RUN MODE, No project artifacts will be removed
        ◎ Skipped 1 project scan root because scanning did not complete:
        ✓ [DRY RUN] /Users/u/Code/app/node_modules, 132.5MB
        ✓ [DRY RUN] ~/Code/my, project/target, 4KB
        Dry run incomplete - no changes made
        Would free approximately: 3.27GB | Items: 315 | Free: 508.57GB
        """
        let p = PurgePreview.parse(out, home: URL(fileURLWithPath: "/Users/u"))
        XCTAssertEqual(p.items.map(\.path), ["/Users/u/Code/app/node_modules", "/Users/u/Code/my, project/target"])
        XCTAssertEqual(p.items[0].project, "/Users/u/Code/app")
        XCTAssertEqual(p.totalSize, 3_270_000_000)
        XCTAssertFalse(p.isComplete)
        XCTAssertEqual(p.warnings.count, 1)
    }

    func testOptimizeReport() {
        let out = """
        Optimize
        Performance diagnosis
          ◎ Likely bottleneck: WindowServer (~33.5% CPU sustained)

        ➤ DNS & Spotlight Check
          → DNS cache flushed
        ➤ Network Stack Refresh
          → Network stack already optimal
        ➤ Database Optimization
          ◎ Close these apps before database optimization: Mail Safari
        ➤ Periodic Maintenance
          → Periodic maintenance skipped (not available on this macOS version)
        ➤ Shared File Lists
          - Shared file lists not readable (check directory permissions and Full Disk Access)
        ➤ Disk Health
          → Disk verify skipped (set MOLE_ENABLE_DISK_VERIFY=1 to enable)
        ======================================================================
        Dry Run Complete, No Changes Made
        Would apply 4 optimizations
        12 unchanged | 2 skipped | 2 unavailable
        ======================================================================
        """
        let r = OptimizeReport.parse(out)
        XCTAssertEqual(r.tasks.map(\.outcome), [.applied, .unchanged, .attention, .unavailable, .unavailable, .skipped])
        XCTAssertEqual(r.diagnosis.count, 1)
        XCTAssertEqual(r.summary.last, "12 unchanged | 2 skipped | 2 unavailable")
    }

    func testInstalledAppsAndHistory() throws {
        let apps = try InstalledApp.decodeList(Data("""
        [{"name": "Example", "bundle_id": "com.example", "source": "App", "uninstall_name": "Example", "path": "/Applications/Example.app", "size": "--"},
         {"name": "Tool", "source": "Homebrew", "uninstall_name": "tool", "path": "/Applications/Tool.app", "size": "12.5MB"}]
        """.utf8))
        XCTAssertEqual(apps.count, 2)
        XCTAssertNil(apps[0].size)
        XCTAssertEqual(apps[1].size, 12_500_000)

        let history = try JSONDecoder().decode(MoleHistory.self, from: Data("""
        {"limit": 2, "sessions": [
          {"command": "clean", "run_id": "", "started_at": "2026-10-13 12:51:38", "items": 3, "size": "1.2GB",
           "operation_count": 89, "failed_tasks": 0, "actions": {"removed": 3, "trashed": 0, "skipped": 86, "failed": 0, "rebuilt": 0}},
          {"command": 42}
        ]}
        """.utf8))
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(history.sessions[0].size, 1_200_000_000)
        XCTAssertEqual(history.sessions[0].skipped, 86)
        XCTAssertNotNil(history.sessions[0].started)
        XCTAssertEqual(history.sessions[1].command, "?")
    }

    func testStatusSnapshotSurvivesMissingAndWrongFields() throws {
        let s = try StatusSnapshot.decode(Data("""
        {"health_score": 66.0, "cpu": {"usage": 12.5, "per_core": [10, "x", 30]},
         "gpu": [{"name": "GPU", "usage": -1}], "memory": {"used": 1, "total": "oops", "pressure": ""},
         "thermal": {"cpu_temp": 0, "system_power": 12.3}, "top_processes": [{"pid": 1, "cpu": 98}, 7]}
        """.utf8))
        XCTAssertEqual(s.healthScore, 66)
        XCTAssertEqual(s.cpu?.perCore, [10, 30])
        XCTAssertNil(s.gpu.first?.usage)
        XCTAssertNil(s.memory?.total)
        XCTAssertNil(s.memory?.pressure)
        XCTAssertNil(s.thermal?.cpuTemp)
        XCTAssertEqual(s.thermal?.systemPower, 12.3)
        XCTAssertEqual(s.topProcesses.count, 1)
        XCTAssertTrue(s.processAlerts.isEmpty)
    }

    func testDiskAnalysis() throws {
        let a = try JSONDecoder().decode(DiskAnalysis.self, from: Data("""
        {"scan_status": "partial", "path": "/Users/u", "entries": [{"name": "A", "path": "/Users/u/A", "size": 10, "is_dir": true, "scan_status": "partial"}],
         "large_files": [{"name": "f.mp4", "path": "/Users/u/A/f.mp4", "size": 5}], "total_size": 10, "total_files": 1}
        """.utf8))
        XCTAssertTrue(a.entries[0].isPartial)
        XCTAssertEqual(a.largeFiles.first?.size, 5)
    }
}

/// Runs the parsers over output captured from a real Mac. Skipped unless `NORA_CAPTURE_DIR`
/// points at a folder with clean-list.txt, clean-dry.txt, purge-dry.txt, optimize-dry.txt,
/// uninstall-list.json, history.json, status.json and analyze-downloads.json. Captures are
/// never committed.
final class RealCaptureTests: XCTestCase {
    func testCapturedOutputParses() throws {
        guard let dir = ProcessInfo.processInfo.environment["NORA_CAPTURE_DIR"] else { throw XCTSkip("NORA_CAPTURE_DIR not set") }
        func read(_ name: String) throws -> String { try String(contentsOfFile: dir + "/" + name, encoding: .utf8) }
        let clean = CleanPreview.parse(cleanList: try read("clean-list.txt"), stdout: try read("clean-dry.txt"))
        XCTAssertGreaterThan(clean.items.count, 0)
        XCTAssertNotNil(clean.potentialSize)
        let purge = PurgePreview.parse(try read("purge-dry.txt"), home: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertGreaterThan(purge.items.count, 0)
        let optimize = OptimizeReport.parse(try read("optimize-dry.txt"))
        XCTAssertGreaterThan(optimize.tasks.count, 10)
        XCTAssertFalse(optimize.summary.isEmpty)
        let apps = try InstalledApp.decodeList(Data(try read("uninstall-list.json").utf8))
        XCTAssertGreaterThan(apps.count, 0)
        let history = try JSONDecoder().decode(MoleHistory.self, from: Data(try read("history.json").utf8))
        XCTAssertGreaterThan(history.sessions.count, 0)
        let status = try StatusSnapshot.decode(Data(try read("status.json").utf8))
        XCTAssertNotNil(status.cpu?.usage)
        XCTAssertNotNil(status.memory?.total)
        let analysis = try JSONDecoder().decode(DiskAnalysis.self, from: Data(try read("analyze-downloads.json").utf8))
        XCTAssertGreaterThan(analysis.entries.count, 0)
        print("clean items \(clean.items.count) in \(clean.sections.count) sections, \(clean.notes.count) notes; purge \(purge.items.count); optimize \(optimize.tasks.map(\.outcome.rawValue)); apps \(apps.count); history \(history.sessions.count)")
    }
}
