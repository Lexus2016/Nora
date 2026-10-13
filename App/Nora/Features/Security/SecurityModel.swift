import Foundation
import MoleKit
import Observation
import UserNotifications

/// A row in the findings list: a launch item or a file, with the reasons it needs a look.
struct SecurityFinding: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case launchItem, xprotect, clamav

        var label: String {
            switch self {
            case .launchItem: String(localized: "Launch item")
            case .xprotect: String(localized: "XProtect")
            case .clamav: String(localized: "ClamAV")
            }
        }
    }

    let id: UUID
    let source: Source
    let title: String
    /// What quarantine moves. For a launch item this is the plist, not the program it starts.
    let path: String
    let reasons: [String]
    /// Set for user launch agents: the label that is unloaded first when it is loaded.
    let launchLabel: String?
    /// False for system-owned files, which Nora never moves.
    let canQuarantine: Bool
}

enum SecurityError: LocalizedError {
    case notAllowed(String)
    case cannotWatch(String)
    case clamdDidNotStart
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let name): String(localized: "\(name) is owned by the system. Nora does not change it.")
        case .cannotWatch(let path): String(localized: "Nora cannot watch \(path).")
        case .clamdDidNotStart: String(localized: "ClamAV's daemon did not start. The console shows the details.")
        case .commandFailed(let text): text
        }
    }
}

/// Notifications for detections and finished scheduled scans. Detections are never acted on automatically.
enum SecurityNotifier {
    static func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Security: launch-item audit, Apple XProtect rules, ClamAV scan, quarantine, schedule and Downloads watch.
/// Nothing is moved, unloaded or deleted without the user's click.
@MainActor @Observable
final class SecurityModel {
    enum ListMode: Equatable { case findings, quarantine }
    enum XProtectState: Equatable { case notRun, ran(matches: Int), failed(String) }

    var stage: FlowStage = .start
    var scope: ScanScope = .quick
    var progress: String?
    var listMode: ListMode?
    /// Findings the user ticked. Starts empty and is cleared by every scan.
    var checked: Set<UUID> = []
    var notice: String?
    var launchItems: [LaunchItem] = []
    var scanFindings: [SecurityFinding] = []
    var watchFindings: [SecurityFinding] = []
    var xprotect: XProtectState = .notRun
    var skippedICloud = 0
    var unreadableCount = 0
    var quarantine: [QuarantineEntry] = []
    var watchActive = false
    var clamav = ClamAVTools.locate()
    var databaseReady = false

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let layout: ClamAVLayout
    @ObservationIgnored private let store: QuarantineStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watch: DownloadsWatch?
    @ObservationIgnored private var clamd: ClamdSession?
    @ObservationIgnored private var watchStart: Task<Void, Never>?
    @ObservationIgnored private var scheduledRun = false

    private static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]

