import MoleKit
import Observation
import SwiftUI

/// Space Map, like CleanMyMac's Space Lens: `mo analyze --json <path>` gives one level; Nora
/// caches each level, draws the entries as bubbles whose area follows their size, and drills
/// down on click. Selected items go to the Trash through Finder's own API (reversible).
@MainActor @Observable
final class SpaceMapModel {
    var stage: FlowStage = .start
    var root: URL
    var path: [URL] = []
    var cache: [URL: DiskAnalysis] = [:]
    var selected: Set<String> = []
    var showLargeFiles = false
    var loading = false
    /// One request at a time: a newer request, Back or Start over makes older results stale.
    @ObservationIgnored private var requestID = UUID()
    var error: String?
    var trashed: [String] = []
    var trashFailures: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var forward: [URL] = []

    init() { root = FileManager.default.homeDirectoryForCurrentUser }

    var current: URL? { path.last }
    var analysis: DiskAnalysis? { current.flatMap { cache[$0] } }
    var entries: [DiskAnalysis.Entry] { (analysis?.entries ?? []).sorted { $0.size > $1.size } }
    var largeFiles: [DiskAnalysis.Entry] { (analysis?.largeFiles ?? []).sorted { $0.size > $1.size } }
    var canGoForward: Bool { !forward.isEmpty }

    var selectedEntries: [DiskAnalysis.Entry] {
        let all = cache.values.flatMap { $0.entries + $0.largeFiles }
        var seen = Set<String>()
        return all.filter { selected.contains($0.path) && seen.insert($0.path).inserted }
    }

