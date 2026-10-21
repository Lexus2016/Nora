import Foundation
import MoleKit

/// Injectable boundary: regression tests never execute brew, clamscan or freshclam.
@MainActor
struct ClamAVManagementServices {
    var locate: () -> ClamAVTools = { ClamAVTools.locate() }
    var brew: () -> URL? = { BrewTools.brew }
    var isHomebrewManaged: (URL, URL) -> Bool = { clamscan, brew in
        let prefix = brew.deletingLastPathComponent().deletingLastPathComponent()
        return clamscan.resolvingSymlinksInPath().path.hasPrefix(prefix.appendingPathComponent("Cellar/clamav").path + "/")
    }
    var run: (ShellCommand, [String: String], TimeInterval?) async throws -> CommandResult = { command, environment, timeout in
        if let timeout {
            return try await ProcessRunner.probe(URL(fileURLWithPath: command.executable), command.arguments,
                                                  environment: environment, timeout: timeout)
        }
        return try await ProcessRunner.run(URL(fileURLWithPath: command.executable), command.arguments,
                                            environment: environment)
    }
    var now: () -> Date = { Date() }
    /// Asked when the Downloads watch starts. Tests replace it so no system prompt appears.
    var requestNotifications: () -> Void = { SecurityNotifier.requestAuthorization() }
}
