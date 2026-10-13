import AppKit
import Carbon.HIToolbox
import Darwin
import MoleKit
import SwiftUI

/// The menu bar item: `NSStatusItem` + `NSPopover` (not MenuBarExtra: it has no right-click and
/// no programmatic open). Left click opens the quick menu, right click a short menu, ⌥⌘N toggles.
@MainActor
final class MenuBarController: NSObject {
    private let app: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: EventHotKeyRef?
    private var titleTimer: Timer?
    private var retainedStatus = false

    init(app: AppModel) {
        self.app = app
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.contentViewController = NSHostingController(rootView: QuickMenu(close: { [weak self] in self?.popover.performClose(nil) })
            .environment(app).preferredColorScheme(.dark))
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        apply()
        registerHotKey()
    }

    @objc private func defaultsChanged() { apply() }

    private var style: MenuBarStyle { MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .icon }

    private func apply() {
        let show = UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true
        if show, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Nora")
            item.button?.imagePosition = .imageLeading
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.toolTip = String(localized: "Nora: system status and quick actions")
            self.item = item
        } else if !show, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        // Metrics in the bar need the live stream even when no window is open.
        let wantsStream = show && style != .icon
        if wantsStream != retainedStatus {
            retainedStatus = wantsStream
            if wantsStream { app.status.retain() } else { app.status.release() }
        }
        titleTimer?.invalidate()
        if wantsStream {
            titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTitle() }
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = item?.button else { return }
        let s = app.status.snapshot
        let cpu = Format.percent(s?.cpu?.usage), mem = Format.percent(s?.memory?.usedPercent)
        let text: String = switch style {
        case .icon: ""
        case .cpu: " \(cpu)"
        case .memory: " \(mem)"
        case .both: " \(cpu) · \(mem)"
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Nora"), action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for module in Module.available {
            let entry = menu.addItem(withTitle: String(localized: String.LocalizationValue(module.titleText)), action: #selector(openModule(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = module.rawValue
            entry.image = NSImage(systemSymbolName: module.symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "Quit Nora"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func openMain() { app.showMain(nil) }

    @objc private func openModule(_ sender: NSMenuItem) {
        app.showMain((sender.representedObject as? String).flatMap(Module.init(rawValue:)))
    }

    @objc private func openSettings() {
        app.showSettings()
    }

    /// ⌥⌘N through Carbon, which needs no Accessibility permission.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<MenuBarController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.toggle() } }
            return noErr
        }, 1, &spec, context, nil)
        let id = EventHotKeyID(signature: OSType(0x4E4F5241), id: 1) // "NORA"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }
}

/// The popover: health, four tiles, what loads the Mac, reclaimable space, jumps.
struct QuickMenu: View {
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var tab = 0

