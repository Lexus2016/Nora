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
    /// `partial`: yara failed on some folders; the matches it found elsewhere are listed.
    enum XProtectState: Equatable { case notRun, ran(matches: Int), partial(matches: Int, String) }

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
    /// clamscan exited with 2 or more (errors, unread files, killed): no match then proves nothing.
    var clamavIncomplete = false
    var quarantine: [QuarantineEntry] = []
    var watchActive = false
    /// clamd is loading its database (several seconds); Settings shows the switch as on meanwhile.
    private(set) var watchStarting = false
    /// Why the last attempt to turn the Downloads watch on failed, shown under the switch.
    private(set) var watchError: String?
    var clamav = ClamAVTools.locate()
    var databaseReady = false
    /// The formula `brew install` is working on, for the button's busy state.
    private(set) var installing: String?
    /// The ClamAV install fetches the virus database in the same click.
    private(set) var downloadingDatabase = false
    /// freshclam is running for a manual or scheduled update.
    private(set) var updatingDatabase = false
    /// Stop was pressed while moving to quarantine: the item in progress finishes, the rest stay.
    private(set) var stopRequested = false
    /// Programs of the current launch items, read when the screen opens, so the scan command
    /// preview lists the same paths a Quick scan will cover.
    private(set) var previewLaunchPaths: [String] = []

    @ObservationIgnored private let home: URL
    @ObservationIgnored private let layout: ClamAVLayout
    @ObservationIgnored private let store: QuarantineStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var watch: DownloadsWatch?
    @ObservationIgnored private var clamd: ClamdSession?
    /// When clamd last stopped under a running watch, for the restart limit.
    @ObservationIgnored private var watchRestarts: [Date] = []
    /// Downloads whose check failed, checked again when the watch restarts.
    @ObservationIgnored private var watchRetry: [URL] = []
    @ObservationIgnored private var watchStart: Task<Void, Never>?
    @ObservationIgnored private var watchGeneration: UUID?
    @ObservationIgnored private var scheduledRun = false
    /// When an update was last tried, whatever the outcome. A failing download is retried hourly
    /// and never holds back a due scan that the existing database can run.
    @ObservationIgnored private var lastUpdateAttempt: Date?

    private static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    /// Nora's quarantine and ClamAV folders, left out of every scan.
    @ObservationIgnored let ownFolders: [String]

    /// Cheap by design: no scans, processes or permission prompts happen here.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, support: URL? = nil) {
        let base = support ?? home.appendingPathComponent("Library/Application Support/Nora", isDirectory: true)
        self.ownFolders = [base.appendingPathComponent("Quarantine").path, base.appendingPathComponent("clamav").path]
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

    /// The ClamAV step of a scan as it can be pasted into Terminal: real paths, quoted.
    var scanCommand: String {
        let plan = ScanPlanner.plan(scope, home: home, launchPaths: previewLaunchPaths)
        let arguments = ClamScanParser.arguments(database: layout.database, roots: plan.roots)
        return ShellCommand(clamav.clamscan?.path ?? "clamscan", arguments).description
    }

    /// Quarantine itself is a file move inside Nora, not a shell command. The only command it runs
    /// is unloading a ticked launch agent, so that is what the footer shows.
    var quarantineCommand: String? {
        let labels = findings.filter { checked.contains($0.id) }.compactMap(\.launchLabel)
        guard !labels.isEmpty else { return nil }
        return labels.map { ShellCommand("/bin/launchctl", ["bootout", "gui/\(getuid())/\($0)"]).description }.joined(separator: "; ")
    }

    func reapOrphanedScanners() async {
        await ClamAVOrphans.reap(root: layout.root)
    }

    func loadPreviewLaunchPaths() async {
        previewLaunchPaths = await LaunchAudit.scan(LaunchAudit.defaultDirectories).items.compactMap(\.program)
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
        clamavIncomplete = false
        progress = String(localized: "Reading launch items")
        let scope = self.scope
        let home = self.home
        task = Task {
            defer { self.task = nil }
            do {
                let report = await LaunchAudit.scan(LaunchAudit.defaultDirectories)
                self.launchItems = report.items
                self.scanFindings = report.items.compactMap(Self.launchFinding)
                var plan = ScanPlanner.plan(scope, home: home, launchPaths: report.items.compactMap(\.program))
                // Nora's own quarantine and virus database are never scanned: a quarantined file
                // would come back as a new finding, and the database is full of signatures.
                plan.roots = ScanPlanner.excluding(self.ownFolders, from: plan.roots)
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
        // Each root's matches are kept as soon as yara reports them, so a later root that fails,
        // or a stop, never loses what was found. Any failure marks the run partial.
        var matches = 0
        var problem: String?
        defer { xprotect = problem.map { .partial(matches: matches, $0) } ?? .ran(matches: matches) }
        for root in roots {
            try Task.checkCancellation()
            progress = String(localized: "XProtect rules: \(Self.shortPath(root))")
            let result = try await runLogged(ShellCommand(yara.path, XProtect.arguments(rules: rules, root: root)), app, qos: .utility)
            let hits = YaraParser.parse(result.stdout).filter { !self.isOwn($0.path) }.map { match in
                SecurityFinding(id: UUID(), source: .xprotect,
                                title: URL(fileURLWithPath: match.path).lastPathComponent, path: match.path,
                                reasons: [String(localized: "Matched Apple XProtect rule \(match.rule).")],
                                launchLabel: nil, canQuarantine: true)
            }
            scanFindings += hits
            matches += hits.count
            if result.status != 0, problem == nil {
                problem = Self.lastLine(result.stderr, fallback: String(localized: "yara stopped."))
            }
        }
    }

    /// True for a path inside Nora's quarantine or virus database.
    private func isOwn(_ path: String) -> Bool {
        ownFolders.contains { path.hasPrefix($0 + "/") }
    }

    private func runClamAV(_ plan: ScanPlan, _ app: AppModel) async throws {
        guard let clamscan = clamav.clamscan, !plan.roots.isEmpty else { return }
        // A database older than a day, or none: update first. A failed update still scans with
        // the copy on this Mac and says how old it is; an old database beats no scan.
        if let freshclam = clamav.freshclam,
           !layout.hasDatabase || ScanSchedule.isUpdateDue(now: .now, last: SecuritySettings.lastDatabaseUpdate) {
            progress = String(localized: "Updating the virus database")
            if let failure = await refreshDatabase(freshclam, app) {
                let message = layout.hasDatabase
                    ? SecuritySettings.lastDatabaseUpdate.map { String(localized: "The virus database could not be updated, so this scan used the copy from \($0.formatted(date: .abbreviated, time: .omitted)).") }
                        ?? String(localized: "The virus database could not be updated, so this scan used the copy already on this Mac.")
                    : failure
                notice = notice.map { $0 + "\n" + message } ?? message
            }
            try Task.checkCancellation()
        }
        guard layout.hasDatabase else {
            let message = String(localized: "ClamAV's virus database is not downloaded yet, so the antivirus scan was skipped.")
            notice = notice.map { $0 + "\n" + message } ?? message
            return
        }
        progress = String(localized: "ClamAV antivirus scan")
        let arguments = ClamScanParser.arguments(database: layout.database, roots: plan.roots)
        let id = app.console.begin(ShellCommand(clamscan.path, arguments))
        // Unfinished until clamscan itself says otherwise: a cancel or a failed launch counts too.
        clamavIncomplete = true
        var lines: [String] = []
        var status: Int32 = 0
        do {
            for try await line in ProcessRunner.lines(clamscan, arguments, environment: BrewTools.environment, qos: .utility) {
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
        scanFindings += output.detections.filter { !isOwn($0.path) }.map(Self.detectionFinding)
        unreadableCount += output.errors
        // Exit 2 or more: errors or unread files. Zero findings then does not mean a clean scan.
        clamavIncomplete = status >= 2
        if status >= 2 {
            let message = String(localized: "ClamAV stopped with an error or could not read some files, so this scan may be incomplete. The console shows the details.")
            notice = notice.map { $0 + "\n" + message } ?? message
        }
    }

    private func runLogged(_ command: ShellCommand, _ app: AppModel, qos: QualityOfService = .default) async throws -> CommandResult {
        let id = app.console.begin(command)
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: command.executable), command.arguments,
                                                     environment: BrewTools.environment, qos: qos)
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
        stopRequested = false
        progress = String(localized: "Moving \(selected.count) items to quarantine")
        task = Task {
            defer { self.task = nil }
            var done = Set<UUID>()
            var problems: [String] = []
            for item in selected {
                if self.stopRequested {
                    problems.append(String(localized: "Stopped. The items that were not moved stay ticked."))
                    break
                }
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

    func stopAfterCurrent() { stopRequested = true }

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
        updatingDatabase = true
        task = Task {
            defer { self.task = nil; self.updatingDatabase = false }
            self.notice = await self.refreshDatabase(freshclam, app)
        }
    }

    /// Cancels `brew install` or a database download. Both resume cleanly on the next try.
    func cancelSetup() {
        guard installing != nil || updatingDatabase else { return }
        task?.cancel()
    }

    /// One freshclam run. Nil when the database is current afterwards, otherwise why not.
    /// Only a successful update counts; a failed one is retried at the next check.
    private func refreshDatabase(_ freshclam: URL, _ app: AppModel) async -> String? {
        // Timed from the end of the attempt, so a slow failing download cannot keep a due
        // scheduled scan waiting.
        defer { lastUpdateAttempt = Date() }
        do {
            try layout.writeConfigs()
            let result = try await runLogged(ShellCommand(freshclam.path, ["--config-file", layout.freshclamConfig.path]), app)
            if Task.isCancelled { return String(localized: "The database update was stopped.") }
            if result.succeeded { SecuritySettings.lastDatabaseUpdate = Date() }
            databaseReady = layout.hasDatabase
            return result.succeeded ? nil : Self.lastLine(result.stderr.isEmpty ? result.stdout : result.stderr,
                                                          fallback: String(localized: "The database update failed."))
        } catch {
            return Task.isCancelled ? String(localized: "The database update was stopped.") : error.localizedDescription
        }
    }

    /// Installs a Homebrew formula. Called only from a button the user clicks.
    func install(_ formula: String, _ app: AppModel) {
        guard task == nil else { return }
        guard let brew = BrewTools.brew else {
            notice = String(localized: "Homebrew was not found. Install Homebrew first.")
            return
        }
        installing = formula
        task = Task {
            defer { self.task = nil; self.installing = nil; self.downloadingDatabase = false }
            do {
                try await app.stream(ShellCommand(brew.path, ["install", formula]), environment: BrewTools.environment)
                self.notice = nil
                // ClamAV is no use without its database: fetch it in the same click.
                if formula == "clamav", let freshclam = ClamAVTools.locate().freshclam {
                    self.downloadingDatabase = true
                    self.notice = await self.refreshDatabase(freshclam, app)
                }
            } catch is CancellationError {
                self.notice = String(localized: "brew install \(formula) was stopped. Install again when you are ready.")
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
        // Kept fresh whenever ClamAV is installed, not only for the schedule or the watch.
        if ScanSchedule.isUpdateDue(now: now, last: SecuritySettings.lastDatabaseUpdate),
           lastUpdateAttempt.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true {
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
        watchError = nil
        guard on else {
            shutdown()
            return
        }
        guard watch == nil else { return }
        refreshTools()
        guard let clamd = clamav.clamd, let clamdscan = clamav.clamdscan, layout.hasDatabase else {
            SecuritySettings.watchEnabled = false
            watchError = String(localized: "The Downloads watch needs ClamAV and its virus database. Install ClamAV and update the database first.")
            notice = watchError
            return
        }
        let session = ClamdSession(clamd: clamd, clamdscan: clamdscan, layout: layout)
        let generation = UUID()
        let watch = DownloadsWatch(directory: home.appendingPathComponent("Downloads", isDirectory: true)) { [weak self, weak app] file in
            guard let self, let app else { return }
            self.inspectDownload(file, session: session, generation: generation, app)
        }
        // clamd gone while the watch is on: the switch must not keep saying it protects anything.
        session.onExit = { [weak self, weak app] in
            guard let self, let app, self.watchGeneration == generation, self.watchActive else { return }
            self.watchStopped(app)
        }
        self.clamd = session
        self.watch = watch
        SecurityNotifier.requestAuthorization()
        watchStarting = true
        watchGeneration = generation
        watchStart = Task {
            defer { if self.watchGeneration == generation { self.watchStarting = false } }
            do {
                try await session.start()
                try Task.checkCancellation()
                try watch.start()
                self.watchActive = true
                // Files a stopped clamd could not check get one more try with the new one.
                let retry = self.watchRetry
                self.watchRetry = []
                for file in retry where FileManager.default.fileExists(atPath: file.path) {
                    self.inspectDownload(file, session: session, generation: generation, app)
                }
            } catch is CancellationError {
                // Turned off or quitting while clamd was loading: not an error, and the setting
                // stays as the user left it so the watch resumes at the next launch.
                session.stop()
            } catch {
                guard self.watchGeneration == generation else { return }
                self.shutdown()
                self.watchError = error.localizedDescription
                self.notice = self.watchError
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
        // A start still loading the database belongs to no one now: its late errors are dropped.
        watchGeneration = nil
        watchStarting = false
        watchStart?.cancel()
        watchStart = nil
        watch?.stop()
        watch = nil
        clamd?.stop()
        clamd = nil
        watchActive = false
    }

    /// clamd stopped under a running watch. It restarts up to three times in ten minutes; after
    /// that the watch turns off and says why, instead of looking active with nothing behind it.
    private func watchStopped(_ app: AppModel) {
        let now = Date()
        watchRestarts = watchRestarts.filter { now.timeIntervalSince($0) < 600 } + [now]
        shutdown()
        if watchRestarts.count > 3 {
            SecuritySettings.watchEnabled = false
            watchError = String(localized: "ClamAV kept stopping, so the Downloads watch is off. Turn it on again to retry.")
            notice = watchError
            return
        }
        setWatch(true, app)
        watchError = String(localized: "ClamAV stopped. Nora restarted the Downloads watch.")
    }

    private func inspectDownload(_ file: URL, session: ClamdSession, generation: UUID, _ app: AppModel) {
        Task {
            let result = try? await self.runLogged(session.scanCommand(for: file), app)
            // A result for a watch that has since stopped or restarted changes nothing.
            guard self.watchGeneration == generation else { return }
            let output = ClamScanParser.parse((result?.stdout ?? "") + "\n" + (result?.stderr ?? ""))
            for detection in output.detections {
                self.watchFindings.append(Self.detectionFinding(detection))
                SecurityNotifier.post(title: String(localized: "Possible threat in Downloads"),
                                      body: String(localized: "\(file.lastPathComponent): \(detection.signature). Open Nora to review."))
            }
            // clamdscan: 0 clean, 1 found, 2 or more an error. An error is not a clean file.
            guard let result, result.status <= 1 else {
                let reason = result.map { Self.lastLine($0.stderr.isEmpty ? $0.stdout : $0.stderr, fallback: String(localized: "clamdscan stopped.")) }
                    ?? String(localized: "clamdscan could not start.")
                self.watchError = String(localized: "\(file.lastPathComponent) could not be checked: \(reason) It is checked again when it changes or when the watch restarts.")
                if !self.watchRetry.contains(file) { self.watchRetry.append(file) }
                return
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
        clamavIncomplete = false
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
