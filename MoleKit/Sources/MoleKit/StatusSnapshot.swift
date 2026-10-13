import Foundation

/// One `mo status --json` snapshot. Every field is optional and decoded leniently: a missing
/// key or a changed type becomes `nil` instead of failing the whole snapshot (MangelSP's
/// dashboard went blank on a single missing field).
public struct StatusSnapshot: Decodable, Sendable {
    public var collectedAt: String?
    public var host: String?
    public var uptime: String?
    public var processCount: Int?
    public var hardware: Hardware?
    public var healthScore: Int?
    public var healthMessage: String?
    public var cpu: CPU?
    public var gpu: [GPU]
    public var memory: Memory?
    public var disks: [Disk]
    public var trashSize: Int64?
    public var diskIO: DiskIO?
    public var network: [Interface]
    public var proxy: Proxy?
    public var batteries: [Battery]
    public var thermal: Thermal?
    public var bluetooth: [BluetoothDevice]
    public var topProcesses: [ProcessInfo]
    public var processStale: Bool?
    public var zombieCount: Int?
    public var processAlerts: [ProcessAlert]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at", host, uptime, procs, hardware
        case healthScore = "health_score", healthMessage = "health_score_msg"
        case cpu, gpu, memory, disks, trashSize = "trash_size", diskIO = "disk_io", network, proxy
        case batteries, thermal, bluetooth, topProcesses = "top_processes", processStale = "process_stale"
        case zombieCount = "zombie_count", processAlerts = "process_alerts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collectedAt = c.lenient(.collectedAt)
        host = c.lenient(.host)
        uptime = c.lenient(.uptime)
        processCount = c.lenientInt(.procs)
        hardware = c.lenient(.hardware)
        healthScore = c.lenientInt(.healthScore)
        healthMessage = c.lenient(.healthMessage)
        cpu = c.lenient(.cpu)
        gpu = c.lenientArray(.gpu)
        memory = c.lenient(.memory)
        disks = c.lenientArray(.disks)
        trashSize = c.lenientInt64(.trashSize)
        diskIO = c.lenient(.diskIO)
        network = c.lenientArray(.network)
        proxy = c.lenient(.proxy)
        batteries = c.lenientArray(.batteries)
        thermal = c.lenient(.thermal)
        bluetooth = c.lenientArray(.bluetooth)
        topProcesses = c.lenientArray(.topProcesses)
        processStale = c.lenient(.processStale)
        zombieCount = c.lenientInt(.zombieCount)
        processAlerts = c.lenientArray(.processAlerts)
    }

    public static func decode(_ data: Data) throws -> StatusSnapshot {
        try JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    public struct Hardware: Decodable, Sendable {
        public var model, cpuModel, totalRAM, diskSize, osVersion: String?
        enum CodingKeys: String, CodingKey { case model, cpuModel = "cpu_model", totalRAM = "total_ram", diskSize = "disk_size", osVersion = "os_version" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = c.lenient(.model); cpuModel = c.lenient(.cpuModel); totalRAM = c.lenient(.totalRAM)
            diskSize = c.lenient(.diskSize); osVersion = c.lenient(.osVersion)
        }
    }

    public struct CPU: Decodable, Sendable {
        public var usage: Double?
        public var perCore: [Double]
        public var load1, load5, load15: Double?
        public var coreCount, performanceCores, efficiencyCores: Int?
        enum CodingKeys: String, CodingKey {
            case usage, perCore = "per_core", load1, load5, load15, coreCount = "core_count"
            case performanceCores = "p_core_count", efficiencyCores = "e_core_count"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usage = c.lenient(.usage); perCore = c.lenientArray(.perCore)
            load1 = c.lenient(.load1); load5 = c.lenient(.load5); load15 = c.lenient(.load15)
            coreCount = c.lenientInt(.coreCount); performanceCores = c.lenientInt(.performanceCores); efficiencyCores = c.lenientInt(.efficiencyCores)
        }
    }

    public struct GPU: Decodable, Sendable {
        public var name: String?
        /// Percent, or `nil` when Mole reports -1 (not measurable).
        public var usage: Double?
        public var coreCount: Int?
        enum CodingKeys: String, CodingKey { case name, usage, coreCount = "core_count" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(.name); coreCount = c.lenientInt(.coreCount)
            let raw: Double? = c.lenient(.usage)
            usage = raw.flatMap { $0 < 0 ? nil : $0 }
        }
    }

    public struct Memory: Decodable, Sendable {
        public var used, total, available, swapUsed, swapTotal, cached: Int64?
        public var usedPercent: Double?
        public var pressure: String?
        enum CodingKeys: String, CodingKey {
            case used, total, available, swapUsed = "swap_used", swapTotal = "swap_total", cached
            case usedPercent = "used_percent", pressure
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used = c.lenientInt64(.used); total = c.lenientInt64(.total); available = c.lenientInt64(.available)
            swapUsed = c.lenientInt64(.swapUsed); swapTotal = c.lenientInt64(.swapTotal); cached = c.lenientInt64(.cached)
            usedPercent = c.lenient(.usedPercent)
            let p: String? = c.lenient(.pressure)
            pressure = p?.isEmpty == true ? nil : p
        }
    }

    public struct Disk: Decodable, Sendable, Identifiable {
        public var mount, device, fsType, smartStatus: String?
        public var used, total: Int64?
        public var usedPercent: Double?
        public var external: Bool?
        public var id: String { mount ?? device ?? "?" }
        enum CodingKeys: String, CodingKey {
            case mount, device, fsType = "fstype", smartStatus = "smart_status", used, total, usedPercent = "used_percent", external
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mount = c.lenient(.mount); device = c.lenient(.device); fsType = c.lenient(.fsType); smartStatus = c.lenient(.smartStatus)
            used = c.lenientInt64(.used); total = c.lenientInt64(.total); usedPercent = c.lenient(.usedPercent); external = c.lenient(.external)
        }
    }

    public struct DiskIO: Decodable, Sendable {
        /// Bytes per second.
        public var readRate, writeRate: Double?
        enum CodingKeys: String, CodingKey { case readRate = "read_rate", writeRate = "write_rate" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            readRate = c.lenient(.readRate); writeRate = c.lenient(.writeRate)
        }
    }

    public struct Interface: Decodable, Sendable, Identifiable {
        public var name, ip: String?
        /// Megabytes per second.
        public var rxRate, txRate: Double?
        public var id: String { name ?? "?" }
        enum CodingKeys: String, CodingKey { case name, ip, rxRate = "rx_rate_mbs", txRate = "tx_rate_mbs" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(.name); ip = c.lenient(.ip); rxRate = c.lenient(.rxRate); txRate = c.lenient(.txRate)
        }
    }

    public struct Proxy: Decodable, Sendable {
        public var enabled: Bool?
        public var type, host: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.lenient(.enabled); type = c.lenient(.type); host = c.lenient(.host)
        }
        enum CodingKeys: String, CodingKey { case enabled, type, host }
    }

    public struct Battery: Decodable, Sendable {
        public var percent, cycleCount, capacity: Int?
        public var status, timeLeft, health: String?
        enum CodingKeys: String, CodingKey { case percent, cycleCount = "cycle_count", capacity, status, timeLeft = "time_left", health }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            percent = c.lenientInt(.percent); cycleCount = c.lenientInt(.cycleCount); capacity = c.lenientInt(.capacity)
            status = c.lenient(.status); timeLeft = c.lenient(.timeLeft); health = c.lenient(.health)
        }
    }

    public struct Thermal: Decodable, Sendable {
        /// Degrees Celsius; `nil` when Mole reports 0 (sensor not readable).
        public var cpuTemp, gpuTemp, batteryTemp: Double?
        public var fanSpeed, fanCount: Int?
        /// Watts.
        public var systemPower, adapterPower, batteryPower: Double?
        enum CodingKeys: String, CodingKey {
            case cpuTemp = "cpu_temp", gpuTemp = "gpu_temp", batteryTemp = "battery_temp", fanSpeed = "fan_speed", fanCount = "fan_count"
            case systemPower = "system_power", adapterPower = "adapter_power", batteryPower = "battery_power"
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func positive(_ k: CodingKeys) -> Double? { let v: Double? = c.lenient(k); return v.flatMap { $0 > 0 ? $0 : nil } }
            cpuTemp = positive(.cpuTemp); gpuTemp = positive(.gpuTemp); batteryTemp = positive(.batteryTemp)
            fanSpeed = c.lenientInt(.fanSpeed); fanCount = c.lenientInt(.fanCount)
            systemPower = positive(.systemPower); adapterPower = positive(.adapterPower); batteryPower = positive(.batteryPower)
        }
    }

    public struct BluetoothDevice: Decodable, Sendable, Identifiable {
        public var name, battery: String?
        public var connected: Bool?
        public var id: String { name ?? "?" }
        enum CodingKeys: String, CodingKey { case name, battery, connected }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = c.lenient(.name); connected = c.lenient(.connected)
            let b: String? = c.lenient(.battery)
            battery = b?.isEmpty == true ? nil : b
        }
    }

    public struct ProcessInfo: Decodable, Sendable, Identifiable {
        public var pid, ppid: Int?
        public var name, command: String?
        public var cpu: Double?
        public var memoryBytes: Int64?
        public var id: Int { pid ?? 0 }
        enum CodingKeys: String, CodingKey { case pid, ppid, name, command, cpu, memoryBytes = "memory_bytes" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = c.lenientInt(.pid); ppid = c.lenientInt(.ppid); name = c.lenient(.name); command = c.lenient(.command)
            cpu = c.lenient(.cpu); memoryBytes = c.lenientInt64(.memoryBytes)
        }
    }

    public struct ProcessAlert: Decodable, Sendable, Identifiable {
        public var pid: Int?
        public var name, window, status, triggeredAt: String?
        public var cpu, threshold: Double?
        public var id: String { "\(pid ?? 0)-\(triggeredAt ?? "")" }
        enum CodingKeys: String, CodingKey { case pid, name, window, status, triggeredAt = "triggered_at", cpu, threshold }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pid = c.lenientInt(.pid); name = c.lenient(.name); window = c.lenient(.window); status = c.lenient(.status)
            triggeredAt = c.lenient(.triggeredAt); cpu = c.lenient(.cpu); threshold = c.lenient(.threshold)
        }
    }
}

