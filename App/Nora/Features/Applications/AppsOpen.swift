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

    /// Opens the app again in the background, without taking focus. An app that installed its
    /// own update as it quit may still be swapping its bundle (Grok Bot's ShipIt did, a second
    /// after the quit), and a launch into that dies: so wait for the bundle to stay put, launch,
    /// and launch once more if it is not running a few seconds later.
    static func reopen(_ path: String) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for attempt in 0..<2 {
            guard await settled(path) else { return }
            _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
            try? await Task.sleep(for: .seconds(5))
            if running(at: path) != nil || attempt == 1 { return }
        }
    }

    /// True once the bundle exists and its Info.plist has not changed for 2 s; false after 30 s.
    private static func settled(_ path: String) async -> Bool {
        let plist = path + "/Contents/Info.plist"
        var last: Date?
        for _ in 0..<60 {
            let modified = (try? FileManager.default.attributesOfItem(atPath: plist)[.modificationDate]) as? Date
            if let modified, modified == last { return true }
            last = modified
            try? await Task.sleep(for: .seconds(modified == nil ? 0.5 : 2))
        }
        return false
    }
}
