import AppKit
import MoleKit
import SwiftUI
import XCTest
@testable import Nora

/// Native pixel artifacts, not golden-image approval. CI retains every PNG in xcresult.
/// No button is pressed. DEBUG fixtures disable appearance work, networking, and live polling.
/// Run under the unit-test host (NORA_UNIT_TESTING=1), never NoraAutoScan.
@MainActor
final class MenuVisualSmokeTests: XCTestCase {
    private let syntheticHome = URL(fileURLWithPath: "/Users/visual-fixture")
    private let isolatedAppHome = FileManager.default.temporaryDirectory.appendingPathComponent("nora-menu-visual-\(UUID().uuidString)")

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: isolatedAppHome)
    }
    private let failure = "Synthetic preview unavailable. Nothing was changed. Review the log and try again."

    func testEverySidebarModuleAtDefaultAndMinimumSize() throws {
        for module in Module.available {
            for size in [CGSize(width: 1240, height: 800), CGSize(width: 1040, height: 620)] {
                let app = fixture(module)
                try snapshot(app, name: "\(module.rawValue)-start-\(Int(size.width))x\(Int(size.height))-en", size: size)
            }
        }
    }

    func testAllAppsEntryAndQuitBeforeRemovalPrompt() throws {
        let app = fixture(.applications)
        try configure(app, module: .applications, state: "review")
        for locale in ["en", "uk", "ru"] {
            try snapshot(app, name: "applications-all-apps-entry-\(locale)", locale: locale,
                         size: CGSize(width: 1040, height: 620))
            try capture(AppsQuitRemovalPrompt(apps: app.apps.apps, cancel: {}, confirm: {})
                .environment(\.locale, Locale(identifier: locale)).preferredColorScheme(.dark).allowsHitTesting(false),
                name: "applications-quit-before-removal-\(locale)", size: CGSize(width: 480, height: 360))
            let multiple = try InstalledApp.decodeList(Data("""
                [{"name":"Example Editor","path":"/synthetic/Editor.app"},
                 {"name":"Example Browser","path":"/synthetic/Browser.app"},
                 {"name":"Example Player","path":"/synthetic/Player.app"},
                 {"name":"Example Notes","path":"/synthetic/Notes.app"},
                 {"name":"Example Mail","path":"/synthetic/Mail.app"}]
                """.utf8))
            try capture(AppsQuitRemovalPrompt(apps: multiple, cancel: {}, confirm: {})
                .environment(\.locale, Locale(identifier: locale)).preferredColorScheme(.dark).allowsHitTesting(false),
                name: "applications-quit-multiple-before-removal-\(locale)", size: CGSize(width: 480, height: 500))
        }
    }

    func testReviewEmptyAndErrorStates() throws {
        for module in Module.available {
            for state in ["review", "empty", "error"] {
                let app = fixture(module)
                try configure(app, module: module, state: state)
                try snapshot(app, name: "\(module.rawValue)-\(state)-en")
            }
        }
    }

    func testRepresentativeLocalizedAndInnerScreens() throws {
        for locale in ["uk", "ru"] {
            for module in [Module.cleanup, .applications, .security, .smartCare] {
                let app = fixture(module)
                try configure(app, module: module, state: "review")
                try snapshot(app, name: "\(module.rawValue)-review-\(locale)", locale: locale,
                             size: CGSize(width: 1040, height: 620))
            }
        }
        for screen in [AppsModel.Screen.list, .updates, .plans] {
            let app = fixture(.applications)
            try configure(app, module: .applications, state: "review")
            app.apps.screen = screen
            try snapshot(app, name: "applications-inner-\(screen)-en")
        }
        for tab in ProtectionModel.Tab.allCases {
            let app = fixture(.protection)
            try configure(app, module: .protection, state: "review")
            app.protection.tab = tab
            try snapshot(app, name: "protection-\(tab.rawValue)-en")
        }
        let security = fixture(.security)
        try configure(security, module: .security, state: "review")
        security.security.listMode = .findings
        try snapshot(security, name: "security-findings-en")
        security.security.listMode = .quarantine
        try snapshot(security, name: "security-quarantine-empty-en")
        let cleanup = fixture(.cleanup)
        try configure(cleanup, module: .cleanup, state: "review")
        cleanup.cleanup.showList = true
        try snapshot(cleanup, name: "cleanup-detailed-list-en")
        // Environment locale covers SwiftUI localized keys. String(localized:) in model code
        // follows the process language; these are layout probes, not complete translation tests.
        for locale in ["en", "uk", "ru"] {
            for tab in ["general", "mole", "security", "updates"] {
                let app = fixture(.tools)
                try capture(SettingsView(snapshotTab: tab).environment(app).environment(\.locale, Locale(identifier: locale))
                    .preferredColorScheme(.dark).allowsHitTesting(false),
                    name: "settings-\(tab)-\(locale)", size: CGSize(width: 640, height: 580))
                XCTAssertTrue(app.console.entries.isEmpty)
            }
        }
    }

    /// Presentation coverage only: assignments below are not an integration run or evidence
    /// that cancelling, retrying, recovery, or a destructive operation actually succeeds.
    func testOperationalStagePresentations() throws {
        let modules: [Module] = [.cleanup, .projects, .installers, .applications,
                                 .performance, .spaceMap, .security, .smartCare]
        for module in modules {
            for state in ["scanning", "running", "done", "done-partial-failure"] {
                let app = fixture(module)
                try configure(app, module: module, state: "review")
                setOperationalState(app, module: module, state: state)
                try snapshot(app, name: "\(module.rawValue)-\(state)-en")
            }
        }
    }

    func testCancellationRecoveryAndRetryPresentations() throws {
        let apps = fixture(.applications)
        apps.apps.stage = .running
        apps.apps.stopRequested = true
        try snapshot(apps, name: "applications-cancel-finishing-current-en")
        apps.apps.stopRequested = false
        apps.apps.reopening = true
        try snapshot(apps, name: "applications-reopening-after-update-en")

        let smart = fixture(.smartCare)
        smart.smartCare.phase = .running
        smart.smartCare.stopRequested = true
        try snapshot(smart, name: "smartCare-cancel-stopping-en")
        smart.smartCare.phase = .done
        smart.smartCare.doneLines = ["Synthetic fixture: stopped after the current task; other tasks were not started."]
        try snapshot(smart, name: "smartCare-cancel-stopped-en")

        let cleanup = fixture(.cleanup)
        cleanup.cleanup.stage = .done
        cleanup.cleanup.failed = true
        cleanup.cleanup.recoveryRequired = true
        cleanup.cleanup.resultHeadline = "Recovery required"
        cleanup.cleanup.resultLines = ["✕ Synthetic protection recovery is pending. No real journal exists."]
        try snapshot(cleanup, name: "cleanup-recovery-required-en")

        let projects = fixture(.projects)
        projects.projects.stage = .done
        projects.projects.failed = true
        projects.projects.recoveryRequired = true
        projects.projects.resultHeadline = "Recovery required"
        projects.projects.resultLines = cleanup.cleanup.resultLines
        try snapshot(projects, name: "projects-recovery-required-en")

        let retry = fixture(.cleanup)
        retry.cleanup.error = failure
        try snapshot(retry, name: "cleanup-retry-available-en")
        retry.cleanup.error = nil
        retry.cleanup.stage = .scanning
        try snapshot(retry, name: "cleanup-retry-scanning-en")
    }

    func testConsoleCurrentHistoryAndPausedPresentations() throws {
        let app = fixture(.cleanup)
        // ConsoleLog only stores strings. These commands are deliberately never executed.
        let first = app.console.begin(ShellCommand("/synthetic/never-executed", ["earlier-preview"]))
        app.console.append(first, ["Synthetic earlier preview output", "No files were touched."])
        app.console.finish(first, status: 0)
        let latest = app.console.begin(ShellCommand("/synthetic/never-executed", ["current-preview"]))
        app.console.append(latest, ["Synthetic current preview output", "Waiting for synthetic fixture input…"])
        let entryIDs = app.console.entries.map(\.id)
        for (name, history, following) in [("current", false, true), ("history", true, true), ("paused", false, false)] {
            try capture(ConsoleView(snapshotHistory: history, snapshotFollowTail: following)
                .environment(app).preferredColorScheme(.dark).allowsHitTesting(false),
                name: "console-\(name)-en", size: CGSize(width: 1040, height: 240))
            XCTAssertEqual(app.console.entries.map(\.id), entryIDs, "Rendering must not launch commands")
            XCTAssertNil(app.console.entries.last?.status, "Rendering must not complete a command")
        }
    }

    private func setOperationalState(_ app: AppModel, module: Module, state: String) {
        let failed = state == "done-partial-failure"
        let stage: FlowStage = state == "scanning" ? .scanning : state == "running" ? .running : .done
        let headline = failed ? "Synthetic task finished with problems" : "Synthetic task complete"
        let lines = failed ? ["✓ One synthetic step completed", "✕ One synthetic step could not finish. Review the log."]
                           : ["✓ Synthetic task completed. No product action was executed."]
        switch module {
        case .cleanup:
            app.cleanup.stage = stage; app.cleanup.failed = failed
            app.cleanup.resultHeadline = headline; app.cleanup.resultLines = lines
        case .projects:
            app.projects.stage = stage; app.projects.failed = failed
            app.projects.resultHeadline = headline; app.projects.resultLines = lines
        case .installers:
            app.installers.stage = stage; app.installers.failed = failed
            app.installers.resultHeadline = headline; app.installers.resultLines = lines
        case .applications:
            app.apps.stage = stage; app.apps.failed = failed
            app.apps.resultHeadline = headline; app.apps.resultLines = lines
        case .performance:
            app.performance.stage = stage; app.performance.failed = failed
            app.performance.resultHeadline = headline; app.performance.resultLines = lines
        case .spaceMap:
            // Space Map's running state shares the interactive lens with review.
            app.spaceMap.stage = stage
            app.spaceMap.trashed = ["Synthetic Example.dmg"]
            app.spaceMap.trashFailures = failed ? ["Synthetic Example.dmg: could not move to Trash"] : []
        case .security:
            // Security .done is its result screen, not DoneView.
            app.security.stage = stage
            app.security.progress = "Synthetic example item"
            app.security.clamavIncomplete = failed
            app.security.notice = failed ? failure : nil
        case .smartCare:
            app.smartCare.phase = state == "scanning" ? .scanning : state == "running" ? .running : .done
            app.smartCare.doneLines = lines
            app.smartCare.failedModules = failed ? [.cleanup] : []
            if stage == .scanning { app.cleanup.stage = .scanning }
            if stage == .running { app.cleanup.stage = .running }
        default:
            XCTFail("This module has no operational FlowStage: \(module.rawValue)")
        }
    }

    private func fixture(_ module: Module) -> AppModel {
        let app = AppModel(visualSnapshot: true, home: isolatedAppHome)
        XCTAssertTrue(app.isVisualSnapshot, "Snapshots require a DEBUG test host")
        XCTAssertFalse(app.autoScan)
        app.selection = module
        app.moleState = .missing // No executable exists in this fixture.
        app.spaceMap.root = syntheticHome
        app.history.loaded = true
        app.protection.loaded = true
        app.security.clamav = ClamAVTools(clamscan: nil, freshclam: nil, clamd: nil, clamdscan: nil)
        return app
    }

    private func configure(_ app: AppModel, module: Module, state: String) throws {
        let populated = state == "review"
        let error = state == "error"
        switch module {
        case .cleanup:
            app.cleanup.stage = error ? .start : .review
            app.cleanup.error = error ? failure : nil
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            app.cleanup.preview = CleanPreview.validated(
                stdout: populated ? "Dry run complete\nPotential space: 60MB | Items: 2\nDetailed file list: synthetic" : "Dry run complete\nNo significant reclaimable space detected, system already clean.",
                list: populated ? "=== User essentials ===\n/Users/visual-fixture/Library/Caches/Example Cache  # 52MB\n=== Browsers ===\n/Users/visual-fixture/Library/Caches/Example Browser  # 8MB" : nil,
                listModified: now, since: now)
            let preview = try XCTUnwrap(app.cleanup.preview, "Cleanup fixture must satisfy the production parser")
            XCTAssertEqual(preview.items.count, populated ? 2 : 0)
            app.cleanup.selected = Set(app.cleanup.preview?.items.map(\.path) ?? [])
        case .projects:
            app.projects.stage = error ? .start : .review
            app.projects.error = error ? failure : nil
            app.projects.preview = PurgePreview.parse(populated
                ? "[DRY RUN] ~/Projects/Example/node_modules, 240MB\nWould free approximately: 240MB | Items: 1\nDry run complete"
                : "No old project artifacts to clean", home: syntheticHome)
            app.projects.selected = Set(app.projects.preview?.items.map(\.path) ?? [])
        case .installers:
            app.installers.stage = error ? .start : .review
            app.installers.error = error ? failure : nil
            app.installers.files = populated ? [.init(name: "Example Installer With A Long Name.dmg", sizeText: "420MB", source: "~/Downloads")] : []
            app.installers.selected = Set(app.installers.files.map(\.id))
        case .performance:
            app.performance.stage = error ? .start : .review
            app.performance.error = error ? failure : nil
            app.performance.report = OptimizeReport.parse(populated
                ? "Performance diagnosis\nMemory pressure is normal\n➤ DNS Cache\nWould refresh DNS cache\n➤ Login Items\n◎ Review startup applications\n=====\nWould apply 1 optimizations\n2 unchanged | 1 skipped | 1 unavailable\n====="
                : "➤ DNS Cache\nAlready healthy\n=====\nWould apply 0 optimizations\n1 unchanged\n=====")
        case .applications:
            app.apps.stage = error ? .start : .review
            app.apps.error = error ? failure : nil
            app.apps.apps = try InstalledApp.decodeList(Data((populated ? #"[{"name":"Example Editor","path":"/Users/visual-fixture/Applications/Example Editor.app","bundle_id":"invalid.example.editor","size":"245MB","source":"download"}]"# : "[]").utf8))
            for item in app.apps.apps { app.apps.sizes[item.path] = 245_000_000 }
            app.apps.plans = app.apps.apps.map { AppsModel.Plan(app: $0, entries: [$0.path, "~/Library/Caches/invalid.example.editor"]) }
            app.apps.updatesNote = "Synthetic fixture: no update provider contacted."
        case .spaceMap:
            app.spaceMap.stage = error ? .start : .review
            app.spaceMap.error = error ? failure : nil
            app.spaceMap.path = [syntheticHome]
            app.spaceMap.cache[syntheticHome] = try JSONDecoder().decode(DiskAnalysis.self, from: Data((populated
                ? #"{"path":"/Users/visual-fixture","scan_status":"complete","total_size":900000000,"entries":[{"name":"Projects","path":"/Users/visual-fixture/Projects","size":600000000,"is_dir":true},{"name":"Downloads","path":"/Users/visual-fixture/Downloads","size":300000000,"is_dir":true}]}"#
                : #"{"path":"/Users/visual-fixture","scan_status":"complete","total_size":0,"entries":[]}"#).utf8))
        case .smartCare:
            for child in SmartCareModel.tiles { try configure(app, module: child, state: state) }
            app.smartCare.phase = .results
        case .security:
            app.security.stage = error ? .start : .review
            app.security.notice = error ? failure : nil
            app.security.scanFindings = populated ? [SecurityFinding(id: UUID(), source: .launchItem,
                title: "Example unsigned helper", path: "/Users/visual-fixture/Library/LaunchAgents/invalid.example.plist",
                reasons: ["Synthetic unsigned item for layout review; no system scan was performed."], launchLabel: nil, canQuarantine: true)] : []
        case .history:
            // A first-load failure has no prior successful data or dashboard to display.
            app.history.loaded = !error
            app.history.error = error ? failure : nil
            // Sessions use no real history and remain empty in the empty/error cases.
            if populated {
                app.history.sessions = try JSONDecoder().decode(MoleHistory.self, from: Data(#"{"sessions":[{"run_id":"synthetic-session","command":"clean","size":"60MB","items":2,"started_at":"2026-10-17 12:00:00","actions":{"removed":2,"trashed":0,"skipped":1,"failed":0,"rebuilt":0},"failed_tasks":0}]}"#.utf8)).sessions
            }
        case .protection:
            // A failed initial load leaves editing disabled and exposes the Retry action.
            app.protection.loaded = !error
            app.protection.message = error ? failure : nil
            app.protection.defaults = populated ? ["~/Library/Caches/Example Browser"] : []
            app.protection.custom = populated ? ["~/Projects/Example Keep"] : []
            app.protection.projectFolders = populated ? ["~/Projects/Example"] : []
            app.protection.tasks = populated ? [(name: "DNS cache", id: "dns")] : []
        case .tools:
            app.tools.touchIDEnabled = populated ? false : nil
            app.tools.touchIDError = error ? failure : nil
            app.tools.completionError = error ? failure : nil
            app.tools.latestMole = populated ? "1.0.0-fixture" : nil
        case .status:
            let sample = populated ? try StatusSnapshot.decode(Data(#"{"host":"Example Mac","health_score":92,"cpu":{"usage":24},"memory":{"used_percent":48},"hardware":{"model":"Example Mac","cpu_model":"Example processor","total_ram":"16 GB"},"disk_io":{"read_rate":4,"write_rate":2}}"#.utf8)) : nil
            app.status.seedVisualSnapshot(sample, error: error ? failure : nil)
        }
    }

    private func snapshot(_ app: AppModel, name: String, locale: String = "en",
                          size: CGSize = CGSize(width: 1240, height: 800)) throws {
        try capture(SnapshotScene(app: app, sceneSize: size)
            .environment(app).environment(\.locale, Locale(identifier: locale))
            .preferredColorScheme(.dark).allowsHitTesting(false),
            name: name, size: CGSize(width: size.width, height: size.height + 100))
        XCTAssertTrue(app.console.entries.isEmpty, "Rendering must not start product commands")
        XCTAssertFalse(app.status.isStreaming, "Rendering must not start status polling")
    }

    private func capture<V: View>(_ view: V, name: String, size: CGSize) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Off-screen hosting avoids desktop capture permissions and real app-window startup.
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 4_096, "Blank or failed render: \(name)")
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoraVisualSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

/// Uses the production scene/rail/orb views without MainView's global mouse monitors.
/// The extra 100 pt shows the portion of the orb that normally extends beyond the window.
@MainActor
private struct SnapshotScene: View {
    let app: AppModel
    let sceneSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            ZStack {
                SceneBackground(palette: app.selection.palette)
                HStack(spacing: 0) {
                    Rail(selection: .constant(app.selection))
                    ModuleDetail(module: app.selection)
                        .environment(\.scenePalette, app.selection.palette)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: sceneSize.width, height: sceneSize.height)
            if let action = app.orb.action {
                BottomOrb(action: action, palette: app.selection.palette)
                    .position(x: Rail.width + (sceneSize.width - Rail.width) / 2,
                              y: sceneSize.height - OrbController.lift)
            }
        }
    }
}
