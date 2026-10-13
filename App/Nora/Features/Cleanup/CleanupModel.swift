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
    @ObservationIgnored private var task: Task<Void, Never>?

    var command: String { includeSystem ? "sudo -A -v && mo clean" : "mo clean" }
    var previewCommand: String { includeSystem ? "sudo -A -v && mo clean --dry-run" : "mo clean --dry-run" }

    var selectedSize: Int64 {
        preview?.items.reduce(0) { selected.contains($1.path) ? $0 + $1.size : $0 } ?? 0
    }

    var protectedCount: Int { (preview?.items.count ?? 0) - selected.count }

    func items(in section: String) -> [CleanPreview.Item] {
        preview?.items.filter { $0.section == section } ?? []
    }

    func scan(_ app: AppModel) {
        error = nil
        stage = .scanning
        task = Task {
            do {
                let output: String
                #if DEBUG
                if let fixture = UserDefaults.standard.string(forKey: "NoraCleanFixture") {
                    let list = (try? String(contentsOfFile: fixture + "/clean-list.txt", encoding: .utf8)) ?? ""
                    let out = (try? String(contentsOfFile: fixture + "/clean-dry.txt", encoding: .utf8)) ?? ""
                    let parsed = CleanPreview.parse(cleanList: list, stdout: out)
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
                let list = (try? String(contentsOf: listURL, encoding: .utf8)) ?? ""
                let parsed = CleanPreview.parse(cleanList: list, stdout: output)
                preview = parsed
                selected = Set(parsed.items.map(\.path))
                stage = .review
            } catch is CancellationError {
                stage = .start
            } catch {
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    func clean(_ app: AppModel) {
        guard let preview, let mole = app.mole else { return }
        let protected = preview.items.filter { !selected.contains($0.path) }.map(\.path)
        stage = .running
        task = Task {
            let runID = "clean-\(Int(Date().timeIntervalSince1970))"
            do {
                if !protected.isEmpty {
                    let defaults = try mole.installation.cleanWhitelistDefaults(home: app.home)
                    try app.overlay.apply(protecting: protected, defaults: defaults, runID: runID)
                }
                defer { try? app.overlay.recoverIfNeeded() }
                let text: String
                let ok: Bool
                if includeSystem {
                    let result = try await app.runPTY(["clean"], sudo: true)
                    text = result.text; ok = result.succeeded
                } else {
                    let result = try await app.run(["clean"])
                    text = result.stdout + "\n" + result.stderr; ok = result.succeeded
                }
                finish(text: text, ok: ok)
            } catch {
                try? app.overlay.recoverIfNeeded()
                failed = true
                resultHeadline = error.localizedDescription
                resultLines = []
                stage = .done
            }
        }
    }

    private func finish(text: String, ok: Bool) {
        let summary = MoleSummary.lines(text)
        failed = !ok
        // "Tracked cleanup: 2.48GB | Items cleaned: 967"
        if let line = summary.first(where: { $0.contains("Tracked cleanup:") || $0.contains("Space freed") }) {
            resultHeadline = line.components(separatedBy: "|").first?
                .replacingOccurrences(of: "Tracked cleanup:", with: "").trimmingCharacters(in: .whitespaces) ?? line
        } else {
            resultHeadline = ok ? Format.bytes(selectedSize) : String(localized: "Cleanup stopped")
        }
        resultLines = summary
        stage = .done
    }

    func stop() {
        task?.cancel()
    }

    func reset() {
        showList = false
        listSection = nil
        stage = .start
        preview = nil
        selected = []
    }

    func sectionSize(_ section: String) -> Int64 { items(in: section).reduce(0) { $0 + $1.size } }

    /// Sections, largest first, without empty ones.
    var rankedSections: [String] {
        (preview?.sections ?? []).filter { sectionSize($0) > 0 }.sorted { sectionSize($0) > sectionSize($1) }
    }

    /// One-click clean of one section: everything outside it is protected for this run.
    func clean(section: String, _ app: AppModel) {
        let inSection = Set(items(in: section).map(\.path))
        selected = selected.intersection(inSection).isEmpty ? inSection : selected.intersection(inSection)
        clean(app)
    }

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
