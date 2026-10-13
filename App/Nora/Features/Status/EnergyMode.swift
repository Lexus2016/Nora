import Foundation

/// The Energy Mode pop-up from System Settings, as `pmset` stores it.
enum EnergyMode: Sendable, Equatable, CaseIterable {
    case low, automatic, high
}

/// What `pmset -g` says about the energy mode on this Mac.
struct EnergyModeState: Sendable, Equatable {
    /// Which `pmset` key carries the setting. `powermode` is newer and has three values.
    enum Key: Sendable, Equatable {
        case powerMode
        case lowPowerMode
    }

    let key: Key
    /// nil when the key exists but holds a value Nora does not know.
    let current: EnergyMode?

    /// High Power is offered only where the Mac reports a `powermode` key.
    var offered: [EnergyMode] {
        key == .powerMode ? [.low, .automatic, .high] : [.low, .automatic]
    }
}

enum EnergyModeParser {
    /// Parses `pmset -g`. Returns nil when neither key is present (for example on a Mac where
    /// pmset does not report energy modes at all).
    static func parse(_ output: String) -> EnergyModeState? {
        let values = firstValues(output, keys: ["powermode", "lowpowermode"])
        if let raw = values["powermode"] {
            return EnergyModeState(key: .powerMode, current: powerMode(raw))
        }
        if let raw = values["lowpowermode"] {
            return EnergyModeState(key: .lowPowerMode, current: lowPowerMode(raw))
        }
        return nil
    }

    /// Value for each key, taken from its first line. `pmset -g` prints one line per setting,
    /// as "<key> <value>" after leading spaces.
    static func firstValues(_ output: String, keys: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let key = String(parts[0])
            guard keys.contains(key), found[key] == nil else { continue }
            found[key] = String(parts[1])
        }
        return found
    }

    /// powermode: 0 Low Power, 1 Automatic, 2 High Power.
    static func powerMode(_ raw: String) -> EnergyMode? {
        switch raw {
        case "0": return .low
        case "1": return .automatic
        case "2": return .high
        default: return nil
        }
    }

    /// lowpowermode: 1 is Low Power, 0 is Automatic.
    static func lowPowerMode(_ raw: String) -> EnergyMode? {
        switch raw {
        case "1": return .low
        case "0": return .automatic
        default: return nil
        }
    }
}

enum EnergyModeCommand {
    static let pmset = "/usr/bin/pmset"
    static let sudo = "/usr/bin/sudo"

    /// The `pmset` arguments that set `mode` for the given key, or nil if that mode does not exist for it.
    static func pmsetArguments(for mode: EnergyMode, key: EnergyModeState.Key) -> [String]? {
        switch (key, mode) {
        case (.powerMode, .low): return ["-a", "powermode", "0"]
        case (.powerMode, .automatic): return ["-a", "powermode", "1"]
        case (.powerMode, .high): return ["-a", "powermode", "2"]
        case (.lowPowerMode, .low): return ["-a", "lowpowermode", "1"]
        case (.lowPowerMode, .automatic): return ["-a", "lowpowermode", "0"]
        case (.lowPowerMode, .high): return nil
        }
    }

    /// The command the user sees, as typed in a shell.
    static func displayed(for mode: EnergyMode, key: EnergyModeState.Key) -> String? {
        guard let args = pmsetArguments(for: mode, key: key) else { return nil }
        return (["sudo", pmset] + args).joined(separator: " ")
    }

    /// What `PTYRun` executes. `pmset` writes need root, and `PrivilegeBroker.wrap` only validates
    /// the sudo credential, so the privileged `pmset` is started through `sudo -A` in the same PTY.
    static func invocation(for mode: EnergyMode, key: EnergyModeState.Key) -> (executable: String, arguments: [String])? {
        guard let args = pmsetArguments(for: mode, key: key) else { return nil }
        return (sudo, ["-A", pmset] + args)
    }
}
