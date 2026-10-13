import Foundation

/// One launchd plist and the program it starts.
struct LaunchItem: Identifiable, Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case userAgent, systemAgent, systemDaemon
    }

    var id: String { plistPath }
    let label: String
    let plistPath: String
    let scope: Scope
    /// `Program`, or `ProgramArguments[0]` when `Program` is absent.
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    let binaryExists: Bool
    /// Nil when there is no program or the binary is missing.
    let signature: CodeSignature?

    var commandLine: String {
        ((program.map { [$0] } ?? []) + arguments).joined(separator: " ")
    }
}

/// Why a launch item needs a look. Each case has a plain sentence for the UI.
enum LaunchReason: String, Sendable, Equatable, CaseIterable {
    case missingBinary, unsigned, invalidSignature, unreadableSignature
    case inTemporaryFolder, inSharedFolder, inHiddenFolder
    case pipesIntoShell, decodesBase64, runsOsascript

    var text: String {
        switch self {
        case .missingBinary: String(localized: "The program file is missing.")
        case .unsigned: String(localized: "The program is not code signed.")
        case .invalidSignature: String(localized: "The code signature is invalid.")
        case .unreadableSignature: String(localized: "The code signature could not be read.")
        case .inTemporaryFolder: String(localized: "The program runs from a temporary folder.")
        case .inSharedFolder: String(localized: "The program runs from /Users/Shared.")
        case .inHiddenFolder: String(localized: "The program sits in a hidden folder.")
        case .pipesIntoShell: String(localized: "The arguments pipe curl or wget into a shell.")
        case .decodesBase64: String(localized: "The arguments decode base64.")
        case .runsOsascript: String(localized: "The arguments run osascript (AppleScript).")
        }
    }
}

/// Read-only audit of launchd plists. Nothing here loads, unloads or edits a file.
enum LaunchAudit {
    struct Directory: Sendable {
        let url: URL
        let scope: LaunchItem.Scope
    }

    struct Report: Sendable {
        var items: [LaunchItem] = []
        /// File names of plists that could not be parsed.
        var unreadable: [String] = []
    }

    static var defaultDirectories: [Directory] {
        [Directory(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                   scope: .userAgent),
         Directory(url: URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), scope: .systemAgent),
         Directory(url: URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), scope: .systemDaemon)]
    }

    /// Reads and checks every plist. Signature checks take time, so this runs off the main actor.
    static func scan(_ directories: [Directory]) async -> Report {
        await Task.detached(priority: .utility) { scanSync(directories) }.value
    }

    static func scanSync(_ directories: [Directory]) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        for directory in directories {
            let files = (try? fileManager.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "plist" {
                if let item = inspect(file, scope: directory.scope) {
                    report.items.append(item)
                } else {
                    report.unreadable.append(file.lastPathComponent)
                }
            }
        }
        return report
    }

    /// Parses one plist and checks its program. Returns nil when the plist is not a dictionary.
    static func inspect(_ plist: URL, scope: LaunchItem.Scope) -> LaunchItem? {
        guard let data = try? Data(contentsOf: plist),
              let dictionary = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        let arguments = dictionary["ProgramArguments"] as? [String] ?? []
        let program = (dictionary["Program"] as? String) ?? arguments.first
        let label = (dictionary["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
        let keepAlive: Bool
        if let flag = dictionary["KeepAlive"] as? Bool {
            keepAlive = flag
        } else {
            keepAlive = dictionary["KeepAlive"] is [String: Any]
        }
        var binaryExists = false
        var signature: CodeSignature?
        if let program, FileManager.default.fileExists(atPath: program) {
            binaryExists = true
            signature = CodeSigning.check(URL(fileURLWithPath: program))
        }
        return LaunchItem(label: label, plistPath: plist.path, scope: scope, program: program, arguments: arguments,
                          runAtLoad: dictionary["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
                          binaryExists: binaryExists, signature: signature)
    }

    /// The reasons an item needs a look. Apple-signed items and anything under /System are never flagged.
    static func reasons(for item: LaunchItem) -> [LaunchReason] {
        guard let program = item.program else { return [] }
        if item.signature == .apple || program.hasPrefix("/System/") { return [] }

        var reasons: [LaunchReason] = []
        if !item.binaryExists { reasons.append(.missingBinary) }
        switch item.signature {
        case .unsigned: reasons.append(.unsigned)
        case .invalid: reasons.append(.invalidSignature)
        case .unreadable: reasons.append(.unreadableSignature)
        case .apple, .signed, .none: break
        }

        if program.hasPrefix("/tmp/") || program.hasPrefix("/private/tmp/") { reasons.append(.inTemporaryFolder) }
        if program.hasPrefix("/Users/Shared/") { reasons.append(.inSharedFolder) }
        let folders = (program as NSString).deletingLastPathComponent.split(separator: "/")
        if folders.contains(where: { $0.hasPrefix(".") }) { reasons.append(.inHiddenFolder) }

        let commandLine = item.commandLine
        if commandLine.range(of: #"(curl|wget)\b[^|]*\|\s*(sudo\s+)?(/\S*/)?(ba|z|da|k)?sh\b"#,
                             options: [.regularExpression, .caseInsensitive]) != nil {
            reasons.append(.pipesIntoShell)
        }
        if commandLine.range(of: #"base64\b.*(\s-d\b|\s-D\b|--decode\b)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            reasons.append(.decodesBase64)
        }
        if commandLine.range(of: #"\bosascript\b"#, options: .regularExpression) != nil {
            reasons.append(.runsOsascript)
        }
        return reasons
    }
}
