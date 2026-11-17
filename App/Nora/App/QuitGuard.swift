import AppKit

/// When quitting should ask first. Nora stops everything it started when it quits, so quitting during
/// a scan or a run loses the result and can leave a half-done change; the user is asked once.
///
/// It must not ask when the system is shutting down, restarting or logging out (answering "keep
/// working" there would hold up the whole Mac), nor when the quit is a SIGTERM sent from outside.
enum QuitGuard {
    /// The quit Apple Event's `why?` parameter and the values that mean the system is quitting every
    /// app (AERegistry.h: `kAEShutDown`, `kAERestart`, `kAEReallyLogOut`, `kAELogOut`).
    private static func code(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
    static let reasonKey = code("why?")
    static let systemReasons: Set<FourCharCode> = [code("shut"), code("rest"), code("rlgo"), code("logo")]

    static func isSystemInitiated(_ reasons: [FourCharCode]) -> Bool {
        reasons.contains(where: systemReasons.contains)
    }

    static func shouldAsk(hasRunningWork: Bool, unattended: Bool, reasons: [FourCharCode]) -> Bool {
        hasRunningWork && !unattended && !isSystemInitiated(reasons)
    }

    /// The reasons carried by the quit event being handled right now. Empty for ⌘Q, the app menu and
    /// the Dock, which send none.
    static func currentReasons() -> [FourCharCode] {
        guard let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: reasonKey) else {
            return []
        }
        // The value arrives as a four-character code, or as the same four bytes in an integer.
        return [reason.enumCodeValue, FourCharCode(truncatingIfNeeded: reason.int32Value)]
    }
}
