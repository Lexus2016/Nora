import AppKit

/// When quitting should ask first. Nora stops everything it started when it quits, so quitting during
/// a scan or a run loses the result and can leave a half-done change; the user is asked once.
///
/// It must not ask when the system is shutting down, restarting or logging out (answering "keep
/// working" there would hold up the whole Mac), nor when the quit is a SIGTERM sent from outside.
/// Two signals say the system is the one quitting: the reason on the quit Apple Event, and the
/// workspace's "will power off" notice. Either one is enough.
enum QuitGuard {
    /// The quit Apple Event's `why?` parameter (`kAEQuitReason`) and the values that mean the system is quitting every
    /// app (AERegistry.h: `kAEShutDown`, `kAERestart`, `kAEReallyLogOut`, `kAELogOut`).
    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
    static let reasonKey = code("why?")
    static let systemReasons: Set<FourCharCode> = [code("shut"), code("rest"), code("rlgo"), code("logo")]

    /// How long a "will power off" notice keeps the question away. A logout the user then cancels posts
    /// the same notice and no other, so the notice must not silence the question for the rest of the session.
    static let powerOffWindow: TimeInterval = 60

    static func isSystemInitiated(_ reasons: [FourCharCode]) -> Bool {
        reasons.contains(where: systemReasons.contains)
    }

    static func shouldAsk(hasRunningWork: Bool, unattended: Bool, reasons: [FourCharCode],
                          powerOffNoticedAt: Date? = nil, now: Date = Date()) -> Bool {
        guard hasRunningWork, !unattended, !isSystemInitiated(reasons) else { return false }
        if let noticed = powerOffNoticedAt, now.timeIntervalSince(noticed) < powerOffWindow { return false }
        return true
    }

    /// The reasons carried by an event. AERegistry.h defines `kAEQuitReason` as a *parameter* of the quit
    /// event; an attribute is read too, since both come back from the same descriptor API. The code
    /// arrives as an enumeration, as a type, or as the same four bytes in an integer; every reading is
    /// returned. An event without the parameter (⌘Q, the app menu, the Dock) gives none.
    static func reasons(in event: NSAppleEventDescriptor?) -> [FourCharCode] {
        let found = [event?.paramDescriptor(forKeyword: reasonKey), event?.attributeDescriptor(forKeyword: reasonKey)]
        return found.compactMap { $0 }.flatMap {
            [$0.enumCodeValue, $0.typeCodeValue, FourCharCode(truncatingIfNeeded: $0.int32Value)]
        }
    }

    /// The reasons carried by the quit event being handled right now.
    static func currentReasons() -> [FourCharCode] {
        reasons(in: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// The question. The default button, the one Return presses, keeps Nora working.
    @MainActor
    static func makeAlert(commands: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Nora is still working")
        var text = String(localized: "Quitting now stops it half way. Files already changed stay changed, and no result is shown.")
        if !commands.isEmpty {
            let shown = commands.prefix(3).map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }
            text += "\n\n" + shown.joined(separator: "\n") + (commands.count > shown.count ? "\n…" : "")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.addButton(withTitle: String(localized: "Stop and Quit"))
        return alert
    }

    /// True when the user chose to stop and quit.
    @MainActor
    static func confirmQuit(commands: [String]) -> Bool {
        NSApp.activate()
        return makeAlert(commands: commands).runModal() == .alertSecondButtonReturn
    }
}
