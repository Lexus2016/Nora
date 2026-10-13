import Foundation

// Read-only hardware sensors through private Apple frameworks, resolved with dlopen/dlsym.
// Nothing here writes to the system. A missing framework or symbol, a NULL return, or a value
// outside the plausible range gives `nil` ("unavailable"), never a guessed number.

struct PowerReading: Sendable, Equatable {
    var cpu: Double?
    var gpu: Double?
    var ane: Double?

    static let unavailable = PowerReading(cpu: nil, gpu: nil, ane: nil)

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

    static func group(_ values: [Double]) -> TemperatureGroup? {
        guard !values.isEmpty else { return nil }
        return TemperatureGroup(average: values.reduce(0, +) / Double(values.count),
                                max: values.max() ?? 0,
                                sensors: values.count)
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
    typealias CreateSamplesDelta = @convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?
    typealias ChannelString = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    typealias SimpleInteger = @convention(c) (UnsafeRawPointer, Int32) -> Int64

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelName: ChannelString
    let unitLabel: ChannelString
    let simpleInteger: SimpleInteger

    static func load() -> IOReportAPI? {
        guard let handle = openFramework("/usr/lib/libIOReport.dylib") else { return nil }
        guard let copy = resolve(handle, "IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let subscribe = resolve(handle, "IOReportCreateSubscription", CreateSubscription.self),
              let samples = resolve(handle, "IOReportCreateSamples", CreateSamples.self),
              let delta = resolve(handle, "IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let name = resolve(handle, "IOReportChannelGetChannelName", ChannelString.self),
              let unit = resolve(handle, "IOReportChannelGetUnitLabel", ChannelString.self),
              let integer = resolve(handle, "IOReportSimpleGetIntegerValue", SimpleInteger.self)
        else { return nil }
        return IOReportAPI(copyChannelsInGroup: copy, createSubscription: subscribe, createSamples: samples,
                           createSamplesDelta: delta, channelName: name, unitLabel: unit, simpleInteger: integer)
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

/// Two IOReport samples turned into CPU, GPU and ANE watts. Keeps its subscription and the
/// last sample between polls, so a poll costs one sample.
actor PowerSampler {
    private let api: IOReportAPI?
    private var subscription: UnsafeRawPointer?
    private var channels: UnsafeRawPointer?
    private var previous: (sample: NSDictionary, uptime: UInt64)?

    /// A baseline older than this is discarded, so the watts never average over a long gap.
    private static let maxGap: UInt64 = 5_000_000_000

    init() {
        api = IOReportAPI.load()
    }

    func read() async -> PowerReading {
        guard let api, ensureSubscription(api) else { return .unavailable }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous, now &- previous.uptime <= Self.maxGap {
            // Baseline from the last poll.
        } else {
            guard let first = takeSample(api) else { return .unavailable }
            previous = first
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let base = previous, let current = takeSample(api) else {
            previous = nil
            return .unavailable
        }
        previous = current
        guard let delta = owned(api.createSamplesDelta(rawPointer(base.sample), rawPointer(current.sample), nil), NSDictionary.self) else {
            return .unavailable
        }
        let seconds = Double(current.uptime &- base.uptime) / 1_000_000_000
        return Self.reading(from: channelList(api, delta), seconds: seconds)
    }

    /// Pure, so it can be tested: sums per component and drops a component if any of its channels is unreadable.
    /// CPU counters that do not move at all over the window are reported as unavailable: a powered
    /// CPU always draws some power, so zero joules means a stuck counter, not an idle chip.
    /// GPU and ANE can legitimately be 0 W, so zero stays a number for them.
    static func reading(from channels: [EnergyChannel], seconds: Double) -> PowerReading {
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
        func watts(_ component: SensorMath.PowerComponent) -> Double? {
            guard !broken.contains(component), let j = joules[component] else { return nil }
            if component == .cpu, j == 0 { return nil }
            return SensorMath.watts(joules: j, seconds: seconds)
        }
        return PowerReading(cpu: watts(.cpu), gpu: watts(.gpu), ane: watts(.ane))
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

    private func channelList(_ api: IOReportAPI, _ delta: NSDictionary) -> [EnergyChannel] {
        guard let items = delta["IOReportChannels"] as? NSArray else { return [] }
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
        // The same sensor name is published by more than one service; average its readings
        // first, so a duplicate does not count twice in the group average.
        var perName: [String: [Double]] = [:]
        var kinds: [String: SensorMath.TemperatureKind] = [:]
        for index in 0..<services.count {
            let service = services[index] as AnyObject
            let pointer = rawPointer(service)
            guard let name = owned(api.copyProperty(pointer, rawPointer("Product" as CFString)), CFString.self) as String?,
                  let kind = SensorMath.temperatureKind(for: name),
                  let value = temperature(api, pointer), SensorMath.isPlausibleCelsius(value) else { continue }
            perName[name, default: []].append(value)
            kinds[name] = kind
        }
        var cpu: [Double] = []
        var gpu: [Double] = []
        for (name, values) in perName {
            let mean = values.reduce(0, +) / Double(values.count)
            switch kinds[name] {
            case .cpu: cpu.append(mean)
            case .gpu: gpu.append(mean)
            case nil: continue
            }
        }
        return TemperatureReading(cpu: SensorMath.group(cpu), gpu: SensorMath.group(gpu))
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