/// `mo status --watch --interval N` as an async sequence of snapshots. Lines that fail to
/// decode are skipped, not fatal.
public enum StatusStream {
    public static func snapshots(_ mole: Mole, interval: Int = 1) -> AsyncThrowingStream<StatusSnapshot, Error> {
        let lines = ProcessRunner.lines(mole.executable, ["status", "--watch", "--interval", "\(interval)s"], environment: mole.environment)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines where !line.isError {
                        guard line.text.first == "{", let data = line.text.data(using: .utf8),
                              let snapshot = try? StatusSnapshot.decode(data) else { continue }
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension KeyedDecodingContainer {
    func lenient<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Integers that Mole may emit as floats in another version.
    func lenientInt(_ key: Key) -> Int? {
        if let v: Int = lenient(key) { return v }
        if let d: Double = lenient(key), d.isFinite { return Int(d) }
        return nil
    }

    func lenientInt64(_ key: Key) -> Int64? {
        if let v: Int64 = lenient(key) { return v }
        if let d: Double = lenient(key), d.isFinite { return Int64(d) }
        return nil
    }

    /// An array whose broken elements are dropped individually.
    func lenientArray<T: Decodable>(_ key: Key) -> [T] {
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !nested.isAtEnd {
            if let value = try? nested.decode(T.self) { result.append(value) }
            else { _ = try? nested.decode(Skip.self) }
        }
        return result
    }
}

/// Accepts any JSON value without reading it, so the unkeyed container always advances.
private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}
