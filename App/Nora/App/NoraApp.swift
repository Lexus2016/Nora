import SwiftUI

@main
struct NoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Nora", id: "main") {
            RootView()
                .environment(delegate.app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.app)
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private var menuBar: MenuBarController?
    private var scheduler: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.prepare()
        _ = Updater.shared
        Task {
            await app.locate()
            menuBar = MenuBarController(app: app)
            app.security.resumeWatchIfEnabled(app)
        }
        // Scheduled security scans: the app has no launchd helper, so a timer asks every 15 min.
        scheduler = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let app = self?.app, app.mole != nil else { return }
                app.security.tick(app)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let identifier = (note.object as? NSWindow)?.identifier?.rawValue
            MainActor.assumeIsolated {
                guard identifier == "main" else { return }
                // With the menu bar item on, Nora keeps running there without a Dock icon.
                if UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.showMain(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.security.shutdown()
        try? app.overlay.recoverIfNeeded()
    }
}
