import Foundation
import MoleKit
import Observation

/// One live metric: not measured yet, measured, or the source failed on this Mac.
enum Probe<Value: Sendable & Equatable>: Sendable, Equatable {
    case pending
    case value(Value)
    case unavailable

    var reading: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    /// False only while the first sample is still running.
    var isLoaded: Bool {
        if case .pending = self { return false }
        return true
    }
}

/// Live readings for the System Status screen. Polling runs only between `start` and `stop`,
/// which the view calls from onAppear and onDisappear. Nothing here changes the system except
/// `apply()`, which runs only after the user clicks Apply.
@MainActor @Observable
final class LiveStatus {
    private(set) var power: Probe<PowerReading> = .pending
    private(set) var temperatures: Probe<TemperatureReading> = .pending
    private(set) var energy: Probe<EnergyModeState> = .pending
    private(set) var ports: Probe<[ListeningPort]> = .pending
    private(set) var traffic: Probe<TrafficReport> = .pending

    /// The mode the user picked and has not applied yet. Nothing changes until Apply.
    private(set) var pendingMode: EnergyMode?
    private(set) var isApplying = false
    private(set) var applyMessage: String?

    @ObservationIgnored private let powerSampler = PowerSampler()
    @ObservationIgnored private let temperatureSampler = TemperatureSampler()
    @ObservationIgnored private var sensorTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var home: URL?
    @ObservationIgnored private var askpass: URL?

    /// Sensor readings every 2 s, and lsof plus nettop every 5 s, both only while visible.
    static let sensorInterval: Duration = .seconds(2)
    static let networkInterval: Duration = .seconds(5)

    func start(home: URL, askpass: URL) {
        self.home = home
        self.askpass = askpass
        if sensorTask == nil {
            sensorTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let power = await self.powerSampler.read()
                    let temps = await self.temperatureSampler.read()
                    guard !Task.isCancelled else { return }
                    self.power = power.supported ? .value(power) : .unavailable
                    self.temperatures = temps.hasAny ? .value(temps) : .unavailable
                    try? await Task.sleep(for: Self.sensorInterval)
                }
            }
        }
        if networkTask == nil {
            networkTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let ports = await PortsAndTrafficSampler.listeningPorts()
                    let traffic = await PortsAndTrafficSampler.traffic()
                    guard !Task.isCancelled else { return }
                    self.ports = ports.map { .value($0) } ?? .unavailable
                    self.traffic = traffic.map { .value($0) } ?? .unavailable
                    try? await Task.sleep(for: Self.networkInterval)
                }
            }
        }
        // Read once per appearance, not on a timer: the mode only changes on Apply or in System Settings.
        Task { await refreshEnergy() }
    }

    func stop() {
        sensorTask?.cancel()
        sensorTask = nil
        networkTask?.cancel()
        networkTask = nil
    }

    /// Re-reads `pmset -g`. Runs on start and after every Apply, never on a timer.
    func refreshEnergy() async {
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: EnergyModeCommand.pmset),
            ["-g"],
            environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        ), result.status == 0, let state = EnergyModeParser.parse(result.stdout) else {
            energy = .unavailable
            return
        }
        energy = .value(state)
    }

    /// Picking a segment only records the choice. Choosing the current mode clears it.
    func choose(_ mode: EnergyMode) {
        applyMessage = nil
        guard case .value(let state) = energy, state.offered.contains(mode), mode != state.current else {
            pendingMode = nil
            return
        }
        pendingMode = mode
    }

    func cancelPending() {
        pendingMode = nil
        applyMessage = nil
    }

    /// The exact command the Apply button will run, or nil when nothing is pending.
    var pendingCommand: String? {
        guard let pendingMode, case .value(let state) = energy else { return nil }
        return EnergyModeCommand.displayed(for: pendingMode, key: state.key)
    }

    /// Runs `sudo -A /usr/bin/pmset -a ...` in a PTY with the Nora askpass helper. Called only from the Apply button.
    func apply() async {
        guard let pendingMode, case .value(let state) = energy,
              let invocation = EnergyModeCommand.invocation(for: pendingMode, key: state.key),
              let home, let askpass else { return }
        isApplying = true
        applyMessage = nil
        defer { isApplying = false }
        let environment = PrivilegeBroker.environment(Mole.environment(home: home), askpass: askpass)
        do {
            let result = try await PTYRun.run(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: environment,
                sudo: true
            )
            if result.succeeded {
                self.pendingMode = nil
            } else {
                let last = result.text.split(separator: "\n").last.map(String.init) ?? ""
                applyMessage = last.isEmpty ? "The mode did not change." : last
            }
        } catch {
            applyMessage = error.localizedDescription
        }
        await refreshEnergy()
    }
}
