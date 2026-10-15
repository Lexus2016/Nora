import AppKit
import Carbon.HIToolbox
import Darwin
import MoleKit
import SwiftUI

/// The menu bar item: `NSStatusItem` + `NSPopover` (not MenuBarExtra: it has no right-click and
/// no programmatic open). Left click opens the quick menu, right click a short menu, ⌥⌘N toggles.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let app: AppModel
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var hotKey: EventHotKeyRef?
    private var titleTimer: Timer?
    private var retainedStatus = false
    private let temperatureSampler = TemperatureSampler()
    /// CPU average from the chip's sensors, or Mole's reading where the sensors are not readable.
    private var cpuTemperature: Double?
    /// The chip's sensors gave no CPU temperature, so the reading comes from Mole's stream.
    private var temperatureFromMole = false

    init(app: AppModel) {
        self.app = app
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        apply()
        registerHotKey()
    }

    @objc private func defaultsChanged() { apply() }

    private var style: MenuBarStyle { MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .icon }
    private var showsTemperature: Bool { UserDefaults.standard.bool(forKey: MenuBarStyle.temperatureKey) }

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
        // Metrics in the bar need the live stream even when no window is open; so does the
        // temperature when the chip's sensors do not give it.
        let wantsStream = show && (style != .icon || (showsTemperature && temperatureFromMole))
        if wantsStream != retainedStatus {
            retainedStatus = wantsStream
            if wantsStream { app.status.retainStream() } else { app.status.releaseStream() }
        }
        titleTimer?.invalidate()
        titleTimer = nil
        let wantsTemperature = show && showsTemperature
        if !wantsTemperature { cpuTemperature = nil; temperatureFromMole = false }
        if wantsStream || wantsTemperature {
            titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(temperature: wantsTemperature) }
            }
        }
        tick(temperature: wantsTemperature)
    }

    private func tick(temperature: Bool) {
        updateTitle()
        guard temperature else { return }
        Task {
            let reading = await temperatureSampler.read()
            cpuTemperature = reading.cpu?.average ?? app.status.currentSnapshot?.thermal?.cpuTemp
            if (reading.cpu == nil) != temperatureFromMole {
                temperatureFromMole = reading.cpu == nil
                apply()
                return
            }
            updateTitle()
        }
    }

    private func updateTitle() {
        guard let button = item?.button else { return }
        // Only current numbers: a dash rather than the last value of a stream that stopped.
        let s = app.status.currentSnapshot
        let cpu = Format.percent(s?.cpu?.usage), mem = Format.percent(s?.memory?.usedPercent)
        let text: String = switch style {
        case .icon: ""
        case .cpu: " \(cpu)"
        case .memory: " \(mem)"
        case .both: " \(cpu) · \(mem)"
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString(string: text, attributes: [.font: font])
        if showsTemperature, let celsius = cpuTemperature {
            // A coloured dot for how hot, the number in the menu bar's own colour.
            title.append(NSAttributedString(string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: Self.color(HeatLevel(celsius: celsius)),
                                                                        .baselineOffset: 1]))
            title.append(NSAttributedString(string: " \(Int(celsius.rounded()))°", attributes: [.font: font]))
            button.toolTip = String(localized: "Nora: system status and quick actions") + "\n" + String(localized: "CPU \(Int(celsius.rounded())) °C")
        } else if showsTemperature {
            button.toolTip = String(localized: "Nora: system status and quick actions") + "\n" + String(localized: "CPU temperature unavailable right now")
        } else {
            button.toolTip = String(localized: "Nora: system status and quick actions")
        }
        button.attributedTitle = title
    }

    static func color(_ level: HeatLevel) -> NSColor {
        switch level {
        case .normal: .systemGreen
        case .warm: .systemOrange
        case .hot: .systemRed
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { toggle() }
    }

    func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // The menu exists only while it is shown. A closed popover keeps its view in a hidden
            // window, and that view went on redrawing every status sample (about 14% CPU) with the
            // stream held open, because SwiftUI never calls onDisappear for it.
            // Opened again while the last close is still animating: that menu is still there.
            if popover.contentViewController == nil {
                popover.contentSize = NSSize(width: 380, height: 560)
                popover.contentViewController = NSHostingController(rootView: QuickMenu(temperature: temperatureSampler, close: { [weak self] in self?.popover.performClose(nil) })
                    .environment(app).preferredColorScheme(.dark))
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// One hold on the stream per open menu, whatever order AppKit reports a quick close and
    /// reopen in.
    private var menuHoldsStatus = false

    func popoverWillShow(_ notification: Notification) {
        guard !menuHoldsStatus else { return }
        menuHoldsStatus = true
        app.status.retain()
    }

    func popoverDidClose(_ notification: Notification) {
        // A close that finishes after the menu was opened again leaves that menu alone.
        guard !popover.isShown else { return }
        if menuHoldsStatus {
            menuHoldsStatus = false
            app.status.release()
        }
        popover.contentViewController = nil
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
    let temperature: TemperatureSampler
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var tab = Self.initialTab
    /// Read every few seconds while the menu is open, never in `body`: walking the process table
    /// on every status sample was most of the menu's own cost.
    @State private var memoryTop: [AppMemory] = []
    @State private var cpuTemperature: Double?

    /// Memory first. Screenshots open the CPU tab (`-NoraPopoverTab 1`): it lists the processes
    /// Mole reports, while the memory list comes from this Mac's own process table.
    private static var initialTab: Int {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "NoraPopoverTab")
        #else
        0
        #endif
    }

    var body: some View {
        // Only current numbers; while the stream is down the tiles show dashes and the reason.
        let s = app.status.liveSnapshot
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HealthRing(score: s?.healthScore, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s?.healthScore == nil ? (app.status.lastError ?? String(localized: "Reading your Mac…")) : HistoryView.healthWord(s?.healthScore))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
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
        .task {
            while !Task.isCancelled {
                memoryTop = await Task.detached(priority: .utility) { AppMemory.top(3) }.value
                cpuTemperature = await temperature.read().cpu?.average
                try? await Task.sleep(for: .seconds(3))
            }
        }
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
        // The chip's sensors first, Mole's reading where they give none.
        let celsius = tile == .cpu ? cpuTemperature ?? s?.thermal?.cpuTemp : nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(tile.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                if let celsius {
                    Circle().fill(Color(nsColor: MenuBarController.color(HeatLevel(celsius: celsius)))).frame(width: 6, height: 6)
                    Text(verbatim: "\(Int(celsius.rounded()))°").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.fg2)
                }
            }
            .help(celsius.map { Text("CPU \(Int($0.rounded())) °C") } ?? Text(verbatim: ""))
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
                ForEach(memoryTop) { usage in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: usage.owner)).resizable().frame(width: 18, height: 18)
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
struct AppMemory: Identifiable, Sendable {
    let name: String
    let bytes: Int64
    /// The `.app` (or executable) the memory is counted toward; its icon is looked up when shown.
    let owner: String
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
            return AppMemory(name: name, bytes: bytes, owner: owner)
        }
    }
}
