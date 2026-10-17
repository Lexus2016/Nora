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
    /// Unit-test hosts must not start schedulers, update checks, recovery, or real scanners.
    private var isUnitTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["NORA_UNIT_TESTING"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }
    private var menuBar: MenuBarController?
    private var trashPrompt: TrashPromptController?
    private var waitingForTrashTermination = false
    private var scheduler: Timer?
    private var startupTask: Task<Void, Never>?
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        // Launching Nora always shows its window. With the system's "keep windows when quitting"
        // on, a window closed before quitting would otherwise stay closed and leave only the menu
        // bar item. Set in Nora's own domain, so other apps keep the system setting.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        // SIGTERM (Activity Monitor's Quit, logout, pkill) goes through the normal quit, so
        // applicationWillTerminate stops Nora's child processes instead of orphaning them.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        terminationSignal = term
        app.prepare()
        trashPrompt = TrashPromptController(model: app.trash, openNora: { [weak self] in self?.app.showSettings() })
        _ = Updater.shared
        startupTask = Task {
            await app.trash.checkRecovery()
            guard !Task.isCancelled else { return }
            app.trash.start()
            await app.security.reapOrphanedScanners()
            guard !Task.isCancelled else { return }
            await app.locate()
            guard !Task.isCancelled else { return }
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
            let windowID = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let windowID,
                      NSApp.windows.first(where: { ObjectIdentifier($0) == windowID })?.identifier?.rawValue == "main" else { return }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isUnitTestHost else { return .terminateNow }
        guard !waitingForTrashTermination else { return .terminateLater }
        startupTask?.cancel()
        let needsSettlement = app.trash.isWorking
        app.trash.shutdown()
        guard needsSettlement else { return .terminateNow }
        waitingForTrashTermination = true
        Task { @MainActor in
            await app.trash.waitUntilSettled()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        startupTask?.cancel()
        app.trash.shutdown()
        trashPrompt?.shutdown()
        app.security.shutdown()
        // Children first, and only once they are gone: Mole must not read the whitelist while
        // it is being put back. If one survives, the overlay stays until the next launch.
        if ChildProcesses.terminateAllAndWait() {
            // No registered child does not prove a detached protection worker has finished:
            // it may be between loading defaults and applying its overlay. Preserve the
            // journal during an exclusive operation. This in-memory barrier does not prove
            // settlement of a surviving helper across a later application launch.
            if !app.exclusiveRunActive { try? app.recoverProtection() }
            app.handover.recover()
        }
    }
}