    var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }

    /// Volumes the user can scan: the home folder, the startup disk and mounted external drives.
    var volumes: [(title: String, url: URL)] {
        var list: [(String, URL)] = [(String(localized: "Home folder"), FileManager.default.homeDirectoryForCurrentUser),
                                     ("Macintosh HD", URL(fileURLWithPath: "/"))]
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        where url.path.hasPrefix("/Volumes/") {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
            list.append((name, url))
        }
        return list
    }

    /// Cancels whatever is loading and returns the id the next request must still hold.
    private func newRequest() -> UUID {
        task?.cancel()
        requestID = UUID()
        return requestID
    }

    func scan(_ app: AppModel) {
        let id = newRequest()
        stage = .scanning
        error = nil
        path = []
        forward = []
        selected = []
        task = Task {
            let ok = await load(root, app)
            guard requestID == id else { return }
            if ok { path = [root]; stage = .review } else { stage = .start }
        }
    }

    func open(_ url: URL, _ app: AppModel) {
        let id = newRequest()
        forward = []
        task = Task {
            if cache[url] == nil {
                let ok = await load(url, app)
                guard requestID == id, ok else { return }
            }
            guard requestID == id else { return }
            path.append(url)
        }
    }

    func back() {
        guard path.count > 1 else { return }
        _ = newRequest()
        forward.append(path.removeLast())
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        _ = newRequest()
        path.append(next)
    }

    func jump(to index: Int) {
        guard index < path.count - 1 else { return }
        _ = newRequest()
        forward = Array(path[(index + 1)...].reversed())
        path = Array(path[...index])
    }

    @discardableResult
    private func load(_ url: URL, _ app: AppModel) async -> Bool {
        loading = true
        defer { loading = false }
        do {
            let result = try await app.run(["analyze", "--json", url.path])
            guard let data = result.stdout.data(using: .utf8), result.succeeded || !result.stdout.isEmpty else {
                throw NoraError.commandFailed(result.stderr.isEmpty ? String(localized: "Mole could not read this folder.") : result.stderr)
            }
            cache[url] = try JSONDecoder().decode(DiskAnalysis.self, from: data)
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Moves the selection to the Trash. Reversible, so it needs no extra dialog.
    func trashSelected() {
        trashed = []
        trashFailures = []
        for entry in selectedEntries {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                trashed.append(entry.name)
            } catch {
                trashFailures.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        let gone = Set(selectedEntries.map(\.path))
        selected = []
        // Sizes above changed; drop the cached levels so a reopen measures again.
        for (url, analysis) in cache where analysis.entries.contains(where: { gone.contains($0.path) }) || analysis.largeFiles.contains(where: { gone.contains($0.path) }) {
            cache[url] = nil
        }
        stage = .done
    }

    func stop() { task?.cancel() }
    func reset() { _ = newRequest(); stage = .start; path = []; cache = [:]; selected = []; forward = [] }
}

struct SpaceMapView: View {
    @Environment(AppModel.self) private var app
    private var model: SpaceMapModel { app.spaceMap }
    private let module = Module.spaceMap

    var body: some View {
        switch model.stage {
        case .start:
            start.task { if app.autoScan { model.scan(app) } }
        case .scanning:
            WorkingView(module: module, title: "Measuring folders…", detail: model.root.path, onStop: { model.stop() })
        case .review, .running:
            SpaceLens(model: model)
        case .done:
            DoneView(module: module,
                     headline: model.trashFailures.isEmpty ? String(localized: "\(model.trashed.count) items moved to the Trash") : String(localized: "Some items stayed"),
                     lines: model.trashed.prefix(5).map { "✓ \($0)" } + model.trashFailures.map { "✕ \($0)" },
                     failed: model.trashed.isEmpty) { model.reset() }
        }
    }

    private var start: some View {
        @Bindable var model = model
        return ModuleStart(module: module,
                           subtitle: "See what takes the most space on your disk and move what you do not need to the Trash.",
                           features: [Feature(symbol: "circle.hexagongrid", text: "Visual map of your storage"),
                                      Feature(symbol: "folder", text: "Biggest folders, level by level"),
                                      Feature(symbol: "doc.richtext", text: "Large files")],
                           command: "mo analyze --json \(ShellQuote.word(model.root.path))",
                           action: { model.scan(app) }) {
            Picker("", selection: $model.root) {
                ForEach(model.volumes, id: \.url) { volume in
                    Label(volume.title, systemImage: volume.url.path == "/" ? "internaldrive" : volume.url.path.hasPrefix("/Volumes") ? "externaldrive" : "house")
                        .tag(volume.url)
                }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 260)
            if let error = model.error { Notice(text: error, color: Palette.crit) }
        }
    }
}

private struct SpaceLens: View {
    @Bindable var model: SpaceMapModel
    @Environment(AppModel.self) private var app
    private let module = Module.spaceMap

    var body: some View {
        ModuleScene(module: module, leading: .startOver { model.reset() },
                    orb: model.selected.isEmpty ? nil : OrbAction(title: "Remove", destructive: true, action: { model.trashSelected() })) {
            VStack(spacing: 14) {
                breadcrumb
                HStack(alignment: .top, spacing: 18) {
                    listPanel.frame(width: 380)
                    ZStack {
                        BubbleMap(entries: Array(model.entries.prefix(14)), total: max(model.analysis?.totalSize ?? 1, 1),
                                  tint: module.palette.glow) { entry in
                            if entry.isDirectory { model.open(URL(fileURLWithPath: entry.path), app) }
                        }
                        if model.loading { ProgressView().controlSize(.large).tint(.white) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
            }
            .padding(.horizontal, 24).padding(.top, 4)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26) }
                .buttonStyle(.plain).disabled(model.path.count < 2).keyboardShortcut("[", modifiers: .command)
            Button { model.goForward() } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26) }
                .buttonStyle(.plain).disabled(!model.canGoForward).keyboardShortcut("]", modifiers: .command)
            Spacer()
            ForEach(Array(model.path.enumerated()), id: \.offset) { index, url in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                Button { model.jump(to: index) } label: {
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Color.clear.frame(width: 60)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 44)
        .glassPanel(radius: 14)
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = model.current, let analysis = model.analysis {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: current.path)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.path == "/" ? "Macintosh HD" : current.lastPathComponent).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                        Text("\(Format.bytes(analysis.totalSize))\(analysis.scanStatus == "partial" ? "+" : "") · \(analysis.totalFiles ?? 0) files")
                            .font(.system(size: 13)).foregroundStyle(Palette.fg2)
                    }
                }
                Picker("", selection: $model.showLargeFiles) {
                    Text("Folders").tag(false)
                    Text("Large files").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                // No "Select all" here: ticking every folder of a level (at / that includes Applications)
                // and sending it to the Trash is too easy a mistake. Clearing a selection is always safe.
                if !model.selected.isEmpty {
                    Button("Deselect all") { model.selected.removeAll() }.buttonStyle(GlassButtonStyle())
                }
                if analysis.scanStatus == "partial" {
                    Notice(text: String(localized: "Some folders could not be read fully; their sizes are at least what is shown."), symbol: "info.circle", color: Palette.fg2)
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.showLargeFiles ? model.largeFiles : model.entries) { entry in row(entry) }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(radius: 20)
    }

    private func row(_ entry: DiskAnalysis.Entry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.selected.contains(entry.path) },
                                     set: { if $0 { model.selected.insert(entry.path) } else { model.selected.remove(entry.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 26, height: 26)
            Text(entry.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Format.bytes(entry.size) + (entry.isPartial ? "+" : "")).font(.system(size: 13, design: .rounded)).monospacedDigit().foregroundStyle(Palette.fg2)
            if entry.isDirectory {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDirectory { model.open(URL(fileURLWithPath: entry.path), app) } }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if let disk = app.status.snapshot?.disks.first(where: { $0.mount == "/" }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Macintosh HD").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(Format.bytes(disk.used)) of \(Format.bytes(disk.total)) used").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                    }
                    Meter(fraction: (disk.usedPercent ?? 0) / 100, tint: .white.opacity(0.85))
                }
                .frame(width: 380)
            }
            Spacer()
            Text(model.selected.isEmpty ? String(localized: "Select items to move them to the Trash")
                 : String(localized: "\(model.selected.count) selected · \(Format.bytes(model.selectedSize))"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 120)
        }
        .frame(height: 40)
        .onAppear { app.status.retain() }
        .onDisappear { app.status.release() }
    }
}

