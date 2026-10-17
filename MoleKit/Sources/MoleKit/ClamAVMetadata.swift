import Foundation

/// Metadata only: parsing never scans files, downloads signatures, or upgrades packages.
public struct ClamAVVersionInfo: Equatable, Sendable {
    public let engine: String
    public let databaseVersion: String?
    public let databaseDate: Date?

    /// `clamscan --database <Nora database> --version`, with LC_ALL=C and TZ=UTC.
    /// The timestamp comes from the database header, not its filesystem modification time.
    public static func parse(_ output: String) -> Self? {
        let lines = output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("ClamAV ") }
        guard lines.count == 1, let line = lines.first else { return nil }
        let fields = line.dropFirst("ClamAV ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard let engine = fields.first.map(String.init), isVersion(engine), fields.count == 1 || fields.count == 3 else { return nil }
        var databaseVersion: String?
        var databaseDate: Date?
        if fields.count == 3, !fields[1].isEmpty, fields[1].allSatisfy(\.isNumber) {
            databaseVersion = String(fields[1])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            databaseDate = formatter.date(from: String(fields[2]))
        }
        return Self(engine: engine, databaseVersion: databaseVersion, databaseDate: databaseDate)
    }

    static func isVersion(_ value: String) -> Bool {
        !value.isEmpty && value.first?.isNumber == true && value.utf8.count <= 80
            && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_").contains($0) }
    }

    public enum Freshness: Equatable, Sendable { case missing, unknown, recent, old }

    /// A local age indication, never a claim that these are the newest available signatures.
    public static func freshness(hasDatabase: Bool, builtAt: Date?, now: Date) -> Freshness {
        guard hasDatabase else { return .missing }
        guard let builtAt, now.timeIntervalSince(builtAt) >= -300 else { return .unknown }
        return now.timeIntervalSince(builtAt) >= 48 * 3_600 ? .old : .recent
    }
}

/// Homebrew's checked catalog, which may itself be cached. Never call this a global latest version.
public struct ClamAVFormulaInfo: Equatable, Sendable {
    public let version: String
    public let revision: Int
    public let installedVersions: [String]
    public let outdated: Bool
    public let pinned: Bool
    public var packageVersion: String { revision == 0 ? version : "\(version)_\(revision)" }
    public var hasVerifiedPackage: Bool { installedVersions.contains(packageVersion) && !outdated }

    public static func parse(_ data: Data) throws -> Self {
        struct Root: Decodable { let formulae: [Formula] }
        struct Formula: Decodable {
            struct Versions: Decodable { let stable: String? }
            struct Installed: Decodable { let version: String }
            let name: String
            let versions: Versions
            let revision: Int
            let installed: [Installed]
            let outdated: Bool
            let pinned: Bool?
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard root.formulae.count == 1, let formula = root.formulae.first,
              formula.name == "clamav", let version = formula.versions.stable,
              ClamAVVersionInfo.isVersion(version), formula.revision >= 0,
              formula.installed.allSatisfy({ ClamAVVersionInfo.isVersion($0.version) }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid ClamAV formula metadata"))
        }
        return Self(version: version, revision: formula.revision,
                    installedVersions: formula.installed.map(\.version), outdated: formula.outdated,
                    pinned: formula.pinned ?? false)
    }

    public static let checkArguments = ["info", "--json=v2", "--formula", "clamav"]
    public static let upgradeArguments = ["upgrade", "--formula", "clamav"]
}
