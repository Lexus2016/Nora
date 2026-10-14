import Foundation

// Read-only hardware sensors through private Apple frameworks, resolved with dlopen/dlsym.
// Nothing here writes to the system. A missing framework or symbol, a NULL return, or a value
// outside the plausible range gives `nil` ("unavailable"), never a guessed number.

struct PowerReading: Sendable, Equatable {
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    /// False when the IOReport API or its subscription is missing. A nil component on a supported
    /// reading only means that its counter has not stepped yet.
    var supported = true

    static let unavailable = PowerReading(cpu: nil, gpu: nil, ane: nil, supported: false)

    var hasAny: Bool { cpu != nil || gpu != nil || ane != nil }

    /// Only when all three components are known: a total without the CPU would understate the power.
    var total: Double? {
        guard let cpu, let gpu, let ane else { return nil }
        return cpu + gpu + ane
    }
}

struct TemperatureGroup: Sendable, Equatable {
    let average: Double
    let max: Double
    let sensors: Int
}

struct TemperatureReading: Sendable, Equatable {
    var cpu: TemperatureGroup?
    var gpu: TemperatureGroup?

    static let unavailable = TemperatureReading(cpu: nil, gpu: nil)

    var hasAny: Bool { cpu != nil || gpu != nil }
}

/// How hot the CPU runs, for the menu bar dot. Apple silicon sits near 90 °C under sustained
/// load and slows itself down above 100 °C, so red means hot, not merely busy.
enum HeatLevel: Equatable, Sendable {
    case normal, warm, hot

    static let warmFrom = 70.0
    static let hotFrom = 90.0

    init(celsius: Double) {
        self = celsius >= Self.hotFrom ? .hot : celsius >= Self.warmFrom ? .warm : .normal
    }
}

/// One channel of the IOReport "Energy Model" group, already read out of a delta sample.
struct EnergyChannel: Sendable, Equatable {
    let name: String
    let unit: String
    let value: Int64
}

/// Pure conversions, kept separate from the C calls so they can be tested.
enum SensorMath {
    enum PowerComponent: Sendable, Equatable { case cpu, gpu, ane }
    enum TemperatureKind: Sendable, Equatable { case cpu, gpu }

    static func powerComponent(for channel: String) -> PowerComponent? {
        switch channel {
        case "CPU Energy": return .cpu
        case "GPU Energy": return .gpu
        default: return channel.hasPrefix("ANE") ? .ane : nil
        }
    }

    /// Joules for an IOReport energy value. Unknown units return nil.
    static func joules(_ value: Int64, unit: String) -> Double? {
        let scale: Double
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "J": scale = 1
        case "mJ": scale = 1e-3
        case "uJ", "µJ": scale = 1e-6
        case "nJ": scale = 1e-9
        default: return nil
        }
        guard value >= 0 else { return nil }
        return Double(value) * scale
    }

    /// Average power over `seconds`. Rejects windows that are too short or results above 500 W.
    static func watts(joules: Double, seconds: Double) -> Double? {
        guard seconds >= 0.2, joules.isFinite, joules >= 0 else { return nil }
        let watts = joules / seconds
        guard watts.isFinite, watts <= 500 else { return nil }
        return watts
    }

    static func temperatureKind(for sensor: String) -> TemperatureKind? {
        if sensor.localizedCaseInsensitiveContains("GPU") { return .gpu }
        if sensor.contains("tdie") || sensor.contains("pACC") || sensor.contains("eACC") { return .cpu }
        return nil
    }

    /// Plausible die temperature in °C. The HID sensor reports 0 or garbage when it is not ready.
    static func isPlausibleCelsius(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= 150
    }

    /// `means` holds one value per sensor name. `rawMax` is the hottest raw reading of the group.
    static func group(means: [Double], rawMax: Double?) -> TemperatureGroup? {
        guard !means.isEmpty, let rawMax else { return nil }
        return TemperatureGroup(average: means.reduce(0, +) / Double(means.count),
                                max: rawMax,
                                sensors: means.count)
    }
}

// MARK: - C symbol access

private func rawPointer(_ object: AnyObject) -> UnsafeRawPointer {
    UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
}

private func owned<T: AnyObject>(_ pointer: UnsafeRawPointer?, _: T.Type) -> T? {
    pointer.map { Unmanaged<T>.fromOpaque($0).takeRetainedValue() }
}

private func borrowed<T: AnyObject>(_ pointer: UnsafeRawPointer?, _: T.Type) -> T? {
    pointer.map { Unmanaged<T>.fromOpaque($0).takeUnretainedValue() }
}

private func resolve<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) -> T? {
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
}

private func openFramework(_ path: String) -> UnsafeMutableRawPointer? {
    dlopen(path, RTLD_NOW)
}