/// Bubbles whose area follows each entry's share, packed around the largest one.
private struct BubbleMap: View {
    let entries: [DiskAnalysis.Entry]
    let total: Int64
    let tint: Color
    let open: (DiskAnalysis.Entry) -> Void

    var body: some View {
        GeometryReader { geo in
            let circles = Self.pack(entries.map { Double(max($0.size, 1)) }, in: geo.size)
            ZStack {
                ForEach(Array(zip(entries, circles)), id: \.0.path) { entry, circle in
                    Bubble(entry: entry, radius: circle.r, tint: tint)
                        .position(x: circle.x, y: circle.y)
                        .onTapGesture { open(entry) }
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: entries.map(\.path))
        }
    }

    struct Circle2: Equatable { var x: Double; var y: Double; var r: Double }

    /// Greedy spiral packing: largest first in the middle, each next one at the first free spot
    /// along a spiral. Area scales so the bubbles fill about half the space.
    static func pack(_ sizes: [Double], in size: CGSize) -> [Circle2] {
        guard !sizes.isEmpty, size.width > 50, size.height > 50 else { return sizes.map { _ in Circle2(x: 0, y: 0, r: 0) } }
        let sum = sizes.reduce(0, +)
        let targetArea = Double(size.width * size.height) * 0.42
        let scale = sqrt(targetArea / (Double.pi * sum))
        var radii = sizes.map { max(sqrt($0) * scale, 26) }
        let maxR = Double(min(size.width, size.height)) * 0.36
        if let first = radii.first, first > maxR { let k = maxR / first; radii = radii.map { max($0 * k, 24) } }
        let cx = Double(size.width) / 2, cy = Double(size.height) / 2
        var placed: [Circle2] = []
        for r in radii {
            if placed.isEmpty { placed.append(Circle2(x: cx - r * 0.25, y: cy, r: r)); continue }
            var angle = 0.0, distance = 0.0, spot: Circle2?
            while distance < Double(max(size.width, size.height)) {
                let candidate = Circle2(x: cx + cos(angle) * distance, y: cy + sin(angle) * distance, r: r)
                let inside = candidate.x - r >= 0 && candidate.x + r <= Double(size.width) && candidate.y - r >= 0 && candidate.y + r <= Double(size.height)
                if inside, !placed.contains(where: { hypot($0.x - candidate.x, $0.y - candidate.y) < $0.r + r + 6 }) { spot = candidate; break }
                angle += 0.35
                distance += 1.6
            }
            placed.append(spot ?? Circle2(x: -999, y: -999, r: 0))
        }
        return placed
    }
}

private struct Bubble: View {
    let entry: DiskAnalysis.Entry
    let radius: Double
    let tint: Color
    @State private var hovering = false

    var body: some View {
        let d = radius * 2
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.18)], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 2, endRadius: radius * 1.2))
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: min(d * 0.36, 92), height: min(d * 0.36, 92))
                if radius > 44 {
                    Text(entry.name).font(.system(size: min(18, max(11, radius / 6)), weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: d * 0.78)
                    Text(Format.bytes(entry.size)).font(.system(size: min(17, max(10, radius / 7)), weight: .medium, design: .rounded))
                }
            }
        }
        .frame(width: d, height: d)
        .scaleEffect(hovering ? 1.04 : 1)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(Text("\(entry.name) · \(Format.bytes(entry.size))"))
    }
}
