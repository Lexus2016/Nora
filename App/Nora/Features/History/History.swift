import Charts
import MoleKit
import Observation
import SwiftUI

/// History: Mole's own record (`mo history --json --limit 200`) as a dashboard, like
/// CleanMyMac's Activity History.
@MainActor @Observable
final class HistoryModel {
    var sessions: [MoleHistory.Session] = []
    var loaded = false
    var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Each load replaces the previous one, so a slow older read never overwrites a newer list.
    func load(_ app: AppModel) {
        error = nil
        task?.cancel()
        task = Task {
            do {
                let result = try await app.run(["history", "--json", "--limit", "200"])
                guard !Task.isCancelled, let data = result.stdout.data(using: .utf8) else { return }
                sessions = try JSONDecoder().decode(MoleHistory.self, from: data).sessions
                loaded = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loaded = true
            }
        }
    }

    var totalFreed: Int64 { sessions.reduce(0) { $0 + $1.size } }

    var freedByCommand: [(command: String, size: Int64)] {
        Dictionary(grouping: sessions, by: \.command)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.size }) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
    }

    /// `failed` counts files Mole could not remove; `failedTasks` counts maintenance tasks (Mole
    /// keeps them apart), so a failed optimize shows up too.
    var actions: (removed: Int, trashed: Int, skipped: Int, failed: Int, failedTasks: Int) {
        sessions.reduce((0, 0, 0, 0, 0)) { ($0.0 + $1.removed, $0.1 + $1.trashed, $0.2 + $1.skipped, $0.3 + $1.failed, $0.4 + $1.failedTasks) }
    }

    /// Freed bytes per day for the last 30 days.
    var daily: [(day: Date, size: Int64)] {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let grouped = Dictionary(grouping: sessions.filter { ($0.started ?? .distantPast) >= since }) {
            calendar.startOfDay(for: $0.started ?? Date())
        }
        return grouped.map { ($0.key, $0.value.reduce(0) { $0 + $1.size }) }.sorted { $0.0 < $1.0 }
    }

    var firstDate: Date? { sessions.compactMap(\.started).min() }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    private var model: HistoryModel { app.history }
    private let module = Module.history

    var body: some View {
        ModuleScene(module: module) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("Activity History").font(.system(size: 52, weight: .light))
                        Spacer()
                        if let first = model.firstDate {
                            Text("Since \(first.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 14)).foregroundStyle(Palette.fg2)
                        }
                    }
                    Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                        GridRow {
                            healthCard.gridCellColumns(1)
                            freedCard
                            actionsCard
                        }
                        GridRow {
                            chartCard.gridCellColumns(2)
                            recentCard
                        }
                    }
                    CommandPreview(command: "mo history --json --limit 200").frame(maxWidth: 420)
                }
                .padding(.horizontal, 34).padding(.top, 6).padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        // Read again every time the screen opens, so runs made meanwhile show up.
        .task { model.load(app) }
        .showsLiveStatus(app.status)
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.fg2)
            content()
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(VolumeFill(radius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .volumeCard(radius: 22, tint: module.palette.glow)
    }

    private var healthCard: some View {
        let s = app.status.snapshot
        return panel("Your Mac's health") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.healthWord(s?.healthScore)).font(.system(size: 34, weight: .medium)).foregroundStyle(Palette.cyan)
                    Text(s?.hardware?.model ?? "Mac").font(.system(size: 13)).foregroundStyle(Palette.fg2)
                }
                Spacer()
                HealthRing(score: s?.healthScore, size: 86)
            }
            Spacer(minLength: 10)
            if let disk = s?.disks.first(where: { $0.mount == "/" }) {
                HStack {
                    Text("Macintosh HD").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Format.bytes(disk.used)) of \(Format.bytes(disk.total)) used").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                }
                Meter(fraction: (disk.usedPercent ?? 0) / 100, tint: .white.opacity(0.85))
            }
        }
    }

    private var freedCard: some View {
        panel("Space freed with Mole") {
            Text(Format.bytes(model.totalFreed)).font(.system(size: 38, weight: .semibold, design: .rounded))
            let parts = model.freedByCommand
            let total = max(Double(model.totalFreed), 1)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        Capsule().fill(Palette.series[i % Palette.series.count])
                            .frame(width: max(6, geo.size.width * Double(part.size) / total))
                    }
                }
            }
            .frame(height: 14)
            ForEach(Array(parts.prefix(4).enumerated()), id: \.offset) { i, part in
                HStack {
                    Circle().fill(Palette.series[i % Palette.series.count]).frame(width: 8, height: 8)
                    Text(Self.commandTitle(part.command)).font(.system(size: 13))
                    Spacer()
                    Text(Format.bytes(part.size)).font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            if parts.isEmpty { Text("Nothing cleaned yet.").font(.system(size: 13)).foregroundStyle(Palette.muted) }
        }
    }

    private var actionsCard: some View {
        let a = model.actions
        return panel("What Mole did") {
            Text("\(model.sessions.count)").font(.system(size: 38, weight: .semibold, design: .rounded))
            Text("sessions").font(.system(size: 13)).foregroundStyle(Palette.fg2)
            InfoRow(label: "Deleted", value: "\(a.removed)")
            InfoRow(label: "Moved to the Trash", value: "\(a.trashed)")
            InfoRow(label: "Skipped as protected", value: "\(a.skipped)")
            InfoRow(label: "Failed", value: "\(a.failed)")
            InfoRow(label: "Maintenance tasks failed", value: "\(a.failedTasks)")
        }
    }

    private var chartCard: some View {
        panel("Space freed per day, last 30 days") {
            if model.daily.isEmpty {
                Text("No cleanups in the last 30 days.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            } else {
                Chart(model.daily, id: \.day) { point in
                    BarMark(x: .value("Day", point.day, unit: .day), y: .value("Freed", Double(point.size) / 1e9))
                        .foregroundStyle(LinearGradient(colors: [module.palette.glow, Palette.cyan], startPoint: .bottom, endPoint: .top))
                        .cornerRadius(4)
                }
                .chartYAxis { AxisMarks { value in AxisValueLabel { if let v = value.as(Double.self) { Text("\(v, specifier: "%.1f") GB") } } } }
                .frame(height: 170)
            }
        }
    }

    private var recentCard: some View {
        panel("Recent sessions") {
            ForEach(model.sessions.prefix(6)) { session in
                HStack {
                    Text(Self.commandTitle(session.command)).font(.system(size: 13, weight: .medium))
                    if session.failed + session.failedTasks > 0 {
                        Text("\(session.failed + session.failedTasks) failed").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.crit)
                    }
                    Spacer()
                    Text(session.started?.formatted(date: .abbreviated, time: .shortened) ?? "").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text(Format.bytes(session.size)).font(.system(size: 12, design: .rounded)).frame(width: 70, alignment: .trailing)
                }
            }
            if let error = model.error { Notice(text: error, color: Palette.crit) }
        }
    }

    static func commandTitle(_ command: String) -> String {
        switch command {
        case "clean": String(localized: "Cleanup")
        case "purge": String(localized: "Projects")
        case "installer": String(localized: "Installers")
        case "uninstall": String(localized: "Applications")
        case "optimize": String(localized: "Performance")
        default: command
        }
    }

    static func healthWord(_ score: Int?) -> String {
        guard let score else { return "—" }
        switch score {
        case 80...: return String(localized: "Excellent")
        case 60..<80: return String(localized: "Good")
        case 40..<60: return String(localized: "Fair")
        default: return String(localized: "Needs care")
        }
    }
}