/// IOReport: the energy counters that macmon reads. Only the calls used here are resolved.
private struct IOReportAPI {
    typealias CopyChannelsInGroup = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeRawPointer?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>?, UInt64, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias CreateSamples = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias ChannelString = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias SimpleInteger = @convention(c) (UnsafeRawPointer, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let channelName: ChannelString
    let unitLabel: ChannelString
    let simpleInteger: SimpleInteger

    static func load() -> IOReportAPI? {
        guard let handle = openFramework("/usr/lib/libIOReport.dylib") else { return nil }
        guard let copy = resolve(handle, "IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let subscribe = resolve(handle, "IOReportCreateSubscription", CreateSubscription.self),
              let samples = resolve(handle, "IOReportCreateSamples", CreateSamples.self),
              let name = resolve(handle, "IOReportChannelGetChannelName", ChannelString.self),
              let unit = resolve(handle, "IOReportChannelGetUnitLabel", ChannelString.self),
              let integer = resolve(handle, "IOReportSimpleGetIntegerValue", SimpleInteger.self)
        else { return nil }
        return IOReportAPI(copyChannelsInGroup: copy, createSubscription: subscribe, createSamples: samples,
                           channelName: name, unitLabel: unit, simpleInteger: integer)
    }
}

/// AppleHID temperature sensors (private IOHIDEventSystemClient API).
private struct HIDAPI {
    typealias CreateClient = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias SetMatching = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    typealias CopyServices = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias CopyProperty = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?
    typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeRawPointer?
    typealias FloatValue = @convention(c) (UnsafeRawPointer, Int32) -> Double

    let createClient: CreateClient
    let setMatching: SetMatching
    let copyServices: CopyServices
    let copyProperty: CopyProperty
    let copyEvent: CopyEvent
    let floatValue: FloatValue

    static func load() -> HIDAPI? {
        guard let handle = openFramework("/System/Library/Frameworks/IOKit.framework/IOKit") else { return nil }
        guard let create = resolve(handle, "IOHIDEventSystemClientCreate", CreateClient.self),
              let matching = resolve(handle, "IOHIDEventSystemClientSetMatching", SetMatching.self),
              let services = resolve(handle, "IOHIDEventSystemClientCopyServices", CopyServices.self),
              let property = resolve(handle, "IOHIDServiceClientCopyProperty", CopyProperty.self),
              let event = resolve(handle, "IOHIDServiceClientCopyEvent", CopyEvent.self),
              let value = resolve(handle, "IOHIDEventGetFloatValue", FloatValue.self)
        else { return nil }
        return HIDAPI(createClient: create, setMatching: matching, copyServices: services,
                      copyProperty: property, copyEvent: event, floatValue: value)
    }
}

// MARK: - Power

/// Power from one cumulative energy counter that updates in steps, not continuously.
/// Watts are the energy added between two observed steps, divided by the time between them.
/// The first step has no start time, so it gives nil; the first watts appear at the second step.
struct StepCounterPower: Sendable, Equatable {
    private struct Point: Sendable, Equatable {
        let joules: Double
        let uptime: UInt64
    }

    private var last: Point?
    private var hasPriorStep = false
    private var watts: Double?
    private var stepAt: UInt64?

    mutating func observe(joules: Double, uptime: UInt64) {
        guard let previous = last, joules >= previous.joules else {
            // First sample, or the counter went backwards: start over from this sample.
            self = StepCounterPower()
            last = Point(joules: joules, uptime: uptime)
            return
        }
        guard joules > previous.joules else { return } // no step since the last poll
        if hasPriorStep, uptime > previous.uptime {
            watts = SensorMath.watts(joules: joules - previous.joules,
                                     seconds: Double(uptime - previous.uptime) / 1_000_000_000)
        } else {
            watts = nil
        }
        hasPriorStep = true
        stepAt = uptime
        last = Point(joules: joules, uptime: uptime)
    }

    /// The watts from the latest step pair, or nil when that step is older than `maxAge` (nanoseconds).
    func current(at uptime: UInt64, maxAge: UInt64) -> Double? {
        guard let watts, let stepAt, uptime >= stepAt, uptime - stepAt <= maxAge else { return nil }
        return watts
    }
}

/// Reads the IOReport "Energy Model" counters on every poll. The subscription is kept for the
/// life of the sampler. Each component's counter is tracked by `StepCounterPower`.
actor PowerSampler {
    private let api: IOReportAPI?
    private var subscription: UnsafeRawPointer?
    private var channels: UnsafeRawPointer?
    private var counters: [SensorMath.PowerComponent: StepCounterPower] = [:]

    /// Watts from a counter that has not stepped for this long are reported as unavailable.
    /// On the Mac where this was measured, CPU Energy stepped once in about 200 s of sampling and
    /// its step covered about 3.7 kJ, so the window is long on purpose.
    static let maxStepAge: UInt64 = 900_000_000_000

    init() {
        api = IOReportAPI.load()
    }

    func read() -> PowerReading {
        guard let api, ensureSubscription(api), let sample = takeSample(api) else { return .unavailable }
        for (component, joules) in Self.energyTotals(channelList(api, sample.sample)) {
            var counter = counters[component] ?? StepCounterPower()
            counter.observe(joules: joules, uptime: sample.uptime)
            counters[component] = counter
        }
        return PowerReading(
            cpu: counters[.cpu]?.current(at: sample.uptime, maxAge: Self.maxStepAge),
            gpu: counters[.gpu]?.current(at: sample.uptime, maxAge: Self.maxStepAge),
            ane: counters[.ane]?.current(at: sample.uptime, maxAge: Self.maxStepAge),
            supported: true
        )
    }

    /// Cumulative joules per component. A component with any unreadable channel is left out,
    /// so its counter is not advanced with a partial sum.
    static func energyTotals(_ channels: [EnergyChannel]) -> [SensorMath.PowerComponent: Double] {
        var joules: [SensorMath.PowerComponent: Double] = [:]
        var broken: Set<SensorMath.PowerComponent> = []
        for channel in channels {
            guard let component = SensorMath.powerComponent(for: channel.name) else { continue }
            guard let j = SensorMath.joules(channel.value, unit: channel.unit) else {
                broken.insert(component)
                continue
            }
            joules[component, default: 0] += j
        }
        return joules.filter { !broken.contains($0.key) }
    }

    private func ensureSubscription(_ api: IOReportAPI) -> Bool {
        if subscription != nil, channels != nil { return true }
        let group = "Energy Model" as CFString
        guard let found = owned(api.copyChannelsInGroup(rawPointer(group), nil, 0, 0, 0), CFDictionary.self),
              let mutable = CFDictionaryCreateMutableCopy(nil, 0, found) else { return false }
        var subscribed: UnsafeRawPointer?
        guard let sub = api.createSubscription(nil, rawPointer(mutable), &subscribed, 0, nil) else { return false }
        subscription = sub
        channels = subscribed ?? rawPointer(mutable)
        return true
    }

    private func takeSample(_ api: IOReportAPI) -> (sample: NSDictionary, uptime: UInt64)? {
        guard let subscription, let channels,
              let sample = owned(api.createSamples(subscription, channels, nil), NSDictionary.self) else { return nil }
        return (sample, DispatchTime.now().uptimeNanoseconds)
    }

    private func channelList(_ api: IOReportAPI, _ sample: NSDictionary) -> [EnergyChannel] {
        guard let items = sample["IOReportChannels"] as? NSArray else { return [] }
        var result: [EnergyChannel] = []
        for index in 0..<items.count {
            guard let item = items[index] as? NSDictionary else { continue }
            let pointer = rawPointer(item)
            guard let name = borrowed(api.channelName(pointer), CFString.self) as String?,
                  let unit = borrowed(api.unitLabel(pointer), CFString.self) as String? else { continue }
            result.append(EnergyChannel(name: name, unit: unit, value: api.simpleInteger(pointer, 0)))
        }
        return result
    }
}

// MARK: - Temperatures

/// HID temperature sensors, grouped into CPU and GPU. Read once per poll.
actor TemperatureSampler {
    private let api: HIDAPI?
    private var client: UnsafeRawPointer?

    init() {
        api = HIDAPI.load()
    }

    func read() -> TemperatureReading {
        guard let api, let client = ensureClient(api) else { return .unavailable }
        guard let services = owned(api.copyServices(client), NSArray.self) else { return .unavailable }
        // The same sensor name is published by more than one service. Averages are taken per name,
        // so a duplicate does not count twice; the max is over every raw reading, so no peak is lost.
        var perName: [String: [Double]] = [:]
        var kinds: [String: SensorMath.TemperatureKind] = [:]
        var rawMax: [SensorMath.TemperatureKind: Double] = [:]
        for index in 0..<services.count {
            let service = services[index] as AnyObject
            let pointer = rawPointer(service)
            guard let name = owned(api.copyProperty(pointer, rawPointer("Product" as CFString)), CFString.self) as String?,
                  let kind = SensorMath.temperatureKind(for: name),
                  let value = temperature(api, pointer), SensorMath.isPlausibleCelsius(value) else { continue }
            perName[name, default: []].append(value)
            kinds[name] = kind
            rawMax[kind] = max(rawMax[kind] ?? value, value)
        }
        var cpuMeans: [Double] = []
        var gpuMeans: [Double] = []
        for (name, values) in perName {
            let mean = values.reduce(0, +) / Double(values.count)
            switch kinds[name] {
            case .cpu: cpuMeans.append(mean)
            case .gpu: gpuMeans.append(mean)
            case nil: continue
            }
        }
        return TemperatureReading(
            cpu: SensorMath.group(means: cpuMeans, rawMax: rawMax[.cpu]),
            gpu: SensorMath.group(means: gpuMeans, rawMax: rawMax[.gpu])
        )
    }

    private func ensureClient(_ api: HIDAPI) -> UnsafeRawPointer? {
        if let client { return client }
        guard let created = api.createClient(nil) else { return nil }
        // The return code is not checked: the call reports non-zero even when the matching works.
        // Missing sensors show up as an empty service list instead.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as NSDictionary
        _ = api.setMatching(created, rawPointer(matching))
        client = created
        return created
    }

    private func temperature(_ api: HIDAPI, _ service: UnsafeRawPointer) -> Double? {
        // kIOHIDEventTypeTemperature = 15, field = type << 16
        guard let event = owned(api.copyEvent(service, 15, 0, 0), NSObject.self) else { return nil }
        return api.floatValue(rawPointer(event), 15 << 16)
    }
}