    var body: some View {
        let s = app.status.snapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HealthRing(score: s?.healthScore, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s?.healthScore == nil ? String(localized: "Reading your Mac…") : HistoryView.healthWord(s?.healthScore)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("Mole \(app.mole?.version ?? "—")").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { open(nil) } label: { Image(systemName: "macwindow").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help(Text("Open Nora"))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(MenuTile.chosen) { tile in tileView(tile, s) }
            }
            load(s)
            reclaim
            HStack(spacing: 6) {
                ForEach(Module.available.prefix(8)) { module in
                    Button { open(module) } label: {
                        Image(systemName: module.symbol).font(.system(size: 14)).frame(width: 34, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain).help(Text(module.title))
                }
            }
            HStack {
                Button("Settings…") { close(); app.showSettings() }
                Spacer()
                Button("Quit Nora") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.fg2)
        }
        .padding(16)
        .frame(width: 380)
        .background(SceneBackground(palette: Module.smartCare.palette).opacity(0.9))
        .onAppear { app.status.retain() }
        .onDisappear { app.status.release() }
    }

    private func open(_ module: Module?) {
        close()
        app.showMain(module)
    }

    private func tileView(_ tile: MenuTile, _ s: StatusSnapshot?) -> some View {
        let store = app.status
        let (value, series, color, maxValue): (String, [Double], Color, Double?) = switch tile {
        case .cpu: (Format.percent(s?.cpu?.usage), store.cpu, Color(hex: 0xFF5CB4), 100)
        case .memory: (Format.percent(s?.memory?.usedPercent), store.memory, Palette.cyan, 100)
        case .network: (Format.rate(store.download.last), store.download, Palette.amber, nil)
        case .disk:
            (s?.disks.first(where: { $0.mount == "/" }).map { String(localized: "\(Format.bytes(($0.total ?? 0) - ($0.used ?? 0))) free") } ?? "—",
             store.diskWrite, Palette.violet, nil)
        case .gpu: (Format.percent(s?.gpu.first?.usage), [], Palette.good, 100)
        case .fan: (s?.thermal?.fanSpeed.map { $0 > 0 ? "\($0) rpm" : "—" } ?? "—", [], Palette.warn, nil)
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(tile.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: series, color: color, maxValue: maxValue).frame(height: 22)
        }
        .padding(10)
        .background(VolumeFill(radius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }

    /// Read-only: where memory and CPU go. Nothing here frees, quits or kills anything.
    private func load(_ s: StatusSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Highest load").font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                Picker("", selection: $tab) {
                    Text("Memory").tag(0)
                    Text("CPU").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 128)
            }
            if tab == 0 {
                let m = s?.memory
                let total = Double(m?.total ?? 1)
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Capsule().fill(Palette.pink).frame(width: geo.size.width * Double(max((m?.used ?? 0) - (m?.cached ?? 0), 0)) / total)
                        Capsule().fill(Palette.cyan).frame(width: geo.size.width * Double(m?.cached ?? 0) / total)
                        Capsule().fill(.white.opacity(0.15))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Used \(Format.memory(m?.used)) · cache \(Format.memory(m?.cached))").font(.system(size: 11)).foregroundStyle(Palette.fg2)
                    Spacer()
                    if let swap = m?.swapUsed, swap > 0 {
                        Text("Swap \(Format.memory(swap))").font(.system(size: 11)).foregroundStyle(Palette.fg2)
                            .help(Text("Swap fills when memory was short earlier. It empties as the apps holding it quit, or after a restart."))
                    }
                }
                ForEach(AppMemory.top(3)) { usage in
                    HStack(spacing: 8) {
                        Image(nsImage: usage.icon).resizable().frame(width: 18, height: 18)
                        Text(usage.name).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(Format.memory(usage.bytes)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                    }
                }
            } else {
                ForEach(s?.topProcesses.prefix(3) ?? []) { p in
                    HStack {
                        Text(p.name ?? "?").font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(Format.percent(p.cpu)).font(.system(size: 12, design: .rounded)).monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .background(VolumeFill(radius: 12))
    }

    /// Text on its own line and two equal buttons under it, so long translations never wrap.
    private var reclaim: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let preview = app.cleanup.preview {
                    Text(Format.bytes(preview.items.reduce(0) { $0 + $1.size })).font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("can be cleaned").font(.system(size: 11)).foregroundStyle(Palette.fg2)
                } else {
                    Text("Free up space").font(.system(size: 14, weight: .semibold))
                    Text("Run a scan to see how much").font(.system(size: 11)).foregroundStyle(Palette.fg2)
                }
            }
            HStack(spacing: 10) {
                Button { open(app.cleanup.preview == nil ? .smartCare : .cleanup) } label: { Text("Clean").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
                Button { open(.performance) } label: { Text("Optimize").frame(maxWidth: .infinity) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }
}

/// Memory per app: helper processes count toward the outermost `.app` they run from.
struct AppMemory: Identifiable {
    let name: String
    let bytes: Int64
    let icon: NSImage
    var id: String { name }

    static func top(_ count: Int) -> [AppMemory] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        var byOwner: [String: Int64] = [:]
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let owner = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
            byOwner[owner, default: 0] += Int64(info.ri_phys_footprint)
        }
        return byOwner.sorted { $0.value > $1.value }.prefix(count).map { owner, bytes in
            let name = owner.hasSuffix(".app") ? ((owner as NSString).lastPathComponent as NSString).deletingPathExtension : (owner as NSString).lastPathComponent
            return AppMemory(name: name, bytes: bytes, icon: NSWorkspace.shared.icon(forFile: owner))
        }
    }
}
