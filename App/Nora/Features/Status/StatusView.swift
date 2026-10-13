import MoleKit
import SwiftUI

/// System Status: every field of `mo status --watch`, live.
struct StatusView: View {
    @Environment(AppModel.self) private var app
    private let module = Module.status

    var body: some View {
        let store = app.status
        let s = store.snapshot
        ModuleScene(module: module) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(s)
                if let s {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], alignment: .leading, spacing: 14) {
                        cpuCard(s, store)
                        memoryCard(s, store)
                        diskCard(s, store)
                        networkCard(s, store)
                        if !s.batteries.isEmpty || s.thermal != nil { powerCard(s) }
                        if !s.topProcesses.isEmpty { processCard(s) }
                        if !s.bluetooth.isEmpty { bluetoothCard(s) }
                    }
                } else if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
                CommandPreview(command: "mo status --watch --interval 1s")
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        }
        .onAppear { store.retain() }
        .onDisappear { store.release() }
    }

    private func header(_ s: StatusSnapshot?) -> some View {
        HStack(alignment: .center, spacing: 22) {
            GlassImage(name: module.glass, size: 120, glow: module.palette.glow)
            VStack(alignment: .leading, spacing: 6) {
                SceneTitle(text: module.title, glow: module.palette.glow)
                if let msg = s?.healthMessage { Text(msg).font(.system(size: 15)).foregroundStyle(Palette.fg2) }
                if let hw = s?.hardware {
                    Text([hw.model, hw.cpuModel, hw.totalRAM, hw.osVersion].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                if let up = s?.uptime { Text("Uptime \(up)").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
            Spacer()
            HealthRing(score: s?.healthScore)
        }
    }

    private func cpuCard(_ s: StatusSnapshot, _ store: StatusStore) -> some View {
        Card(title: "Processor", symbol: "cpu") {
            HStack(alignment: .lastTextBaseline) {
                Text(Format.percent(s.cpu?.usage)).font(.numberLarge)
                Spacer()
                if let cpu = s.cpu {
                    Text("Load \(Format.number(cpu.load1, digits: 2)) · \(Format.number(cpu.load5, digits: 2)) · \(Format.number(cpu.load15, digits: 2))")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).monospacedDigit()
                }
            }
            Sparkline(values: store.cpu, color: Color(hex: 0xFF5CB4), maxValue: 100).frame(height: 46)
            if let cores = s.cpu?.perCore, !cores.isEmpty {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Palette.pink.opacity(0.35 + 0.65 * min(v / 100, 1)))
                            .frame(maxWidth: 9)
                            .frame(height: max(3, 26 * CGFloat(min(v / 100, 1))))
                    }
                }
                .frame(height: 26, alignment: .bottom)
                if let p = s.cpu?.performanceCores, let e = s.cpu?.efficiencyCores {
                    Text("\(p) performance and \(e) efficiency cores").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func memoryCard(_ s: StatusSnapshot, _ store: StatusStore) -> some View {
        Card(title: "Memory", symbol: "memorychip") {
            let m = s.memory
            HStack(alignment: .lastTextBaseline) {
                Text(Format.percent(m?.usedPercent)).font(.numberLarge)
                Spacer()
                Text("\(Format.memory(m?.used)) of \(Format.memory(m?.total))").font(.system(size: 12)).foregroundStyle(Palette.fg2)
            }
            Sparkline(values: store.memory, color: Palette.cyan, maxValue: 100).frame(height: 46)
            InfoRow(label: "Cached", value: Format.memory(m?.cached))
            InfoRow(label: "Available", value: Format.memory(m?.available))
            if let used = m?.swapUsed, let total = m?.swapTotal, total > 0 {
                InfoRow(label: "Swap", value: "\(Format.memory(used)) / \(Format.memory(total))")
            }
            if let pressure = m?.pressure { InfoRow(label: "Pressure", value: pressure) }
        }
    }

    private func diskCard(_ s: StatusSnapshot, _ store: StatusStore) -> some View {
        Card(title: "Disks", symbol: "internaldrive") {
            ForEach(s.disks) { disk in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(disk.mount == "/" ? "Macintosh HD" : ((disk.mount ?? "?") as NSString).lastPathComponent)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .help(disk.mount ?? "")
                        if disk.external == true { Text("external").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                        Spacer()
                        Text("\(Format.bytes(disk.used)) / \(Format.bytes(disk.total))").font(.system(size: 11)).foregroundStyle(Palette.fg2).monospacedDigit()
                    }
                    Meter(fraction: (disk.usedPercent ?? 0) / 100)
                }
            }
            HStack(spacing: 14) {
                Label("Read \(Format.number(store.diskRead.last, digits: 1)) MB/s", systemImage: "arrow.down")
                Label("Write \(Format.number(store.diskWrite.last, digits: 1)) MB/s", systemImage: "arrow.up")
            }
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if let trash = s.trashSize, trash > 0 { InfoRow(label: "Trash", value: Format.bytes(trash)) }
        }
    }

    private func networkCard(_ s: StatusSnapshot, _ store: StatusStore) -> some View {
        Card(title: "Network", symbol: "network") {
            HStack {
                Label(Format.rate(store.download.last), systemImage: "arrow.down").foregroundStyle(Palette.amber)
                Spacer()
                Label(Format.rate(store.upload.last), systemImage: "arrow.up").foregroundStyle(Palette.cyan)
            }
            .font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
            ZStack {
                Sparkline(values: store.download, color: Palette.amber)
                Sparkline(values: store.upload, color: Palette.cyan, maxValue: (store.download.max() ?? 0) * 1.15, fill: false)
            }
            .frame(height: 40)
            ForEach(s.network.filter { $0.ip?.isEmpty == false }) { iface in
                InfoRow(label: LocalizedStringKey(iface.name ?? "?"), value: iface.ip ?? "")
            }
            if let proxy = s.proxy, proxy.enabled == true {
                InfoRow(label: "Proxy", value: [proxy.type, proxy.host].compactMap { $0 }.joined(separator: " "))
            }
        }
    }

    private func powerCard(_ s: StatusSnapshot) -> some View {
        Card(title: "Battery and power", symbol: "battery.75percent") {
            if let b = s.batteries.first {
                HStack(alignment: .lastTextBaseline) {
                    Text(b.percent.map { "\($0)%" } ?? "—").font(.numberLarge)
                    Spacer()
                    Text(b.status ?? "").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                }
                if let left = b.timeLeft, !left.isEmpty { InfoRow(label: "Time left", value: left) }
                if let health = b.health { InfoRow(label: "Condition", value: health) }
                if let cap = b.capacity { InfoRow(label: "Maximum capacity", value: "\(cap)%") }
                if let cycles = b.cycleCount { InfoRow(label: "Cycles", value: "\(cycles)") }
            }
            if let t = s.thermal {
                if let w = t.systemPower { InfoRow(label: "System power", value: "\(Format.number(w)) W") }
                if let w = t.adapterPower { InfoRow(label: "Adapter", value: "\(Format.number(w, digits: 0)) W") }
                if let c = t.cpuTemp { InfoRow(label: "CPU temperature", value: "\(Format.number(c, digits: 0)) °C") }
                if let c = t.gpuTemp { InfoRow(label: "GPU temperature", value: "\(Format.number(c, digits: 0)) °C") }
                if let rpm = t.fanSpeed, rpm > 0 { InfoRow(label: "Fan", value: "\(rpm) rpm") }
            }
        }
    }

    private func processCard(_ s: StatusSnapshot) -> some View {
        Card(title: "Top processes", symbol: "list.bullet") {
            ForEach(s.topProcesses.prefix(6)) { p in
                HStack {
                    Text(p.name ?? "?").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Format.percent(p.cpu)).monospacedDigit().foregroundStyle(Palette.fg2)
                    Text(Format.memory(p.memoryBytes)).monospacedDigit().foregroundStyle(Palette.muted).frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            if !s.processAlerts.isEmpty {
                Divider().overlay(Palette.line)
                ForEach(s.processAlerts) { a in
                    Label("\(a.name ?? "?") above \(Format.percent(a.threshold)) for \(a.window ?? "")", systemImage: "flame")
                        .font(.system(size: 11)).foregroundStyle(Palette.warn)
                }
            }
            if let z = s.zombieCount, z > 0 { InfoRow(label: "Zombie processes", value: "\(z)") }
        }
    }

    private func bluetoothCard(_ s: StatusSnapshot) -> some View {
        Card(title: "Bluetooth", symbol: "dot.radiowaves.left.and.right") {
            ForEach(s.bluetooth.prefix(6)) { d in
                HStack {
                    Circle().fill(d.connected == true ? Palette.good : .white.opacity(0.2)).frame(width: 6, height: 6)
                    Text(d.name ?? "?").lineLimit(1)
                    Spacer()
                    if let b = d.battery { Text(b).foregroundStyle(Palette.fg2) }
                }
                .font(.system(size: 12))
            }
        }
    }
}