    /// Cheap by design: no scans, processes or permission prompts happen here.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL? = nil) {
        let base = support ?? home.appendingPathComponent("Library/Application Support/Nora", isDirectory: true)
        let layout = ClamAVLayout(root: base.appendingPathComponent("clamav", isDirectory: true))
        self.home = home
        self.layout = layout
        self.store = QuarantineStore(root: base.appendingPathComponent("Quarantine", isDirectory: true))
        self.databaseReady = layout.hasDatabase
    }

    // MARK: - Derived state for the views

    var findings: [SecurityFinding] { scanFindings + watchFindings }
    var launchFlagged: Int { findings.filter { $0.source == .launchItem }.count }
    var clamavSignals: Int { findings.filter { $0.source == .clamav }.count }
    var yaraMissing: Bool { BrewTools.locate("yara") == nil }
    var rulesMissing: Bool { XProtect.rulesURL == nil }

    var scanCommand: String {
        "clamscan -r --infected --no-summary -d \(Self.shortPath(layout.database.path)) \(scope.commandPaths)"
    }

    var quarantineCommand: String {
        let picked = findings.filter { checked.contains($0.id) }
        guard !picked.isEmpty else { return String(localized: "Tick findings to quarantine them") }
        return picked.map { item -> String in
            let path = Self.shortPath(item.path)
            guard let label = item.launchLabel else { return "move \(path) to Quarantine" }
            return "launchctl bootout gui/\(getuid())/\(label) (if loaded); move \(path) to Quarantine"
        }
        .joined(separator: "; ")
    }

    var databaseStatus: String {
        if !clamav.isInstalled { return String(localized: "ClamAV is not installed.") }
        guard databaseReady else { return String(localized: "Not downloaded yet") }
        if let date = SecuritySettings.lastDatabaseUpdate {
            return String(localized: "Updated \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "Ready")
    }

    // MARK: - Scan

    /// Quick or Full: launch items, then Apple's XProtect rules, then one ClamAV run over the scope.
    func scan(_ app: AppModel) {
        guard task == nil else { return }
        stage = .scanning
        notice = nil
        checked = []
        scanFindings = []
        xprotect = .notRun
        unreadableCount = 0
        progress = String(localized: "Reading launch items")
        let scope = self.scope
        let home = self.home
        task = Task {
            defer { self.task = nil }
            do {
                let report = await LaunchAudit.scan(LaunchAudit.defaultDirectories)
                self.launchItems = report.items
                self.scanFindings = report.items.compactMap(Self.launchFinding)
                let plan = ScanPlanner.plan(scope, home: home, launchPaths: report.items.compactMap(\.program))
                self.skippedICloud = plan.skippedICloud
                try await self.runXProtect(plan.roots, app)
                try await self.runClamAV(plan, app)
            } catch is CancellationError {
                self.notice = String(localized: "Scan stopped. Results are partial.")
            } catch {
                self.notice = error.localizedDescription
            }
            self.progress = nil
            self.stage = .review
            if self.scheduledRun {
                self.scheduledRun = false
                if !self.findings.isEmpty {
                    SecurityNotifier.post(title: String(localized: "Security scan finished"),
                                          body: String(localized: "\(self.findings.count) signals to review in Nora."))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func runXProtect(_ roots: [String], _ app: AppModel) async throws {
        guard let yara = BrewTools.locate("yara"), let rules = XProtect.rulesURL else {
            xprotect = .notRun
            return
        }
        var hits: [SecurityFinding] = []
        for root in roots {
            try Task.checkCancellation()
            progress = String(localized: "XProtect rules: \(Self.shortPath(root))")
            let result = try await runLogged(ShellCommand(yara.path, XProtect.arguments(rules: rules, root: root)), app)
            if result.status != 0 && result.stdout.isEmpty {
                xprotect = .failed(Self.lastLine(result.stderr, fallback: String(localized: "yara stopped.")))
                return
            }
            hits += YaraParser.parse(result.stdout).map { match in
                SecurityFinding(id: UUID(), source: .xprotect,
                                title: URL(fileURLWithPath: match.path).lastPathComponent, path: match.path,
                                reasons: [String(localized: "Matched Apple XProtect rule \(match.rule).")],
                                launchLabel: nil, canQuarantine: true)
            }
        }
        scanFindings += hits
        xprotect = .ran(matches: hits.count)
    }

    private func runClamAV(_ plan: ScanPlan, _ app: AppModel) async throws {
        guard let clamscan = clamav.clamscan, !plan.roots.isEmpty else { return }
        guard layout.hasDatabase else {
            notice = String(localized: "ClamAV's virus database is not downloaded yet, so the antivirus scan was skipped.")
            return
        }
        progress = String(localized: "ClamAV antivirus scan")
        let arguments = ClamScanParser.arguments(database: layout.database, roots: plan.roots)
        let id = app.console.begin(ShellCommand(clamscan.path, arguments))
        var lines: [String] = []
        var status: Int32 = 0
        do {
            for try await line in ProcessRunner.lines(clamscan, arguments, environment: BrewTools.environment) {
                lines.append(line.text)
                app.console.append(id, [line.text])
            }
        } catch let failure as ProcessFailure {
            // clamscan exits 1 when it finds something and 2 when some files could not be read.
            status = failure.status
        } catch {
            app.console.fail(id, error: error)
            throw error
        }
        app.console.finish(id, status: status)
        try Task.checkCancellation()
        let output = ClamScanParser.parse(lines.joined(separator: "\n"))
        scanFindings += output.detections.map(Self.detectionFinding)
        unreadableCount += output.errors
    }

    private func runLogged(_ command: ShellCommand, _ app: AppModel) async throws -> CommandResult {
        let id = app.console.begin(command)
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: command.executable), command.arguments,
                                                     environment: BrewTools.environment)
            app.console.finish(id, result: result)
            return result
        } catch {
            app.console.fail(id, error: error)
            throw error
        }
    }

    private static func launchFinding(_ item: LaunchItem) -> SecurityFinding? {
        let reasons = LaunchAudit.reasons(for: item)
        guard !reasons.isEmpty else { return nil }
        let userOwned = item.scope == .userAgent
        return SecurityFinding(id: UUID(), source: .launchItem, title: item.label, path: item.plistPath,
                               reasons: reasons.map(\.text), launchLabel: userOwned ? item.label : nil,
                               canQuarantine: userOwned)
    }

    private static func detectionFinding(_ detection: ClamScanParser.Detection) -> SecurityFinding {
        SecurityFinding(id: UUID(), source: .clamav,
                        title: URL(fileURLWithPath: detection.path).lastPathComponent, path: detection.path,
                        reasons: [String(localized: "ClamAV matched the signature \(detection.signature).")],
                        launchLabel: nil, canQuarantine: true)
    }

    // MARK: - Quarantine

    /// Moves every ticked finding to quarantine. A loaded user launch agent is unloaded first.
    func quarantineChecked(_ app: AppModel) {
        let selected = findings.filter { checked.contains($0.id) }
        guard !selected.isEmpty, task == nil else { return }
        stage = .running
        progress = String(localized: "Moving \(selected.count) items to quarantine")
        task = Task {
            defer { self.task = nil }
            var done = Set<UUID>()
            var problems: [String] = []
            for item in selected {
                do {
                    try await self.quarantine(item, app)
                    done.insert(item.id)
                } catch {
                    problems.append("\(item.title): \(error.localizedDescription)")
                }
            }
            self.scanFindings.removeAll { done.contains($0.id) }
            self.watchFindings.removeAll { done.contains($0.id) }
            self.checked.subtract(done)
            self.quarantine = self.store.list()
            self.notice = problems.isEmpty ? nil : problems.joined(separator: "\n")
            self.progress = nil
            self.stage = .review
        }
    }

    private func quarantine(_ item: SecurityFinding, _ app: AppModel) async throws {
        let url = URL(fileURLWithPath: item.path)
        guard item.canQuarantine, await isMovable(url) else { throw SecurityError.notAllowed(item.title) }
        if let label = item.launchLabel, await isLoaded(label) {
            let result = try await runLogged(ShellCommand("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"]), app)
            guard result.succeeded else {
                throw SecurityError.commandFailed(String(localized: "launchctl could not unload \(label). The file was not moved."))
            }
        }
        try store.move(url, detection: item.reasons.joined(separator: " "))
    }

    private func isMovable(_ url: URL) async -> Bool {
        let path = url.path
        guard !Self.systemPrefixes.contains(where: { path.hasPrefix($0) }),
              FileManager.default.isDeletableFile(atPath: path) else { return false }
        return await Task.detached { !CodeSigning.isApple(at: url) }.value
    }

    private func isLoaded(_ label: String) async -> Bool {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/launchctl"), ["list"],
                                                        environment: BrewTools.environment) else { return false }
        return result.stdout.split(separator: "\n").contains { line in
            line.split(whereSeparator: \.isWhitespace).last == Substring(label)
        }
    }

    func restore(_ entry: QuarantineEntry) {
        do { try store.restore(entry) } catch { notice = error.localizedDescription }
        quarantine = store.list()
    }

    /// Permanent deletion. The view shows a confirmation dialog before calling this.
    func deletePermanently(_ entry: QuarantineEntry) {
        do { try store.delete(entry) } catch { notice = error.localizedDescription }
        quarantine = store.list()
    }

    // MARK: - ClamAV database and tools

    /// Runs freshclam with Nora's config. Manual and scheduled updates both call this.
    func updateDatabase(_ app: AppModel) {
        guard task == nil, let freshclam = clamav.freshclam else { return }
        task = Task {
            defer { self.task = nil }
            do {
                try self.layout.writeConfigs()
                SecuritySettings.lastDatabaseUpdate = Date()
                let result = try await self.runLogged(
                    ShellCommand(freshclam.path, ["--config-file", self.layout.freshclamConfig.path]), app)
                self.databaseReady = self.layout.hasDatabase
                self.notice = result.succeeded ? nil : Self.lastLine(result.stderr.isEmpty ? result.stdout : result.stderr,
                                                                     fallback: String(localized: "The database update failed."))
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    /// Installs a Homebrew formula. Called only from a button the user clicks.
    func install(_ formula: String, _ app: AppModel) {
        guard task == nil, let brew = BrewTools.brew else { return }
        task = Task {
            defer { self.task = nil }
            do {
                try await app.stream(ShellCommand(brew.path, ["install", formula]), environment: BrewTools.environment)
                self.notice = nil
            } catch {
                self.notice = String(localized: "brew install \(formula) did not finish. The console shows the output.")
            }
            self.refreshTools()
        }
    }

    func refreshTools() {
        clamav = ClamAVTools.locate()
        databaseReady = layout.hasDatabase
        quarantine = store.list()
    }

    // MARK: - Schedule and Downloads watch

    /// Entry point for the app's timer (every 15 minutes is enough). Runs at most one job per call:
    /// the daily database update when the schedule or the watch needs it, then a due scheduled scan.
    func tick(_ app: AppModel, now: Date = .now) {
        guard task == nil, stage == .start || stage == .review, checked.isEmpty, clamav.isInstalled else { return }
        let needsDatabase = SecuritySettings.scheduleEnabled || SecuritySettings.watchEnabled
        if needsDatabase, ScanSchedule.isUpdateDue(now: now, last: SecuritySettings.lastDatabaseUpdate) {
            updateDatabase(app)
            return
        }
        guard SecuritySettings.scheduleEnabled,
              ScanSchedule.isDue(now: now, last: SecuritySettings.lastScheduledScan, cadence: SecuritySettings.cadence) else { return }
        SecuritySettings.lastScheduledScan = now
        scope = SecuritySettings.scope
        scheduledRun = true
        scan(app)
    }

    /// Turns the Downloads watch on or off. On starts clamd as a child process and the FSEvents-style directory watch.
    func setWatch(_ on: Bool, _ app: AppModel) {
        SecuritySettings.watchEnabled = on
        guard on else {
            shutdown()
            return
        }
        guard watch == nil else { return }
        guard let clamd = clamav.clamd, let clamdscan = clamav.clamdscan, layout.hasDatabase else {
            SecuritySettings.watchEnabled = false
            notice = String(localized: "The Downloads watch needs ClamAV and its virus database. Install ClamAV and update the database first.")
            return
        }
        let session = ClamdSession(clamd: clamd, clamdscan: clamdscan, layout: layout)
        let watch = DownloadsWatch(directory: home.appendingPathComponent("Downloads", isDirectory: true)) { [weak self, weak app] file in
            guard let self, let app else { return }
            self.inspectDownload(file, session: session, app)
        }
        self.clamd = session
        self.watch = watch
        SecurityNotifier.requestAuthorization()
        watchStart = Task {
            do {
                try await session.start()
                try watch.start()
                self.watchActive = true
            } catch {
                self.shutdown()
                self.notice = error.localizedDescription
                SecuritySettings.watchEnabled = false
            }
        }
    }

    /// Called at launch. Starts the watch again only when the user had it on.
    func resumeWatchIfEnabled(_ app: AppModel) {
        if SecuritySettings.watchEnabled { setWatch(true, app) }
    }

    /// Stops the watch and clamd without changing the setting. Call on quit.
    func shutdown() {
        watchStart?.cancel()
        watchStart = nil
        watch?.stop()
        watch = nil
        clamd?.stop()
        clamd = nil
        watchActive = false
    }

    private func inspectDownload(_ file: URL, session: ClamdSession, _ app: AppModel) {
        Task {
            do {
                let result = try await self.runLogged(session.scanCommand(for: file), app)
                let output = ClamScanParser.parse(result.stdout + "\n" + result.stderr)
                for detection in output.detections {
                    self.watchFindings.append(Self.detectionFinding(detection))
                    SecurityNotifier.post(title: String(localized: "Possible threat in Downloads"),
                                          body: String(localized: "\(file.lastPathComponent): \(detection.signature). Open Nora to review."))
                }
            } catch {
                self.notice = error.localizedDescription
            }
        }
    }

    // MARK: - Navigation

    func openList(_ mode: ListMode) {
        listMode = mode
    }

    func reset() {
        stage = .start
        listMode = nil
        checked = []
        notice = nil
        scanFindings = []
        xprotect = .notRun
        skippedICloud = 0
        unreadableCount = 0
    }

    // MARK: - Helpers

    static func shortPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func lastLine(_ text: String, fallback: String = "") -> String {
        let line = text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? fallback : line
    }
}
