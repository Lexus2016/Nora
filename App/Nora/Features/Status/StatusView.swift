import MoleKit
import SwiftUI

/// System Status: every field of `mo status --watch`, live.
struct StatusView: View {
    @Environment(AppModel.self) private var app
    private let module = Module.status
    @State private var live = LiveStatus()
    @State private var portsExpanded = false

    var body: some View {
        let store = app.status
        let s = store.snapshot
        ModuleScene(module: module) {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(s)
                if s != nil, let error = store.lastError {
                    // The stream stopped after it had delivered data: the cards below are old.
                    Notice(text: String(localized: "Live data stopped: \(error). The values below are from \((store.lastSampleAt ?? Date()).formatted(date: .omitted, time: .standard))."),
                           symbol: "exclamationmark.triangle")
                }
                if let s {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 14)], alignment: .leading, spacing: 14) {
                        cpuCard(s, store)
                        memoryCard(s, store)
                        diskCard(s, store)
                        networkCard(s, store)
                        powerLiveCard()
                        temperatureCard(s)
                        energyModeCard()
                        trafficCard()
                        if !s.batteries.isEmpty || s.thermal != nil { powerCard(s) }
                        if !s.topProcesses.isEmpty { processCard(s) }
                        if !s.bluetooth.isEmpty { bluetoothCard(s) }
                        portsCard()
                    }
                } else if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn)
                } else {
                    Spinner()
                }
                CommandPreview(command: "mo status --watch --interval 1s")
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        }
        .onAppear {
            store.retain()
            live.start(home: app.home, askpass: app.askpassURL)
        }
        .onDisappear {
            store.release()
            live.stop()
        }
    }

    private func header(_ s: StatusSnapshot?) -> some View {
        HStack(alignment: .center, spacing: 22) {
            GlassImage(name: module.glass, size: 120, glow: module.palette.glow)
            VStack(alignment: .leading, spacing: 6) {
                SceneTitle(text: module.title, glow: module.palette.glow)
                if s?.healthScore != nil { Text(HistoryView.healthWord(s?.healthScore)).font(.system(size: 15)).foregroundStyle(Palette.fg2) }
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
                if let w = t.systemPower { InfoRow(label: "System power (Mole)", value: "\(Format.number(w)) W") }
                if let w = t.adapterPower { InfoRow(label: "Adapter", value: "\(Format.number(w, digits: 0)) W") }
            }
        }
    }

    // MARK: Live cards (IOReport, IOHID, pmset, lsof, nettop)

    private func powerLiveCard() -> some View {
        Card(title: "Power", symbol: "bolt") {
            HStack(alignment: .lastTextBaseline) {
                Text(powerText { $0.total }).font(.numberMedium).monospacedDigit()
                Spacer()
                Text("total").font(.system(size: 12)).foregroundStyle(Palette.fg2)
            }
            InfoRow(label: "CPU", value: powerText { $0.cpu })
            InfoRow(label: "GPU", value: powerText { $0.gpu })
            InfoRow(label: "Neural Engine", value: powerText { $0.ane })
            Text("Read from the power counters, no password needed. CPU energy updates rarely, so CPU watts are an average over the gap between updates.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func temperatureCard(_ s: StatusSnapshot) -> some View {
        Card(title: "Temperatures", symbol: "thermometer.medium") {
            let reading = live.temperatures.reading
            let loaded = live.temperatures.isLoaded
            InfoRow(label: "CPU average", value: celsius(reading?.cpu?.average, loaded: loaded))
            InfoRow(label: "CPU max", value: celsius(reading?.cpu?.max, loaded: loaded))
            if let sensors = reading?.cpu?.sensors {
                Text("\(sensors) CPU sensors").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            InfoRow(label: "GPU", value: celsius(reading?.gpu?.average, loaded: loaded))
            if let t = s.thermal {
                if let c = t.cpuTemp { InfoRow(label: "CPU (Mole)", value: celsius(c, loaded: true)) }
                if let c = t.gpuTemp { InfoRow(label: "GPU (Mole)", value: celsius(c, loaded: true)) }
                if let rpm = t.fanSpeed, rpm > 0 { InfoRow(label: "Fan (Mole)", value: "\(rpm) rpm") }
            }
        }
    }

    private func energyModeCard() -> some View {
        Card(title: "Energy mode", symbol: "leaf") {
            switch live.energy {
            case .pending:
                Spinner()
            case .unavailable:
                Text("Energy mode is not reported on this Mac.").font(.system(size: 12)).foregroundStyle(Palette.fg2)
            case .value(let state):
                HStack(spacing: 6) {
                    ForEach(state.offered, id: \.self) { mode in
                        energySegment(mode, state: state)
                    }
                }
                Text("Changing the mode asks for your Mac password.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let command = live.pendingCommand, let mode = live.pendingMode {
                    CommandPreview(command: command)
                    HStack(spacing: 8) {
                        Button(action: { Task { await live.apply() } }) {
                            Text("Apply \(energyTitle(mode))")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(live.isApplying)
                        Button("Cancel") { live.cancelPending() }
                            .buttonStyle(GlassButtonStyle())
                            .disabled(live.isApplying)
                        if live.isApplying { Spinner() }
                    }
                }
                if let message = live.applyMessage {
                    Text(message).font(.system(size: 11)).foregroundStyle(Palette.warn)
                }
            }
        }
    }

    private func energySegment(_ mode: EnergyMode, state: EnergyModeState) -> some View {
        let isCurrent = state.current == mode
        let isPending = live.pendingMode == mode
        return Button { live.choose(mode) } label: {
            Text(energyTitle(mode))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isCurrent ? Color.white : Palette.fg2)
                .background(
                    Capsule().fill(isCurrent ? Palette.cyan.opacity(0.28) : Palette.surface2)
                )
                .overlay(
                    Capsule().stroke(isPending ? Palette.cyan : Palette.line, lineWidth: isPending ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || live.isApplying)
    }

    private func energyTitle(_ mode: EnergyMode) -> String {
        switch mode {
        case .low: return String(localized: "Low Power")
        case .automatic: return String(localized: "Automatic")
        case .high: return String(localized: "High Power")
        }
    }

    private func trafficCard() -> some View {
        Card(title: "Network by app", symbol: "arrow.up.arrow.down") {
            switch live.traffic {
            case .pending:
                Spinner()
            case .unavailable:
                Text("nettop did not return data.").font(.system(size: 12)).foregroundStyle(Palette.fg2)
            case .value(let report):
                if report.down.isEmpty && report.up.isEmpty {
                    Text("No network traffic in the last second.").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                }
                if !report.down.isEmpty {
                    Text("Download").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amber)
                    ForEach(report.down) { entry in
                        InfoRow(label: LocalizedStringKey(entry.name), value: Format.rate(entry.downBytesPerSecond / 1_048_576))
                    }
                }
                if !report.up.isEmpty {
                    Text("Upload").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.cyan)
                    ForEach(report.up) { entry in
                        InfoRow(label: LocalizedStringKey(entry.name), value: Format.rate(entry.upBytesPerSecond / 1_048_576))
                    }
                }
            }
        }
    }

    private func portsCard() -> some View {
        Card(title: "Listening ports", symbol: "point.3.connected.trianglepath.dotted") {
            switch live.ports {
            case .pending:
                Spinner()
            case .unavailable:
                Text("lsof did not return data.").font(.system(size: 12)).foregroundStyle(Palette.fg2)
            case .value(let ports):
                if ports.isEmpty {
                    Text("No listening TCP ports.").font(.system(size: 12)).foregroundStyle(Palette.fg2)
                } else {
                    DisclosureGroup("\(ports.count) listening", isExpanded: $portsExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(ports.prefix(60)) { port in
                                HStack {
                                    Text(port.process).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text("\(port.address):\(port.port)").monospacedDigit().foregroundStyle(Palette.fg2)
                                }
                                .font(.system(size: 12))
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.system(size: 12))
                }
            }
        }
    }

    /// Unsupported API: "unavailable". Supported but no counter step yet: "waiting for update".
    private func powerText(_ pick: (PowerReading) -> Double?) -> String {
        switch live.power {
        case .pending:
            return "…"
        case .unavailable:
            return String(localized: "unavailable")
        case .value(let reading):
            guard let value = pick(reading) else { return String(localized: "waiting for update") }
            return "\(Format.number(value, digits: 2)) W"
        }
    }

    private func celsius(_ value: Double?, loaded: Bool) -> String {
        guard loaded else { return "…" }
        guard let value else { return String(localized: "unavailable") }
        return "\(Format.number(value, digits: 0)) °C"
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
