import MoleKit
import Observation
import SwiftUI

/// Performance: `mo optimize --dry-run` → the task list with Mole's diagnosis → `mo optimize`
/// in a PTY after `sudo -A -v`, so Mole adopts the session and never prompts on its own.
@MainActor @Observable
final class PerformanceModel {
    var stage: FlowStage = .start
    var report: OptimizeReport?
    var error: String?
    var resultHeadline = ""
    var resultLines: [String] = []
    var failed = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// "Would apply 4 optimizations" → 4, as Mole counts them.
    var pendingCount: Int? {
        report?.summary.lazy.compactMap { line -> Int? in
            guard line.hasPrefix("Would apply ") else { return nil }
            return Int(line.dropFirst("Would apply ".count).prefix { $0.isNumber })
        }.first
    }

    func scan(_ app: AppModel) {
        error = nil
        stage = .scanning
        task = Task {
            do {
                let result = try await app.run(["optimize", "--dry-run"])
                let parsed = OptimizeReport.parse(result.stdout)
                guard !parsed.tasks.isEmpty else { throw NoraError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr) }
                report = parsed
                stage = .review
            } catch is CancellationError {
                stage = .start
            } catch {
                self.error = error.localizedDescription
                stage = .start
            }
        }
    }

    func run(_ app: AppModel) {
        stage = .running
        task = Task {
            do {
                let result = try await app.runPTY(["optimize"], sudo: true)
                let after = OptimizeReport.parse(result.text)
                failed = !result.succeeded
                resultLines = after.summary
                resultHeadline = failed ? String(localized: "Maintenance stopped") : String(localized: "Your Mac is refreshed")
            } catch {
                failed = true
                resultHeadline = error.localizedDescription
            }
            stage = .done
        }
    }

    func stop() { task?.cancel() }
    func reset() { stage = .start; report = nil }
}

struct PerformanceView: View {
    @Environment(AppModel.self) private var app
    private var model: PerformanceModel { app.performance }
    private let module = Module.performance

    var body: some View {
        switch model.stage {
        case .start:
            ModuleStart(module: module,
                        subtitle: "Refresh caches and services that slow your Mac down, and repair safe maintenance issues.",
                        features: [Feature(symbol: "magnifyingglass", text: "DNS, Spotlight and Finder caches"),
                                   Feature(symbol: "network", text: "Network stack and services"),
                                   Feature(symbol: "person.badge.key", text: "Login items and launch agents"),
                                   Feature(symbol: "stethoscope", text: "What slows your Mac right now")],
                        command: "mo optimize --dry-run",
                        action: { model.scan(app) }) {
                if let error = model.error { Notice(text: error, color: Palette.crit) }
            }
            .task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Checking your Mac…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []), onStop: { model.stop() })
        case .review:
            PerformanceReview(model: model)
        case .running:
            WorkingView(module: module, title: "Refreshing…", detail: WorkingView.currentItem(app.console.entries.last?.output ?? []))
        case .done:
            DoneView(module: module, headline: model.resultHeadline, lines: model.resultLines, failed: model.failed) { model.reset() }
        }
    }
}

private struct PerformanceReview: View {
    @Bindable var model: PerformanceModel
    @Environment(AppModel.self) private var app
    private let module = Module.performance

    var body: some View {
        let report = model.report
        ModuleScene(module: module, leading: .startOver { model.reset() }, orb: OrbAction(title: "Run", action: { model.run(app) })) {
            VStack(spacing: 18) {
                ResultHeadline(text: model.pendingCount.map { String(localized: "\($0) tasks are ready to run.") } ?? String(localized: "Maintenance is ready."))
                if let diagnosis = report?.diagnosis, !diagnosis.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("What slows your Mac", systemImage: "stethoscope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                        ForEach(Array(diagnosis.prefix(6).enumerated()), id: \.offset) { _, line in
                            Text(line.replacingOccurrences(of: "◎ ", with: "").replacingOccurrences(of: "⊙ ", with: ""))
                                .font(.system(size: 13)).foregroundStyle(line.hasPrefix("◎") ? Palette.warn : Palette.fg2)
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).glassPanel()
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(report?.tasks ?? []) { task in taskCard(task) }
                    }
                }
                .scrollIndicators(.never)
                ReviewFooter(command: "sudo -A -v && mo optimize",
                             note: String(localized: "Some tasks need administrator rights; macOS asks for your password once."))
            }
            .padding(.horizontal, 34).padding(.top, 10)
        }
    }

    private func taskCard(_ task: OptimizeReport.Task) -> some View {
        let badge: (String, Color)? = switch task.outcome {
        case .attention: (String(localized: "Needs attention"), Palette.warn)
        case .skipped: (String(localized: "Skipped"), Palette.muted)
        case .unavailable: (String(localized: "Not available"), Palette.muted)
        case .applied, .unchanged: nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(task.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let badge {
                    Text(badge.0).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(badge.1.opacity(0.2))).foregroundStyle(badge.1)
                }
            }
            ForEach(Array(task.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line.replacingOccurrences(of: "→ ", with: "").replacingOccurrences(of: "◎ ", with: "").replacingOccurrences(of: "- ", with: ""))
                    .font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(2)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading).glassPanel(radius: 16)
    }
}
