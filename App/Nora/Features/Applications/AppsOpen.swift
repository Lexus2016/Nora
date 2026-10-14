import AppKit

/// Apps that are open while an update would replace them. Nora quits them the way their own Quit
/// command does, so each one can ask to save first, updates them, and opens them again.
@MainActor
enum OpenApps {
    /// The running app whose bundle is at this path.
    static func running(at path: String) -> NSRunningApplication? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == target }
    }

    /// Asks the app to quit and waits for it. An app still open after 2 s is probably asking to save,
    /// so it comes to the front, where that question can be seen. False when it is still open after
    /// `timeout`, for example because its user cancelled the save sheet.
    static func quit(_ app: NSRunningApplication, timeout: Duration = .seconds(60)) async -> Bool {
        guard !app.isTerminated else { return true }
        app.terminate()
        let start = ContinuousClock.now
        var shown = false
        while !app.isTerminated, ContinuousClock.now < start + timeout {
            if !shown, ContinuousClock.now > start + .seconds(2) {
                app.activate()
                shown = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return app.isTerminated
    }

    /// Opens the app again in the background, without taking focus.
    static func reopen(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
    }
}
