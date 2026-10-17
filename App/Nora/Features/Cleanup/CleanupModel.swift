import Foundation
import MoleKit
import Observation

/// Cleanup: `mo clean --dry-run` → review every path → `mo clean` with the unchecked paths
/// protected for this run through the whitelist overlay.
@MainActor @Observable
final class CleanupModel {
    var stage: FlowStage = .start
    var preview: CleanPreview?
    var selected: Set<String> = []
    var includeSystem = false
    /// The detailed list is open: `nil` section means every section.
    var showList = false
    var listSection: String?
    var error: String?
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    var recoveryRequired = false
    @ObservationIgnored private var generation = UUID()
    var canClean: Bool {
        stage == .review && preview?.isComplete == true && !selected.isEmpty
            && selected.isSubset(of: Set(preview?.items.map(\.path) ?? []))
    }
    @ObservationIgnored private var task: Task<Void, Never>?

    var command: String { includeSystem ? "sudo -A -v && mo clean" : "mo clean" }
    var previewCommand: String { includeSystem ? "sudo -A -v && mo clean --dry-run" : "mo clean --dry-run" }

    var selectedSize: Int64 {
        preview?.items.reduce(0) { selected.contains($1.path) ? $0 + $1.addedSize : $0 } ?? 0
    }

    var reviewNotes: [CleanPreview.Note] {
        (preview?.notes ?? []).enumerated().sorted { left, right in
            func priority(_ text: String) -> Int {
                text.localizedCaseInsensitiveContains("Full Disk Access")
                    || text.localizedCaseInsensitiveContains("permission") ? 0 : 1
            }
            let a = priority(left.element.text), b = priority(right.element.text)
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
    }

    var protectedCount: Int { (preview?.items.count ?? 0) - selected.count }

    func items(in section: String) -> [CleanPreview.Item] {
        preview?.items.filter { $0.section == section } ?? []
    }

    func scan(_ app: AppModel) {
        guard stage != .scanning, stage != .running, task == nil else { return }
        // Under another run's temporary whitelist the preview would miss what that run protects.
        guard !app.exclusiveRunActive else { error = AppModel.busyScanMessage; return }
        error = nil
        preview = nil
        selected = []
        showList = false
        listSection = nil
        generation = UUID()
        let request = generation
        let started = Date()
        stage = .scanning
        task = Task(.cleanup) {
            defer { task = nil }
            do {
                let output: String
                #if DEBUG
                if let fixture = UserDefaults.standard.string(forKey: "NoraCleanFixture") {
                    let list = (try? String(contentsOfFile: fixture + "/clean-list.txt", encoding: .utf8)) ?? ""
                    let out = (try? String(contentsOfFile: fixture + "/clean-dry.txt", encoding: .utf8)) ?? ""
                    guard let parsed = CleanPreview.validated(stdout: out, list: list, listModified: started, since: started) else {
                        throw NoraError.commandFailed(String(localized: "The cleanup preview is incomplete or unreadable. Scan again."))
                    }
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    preview = parsed
                    selected = Set(parsed.items.map(\.path))
                    stage = .review
                    return
                }
                #endif
                if includeSystem {
                    let result = try await app.runPTY(["clean", "--dry-run"], sudo: true)
                    guard result.succeeded else { throw NoraError.commandFailed(String(localized: "The password was not accepted, or Mole stopped. The console shows the output.")) }
                    output = result.text
                } else {
                    let result = try await app.run(["clean", "--dry-run"])
                    guard result.succeeded else { throw NoraError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr) }
                    output = result.stdout
                }
                let listURL = app.home.appendingPathComponent(".config/mole/clean-list.txt")
                let list = try? String(contentsOf: listURL, encoding: .utf8)
                let modified = (try? listURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let parsed = CleanPreview.validated(stdout: output, list: list, listModified: modified, since: started) else {
                    throw NoraError.commandFailed(String(localized: "The cleanup preview is incomplete, stale or unreadable. Scan again."))
                }
                try Task.checkCancellation()
                guard generation == request else { return }
                preview = parsed
                selected = Set(parsed.items.map(\.path))
                stage = .review
            } catch is CancellationError {
                guard generation == request else { return }
                stage = .start
            } catch {
                guard generation == request else { return }
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    func clean(_ app: AppModel) {
        guard canClean, task == nil, let preview, let mole = app.mole else { return }
        let runID = "clean-\(UUID().uuidString)"
        guard app.beginExclusiveRun(runID) else {
            if app.overlay.needsRecovery { recoveryRequired = true; return refuse(WhitelistOverlayError.pendingRecovery) }
            error = AppModel.busyScanMessage
            return
        }
        recoveryRequired = false
        let reviewed = protectedPaths
        let chosen = selected
        let previewed = Set(preview.items.map(\.path))
        let system = includeSystem
        let (overlay, installation, home) = (app.overlay, mole.installation, app.home)
        stage = .running
        task = Task(.cleanup) {
            // Only this run's overlay is ever undone here; another module's stays in place.
            defer {
                do { try app.overlay.recover(runID: runID) }
                catch {
                    recoveryRequired = true
                    failed = true
                    resultHeadline = String(localized: "Protection recovery required")
                    resultLines.append(Self.describe(error))
                    stage = .done
                }
                app.endExclusiveRun(runID)
                task = nil
            }
            do {
                // Always check again right before the run, with the same rights as the run, so junk
                // that appeared since the review is protected too instead of riding along unseen.
                let started = Date()
                let decide: @Sendable (String, Bool) throws -> Void = { output, ok in
                    let listURL = home.appendingPathComponent(".config/mole/clean-list.txt")
                    let modified = (try? listURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    guard ok, let fresh = Self.freshPaths(stdout: output, list: try? String(contentsOf: listURL, encoding: .utf8),
                                                         listModified: modified, since: started) else {
                        throw NoraError.commandFailed(String(localized: "Mole could not check the junk again before cleaning, so nothing was removed. Scan again."))
                    }
                    guard !chosen.isDisjoint(with: fresh) else {
                        throw NoraError.commandFailed(String(localized: "The selected items are no longer in the cleanup preview. Nothing was removed. Scan again."))
                    }
                    try AppModel.protect(Self.protected(reviewed: reviewed, fresh: fresh, chosen: chosen, previewed: previewed),
                                         overlay: overlay, installation: installation, home: home, runID: runID)
                }
                let text: String
                let ok: Bool
                if system {
                    let result = try await app.runGated(check: ["clean", "--dry-run"], run: ["clean"]) { output, status in
                        try decide(output, status == 0)
                    }
                    text = result.text; ok = result.succeeded
                } else {
                    let check = try await app.run(["clean", "--dry-run"])
                    try await Task.detached { try decide(check.stdout, check.succeeded) }.value
                    try Task.checkCancellation()
                    let result = try await app.run(["clean"])
                    text = result.stdout + "\n" + result.stderr; ok = result.succeeded
                }
                finish(text: text, ok: ok)
            } catch is CancellationError {
                failed = true
                resultHeadline = String(localized: "Cleanup stopped")
                resultLines = [String(localized: "What was removed before the stop stays removed. Scan again to see what is left.")]
                stage = .done
            } catch {
                failed = true
                resultHeadline = Self.describe(error)
                resultLines = []
                stage = .done
            }
        }
    }

    /// What the run must leave alone: every reviewed item the user unticked, plus anything the
    /// fresh check found that the review never showed.
    nonisolated static func protected(reviewed: [String], fresh: [String], chosen: Set<String>, previewed: Set<String>) -> [String] {
        reviewed + fresh.filter { !chosen.contains($0) && !previewed.contains($0) }
    }

    private func refuse(_ error: Error) {
        failed = true
        resultHeadline = Self.describe(error)
        resultLines = []
        stage = .done
    }

    static func describe(_ error: Error) -> String {
        if let overlayError = error as? WhitelistOverlayError {
            switch overlayError {
            case .pendingRecovery:
                return String(localized: "Protection recovery is required before another cleanup. Retry recovery and scan again.")
            case .io(let detail):
                return String(localized: "Protection recovery failed: \(detail)")
            case .conflictingChanges(let path):
                return String(localized: "The protection file at \(path) changed outside Nora. The edited file and recovery copy are preserved. Resolve the file conflict before retrying recovery.")
            }
        }
        return error.localizedDescription
    }

    func finish(text: String, ok: Bool) {
        let summary = MoleSummary.lines(text)
        let report = summary.first { $0.contains("Tracked cleanup:") || $0.contains("Space freed") }
        // A backend report is not a measured filesystem delta. Never substitute preview bytes.
        let confirmed = summary.contains("Cleanup complete") && report != nil
        failed = !ok || !confirmed
        resultHeadline = !ok ? String(localized: "Cleanup stopped")
            : !confirmed ? String(localized: "Cleanup result is unverified")
            : String(localized: "Cleanup command completed")
        resultLines = summary
        if !confirmed && ok {
            resultLines.append(String(localized: "Mole did not report a cleanup result. Scan again to see what is left."))
        } else if report != nil {
            resultLines.append(String(localized: "These are Mole's reported results, not a measurement of newly available disk space."))
        }
        stage = .done
    }

    func retryRecovery(_ app: AppModel) {
        guard stage != .running else { return }
        do {
            try app.recoverProtection()
            recoveryRequired = false
            reset()
        } catch {
            recoveryRequired = true
            failed = true
            resultHeadline = String(localized: "Protection recovery required")
            resultLines = [Self.describe(error)]
        }
    }

    func stop() {
        task?.cancel()
    }

    func reset() {
        // Do not orphan a destructive run or its protection restoration.
        guard stage != .running, !recoveryRequired else { return }
        task?.cancel()
        generation = UUID()
        // Keep the cancelled task until it exits, so a new scan cannot overlap it.
        error = nil
        resultHeadline = ""
        resultLines = []
        failed = false
        showList = false
        listSection = nil
        stage = .start
        preview = nil
        selected = []
    }

    func sectionSize(_ section: String) -> Int64 { items(in: section).reduce(0) { $0 + $1.addedSize } }

    /// The section's total, or "Size unknown" when Mole could not measure anything in it.
    func sizeText(_ section: String) -> String {
        let size = sectionSize(section)
        if size == 0, items(in: section).contains(where: { !$0.sizeKnown }) { return String(localized: "Size unknown") }
        return Format.bytes(size)
    }

    /// The ticked items of one section and their size.
    func selected(in section: String) -> (paths: Set<String>, size: Int64) {
        let picked = items(in: section).filter { selected.contains($0.path) }
        return (Set(picked.map(\.path)), picked.reduce(0) { $0 + $1.addedSize })
    }

    /// Every section with an item, largest first. One Mole could not measure still shows: its
    /// items are ticked, so hiding it would clean them unseen.
    var rankedSections: [String] {
        (preview?.sections ?? []).filter { !items(in: $0).isEmpty }.sorted { sectionSize($0) > sectionSize($1) }
    }

    /// Cleans only what is ticked in one section; everything outside it is protected for this run.
    /// A section with nothing ticked is never ticked back on the user's behalf: its list opens.
    func clean(section: String, _ app: AppModel) {
        guard stage == .review else { return }
        guard scope(to: section) else { return openList(section) }
        clean(app)
    }

    /// Narrows the selection to what is ticked in `section`; false when nothing there is ticked.
    func scope(to section: String) -> Bool {
        let picked = selected(in: section).paths
        guard !picked.isEmpty else { return false }
        selected = picked
        return true
    }

    /// The paths of a fresh `mo clean --dry-run`, or nil when it is not a complete, readable
    /// answer. Mole says "Dry run complete" only when it finished; it writes clean-list.txt and
    /// prints "Detailed file list:" only when it found something, so a list must then be fresh.
    nonisolated static func freshPaths(stdout: String, list: String?, listModified: Date?, since started: Date) -> [String]? {
        CleanPreview.validated(stdout: stdout, list: list, listModified: listModified, since: started)?.items.map(\.path)
    }

    /// Every previewed path that is not ticked: Mole must not touch these in this run.
    var protectedPaths: [String] { preview?.items.filter { !selected.contains($0.path) }.map(\.path) ?? [] }

    func openList(_ section: String?) {
        listSection = section
        showList = true
    }

    func setSection(_ section: String, on: Bool) {
        for item in items(in: section) {
            if on { selected.insert(item.path) } else { selected.remove(item.path) }
        }
    }
}
