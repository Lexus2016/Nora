import MoleKit
import SwiftUI

@main
struct NoraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Nora", id: "main") {
            RootView()
                .environment(delegate.app)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1040, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Self.defaultWindowSize)
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

    /// 1240 × 800 where it fits; on smaller screens the window starts inside the visible area
    /// (menu bar and Dock excluded) instead of running under the Dock. Never below the 620 pt minimum.
    static var defaultWindowSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 875)
        return CGSize(width: min(1240, max(1040, (visible.width * 0.92).rounded())), height: min(800, max(620, (visible.height * 0.9).rounded())))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppModel()
    private var menuBar: MenuBarController?
    private var scheduler: Timer?
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Launching Nora always shows its window. With the system's "keep windows when quitting"
        // on, a window closed before quitting would otherwise stay closed and leave only the menu
        // bar item. Set in Nora's own domain, so other apps keep the system setting.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM (Activity Monitor's Quit, logout, pkill) goes through the normal quit, so
        // applicationWillTerminate stops Nora's child processes instead of orphaning them.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        terminationSignal = term
        app.prepare()
        _ = Updater.shared
        Task {
            await app.security.reapOrphanedScanners()
            await app.locate()
            menuBar = MenuBarController(app: app)
            app.security.resumeWatchIfEnabled(app)
            #if DEBUG
            // Screenshot helpers: -NoraShowPopover 1 opens the quick menu, -NoraShowSettings 1 the Settings window.
            if UserDefaults.standard.bool(forKey: "NoraShowPopover") {
                try? await Task.sleep(for: .seconds(1.5))
                menuBar?.toggle()
            }
            if UserDefaults.standard.bool(forKey: "NoraShowSettings") {
                try? await Task.sleep(for: .seconds(1.5))
                app.showSettings()
            }
            #endif
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
        // Children first, and only once they are gone: Mole must not read the whitelist while
        // it is being put back.
        ChildProcesses.terminateAllAndWait()
        try? app.overlay.recoverIfNeeded()
    }
}
