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

    /// Nora's own one-line summary of the dry run instead of Mole's CLI wording
    /// ("Run without --dry-run to apply these changes" means nothing in a window).
    var headerSummary: String? {
        guard report != nil else { return nil }
        var parts: [String] = []
        if let n = pendingCount { parts.append(String(localized: "To apply: \(n)")) }
        if let n = summaryCount("unchanged") { parts.append(String(localized: "Already fine: \(n)")) }
        if let n = summaryCount("skipped"), n > 0 { parts.append(String(localized: "Skipped: \(n)")) }
        if let n = summaryCount("unavailable"), n > 0 { parts.append(String(localized: "Unavailable: \(n)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "13 unchanged | 2 skipped | 2 unavailable" → the number before `word`.
    func summaryCount(_ word: String) -> Int? {
        for line in report?.summary ?? [] {
            if let range = line.range(of: "\\d+ \(word)", options: .regularExpression) {
                return Int(line[range].prefix { $0.isNumber })
            }
        }
        return nil
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
    @State private var showAll = false
    private let module = Module.performance

    var body: some View {
        if showAll { list } else { results }
    }

    private var results: some View {
        let report = model.report
        let attention = (report?.tasks ?? []).filter { $0.outcome == .attention }
        let loginItems = report?.tasks.first { $0.title == "Login Items" }
        return ModuleScene(module: module, leading: .startOver { model.reset() }, orb: OrbAction(title: "Run", action: { model.run(app) })) {
            VStack(spacing: 22) {
                ResultHeadline(text: String(localized: "Run the recommended maintenance, or check each task first."),
                               button: ("Review all tasks", { showAll = true }))
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 18) {
                        CategoryCard(value: String(localized: "\(model.pendingCount ?? 0) tasks"),
                                     caption: String(localized: "of recommended maintenance"),
                                     detail: String(localized: "Mole refreshes caches and services it found worth refreshing. Nothing personal is touched."),
                                     symbol: "wrench.and.screwdriver", tint: module.palette.glow, large: true, glass: module.glass,
                                     actionTitle: "Run", review: { showAll = true }, action: { model.run(app) })
                            .frame(width: (geo.size.width - 36) / 3)
                        VStack(spacing: 18) {
                            diagnosisCard(report?.diagnosis ?? [])
                            HStack(spacing: 18) {
                                if let first = attention.first {
                                    CategoryCard(value: first.title, caption: Self.clean(first.lines.first ?? ""),
                                                 symbol: "exclamationmark.triangle", tint: Palette.warn, review: { showAll = true })
                                }
                                if let loginItems {
                                    let line = Self.clean(loginItems.lines.first ?? "")
                                    let count = line.range(of: #"\((\d+) checked\)"#, options: .regularExpression).map { String(line[$0]).filter(\.isNumber) }
                                    CategoryCard(value: count.map { String(localized: "\($0) login items") } ?? String(localized: "Login items"),
                                                 caption: line.replacingOccurrences(of: #"\s*\(\d+ checked\)"#, with: "", options: .regularExpression),
                                                 symbol: "person.badge.key", tint: module.palette.glow, review: { showAll = true })
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 14)
        }
    }

    private func diagnosisCard(_ diagnosis: [String]) -> some View {
        let main = diagnosis.filter { $0.hasPrefix("◎") || $0.hasPrefix("⊙") }.map(Self.clean)
        let processes = diagnosis.filter { !$0.hasPrefix("◎") && !$0.hasPrefix("⊙") }
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What slows your Mac").font(.system(size: 21, weight: .semibold))
                Spacer()
                FeatureDisc(symbol: "stethoscope", tint: module.palette.glow, size: 44)
            }
            ForEach(Array(main.prefix(3).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13)).foregroundStyle(Palette.fg2).lineLimit(2)
            }
            if !processes.isEmpty {
                HStack(spacing: 14) {
                    ForEach(Array(processes.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text(line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VolumeFill(radius: 22))
        .clipShape(shape)
        .volumeCard(radius: 22, tint: module.palette.glow)
    }

    private var list: some View {
        let report = model.report
        return ModuleScene(module: module, leading: .back { showAll = false }, orb: OrbAction(title: "Run", action: { model.run(app) })) {
            VStack(spacing: 16) {
                StepHeader(module: module, title: "All tasks", subtitle: model.headerSummary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(report?.tasks ?? []) { task in taskCard(task) }
                    }
                }
                .scrollIndicators(.never)
                ReviewFooter(command: "sudo -A -v && mo optimize",
                             note: String(localized: "Some tasks need administrator rights; macOS asks for your password once."))
            }
            .padding(.horizontal, 34).padding(.top, 8)
        }
    }

    static func clean(_ line: String) -> String {
        var s = line
        for marker in ["→ ", "◎ ", "⊙ ", "- ", "✓ "] where s.hasPrefix(marker) { s.removeFirst(marker.count) }
        return s
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
                Text(Self.clean(line)).font(.system(size: 12)).foregroundStyle(Palette.fg2).lineLimit(2)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(VolumeFill(radius: 16))
        .volumeCard(radius: 16, tint: module.palette.glow)
    }
}
