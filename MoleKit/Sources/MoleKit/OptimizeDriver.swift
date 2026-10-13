import Foundation

/// Answers the one interactive question `mo optimize` (Mole 1.59) can ask in a terminal:
/// "Detach now? Enter confirm / Space cancel" about mounted disk images while syspolicyd is busy.
/// Nora never detaches anything on its own, so it answers Space (keep them mounted) and lets the
/// run go on. Without an answer the command would wait until its timeout.
public struct OptimizeDriver {
    public static let detachPrompt = "Detach now?"
    public var timeout: TimeInterval = 1800

    public init() {}

    /// Runs until the command exits. Returns how many detach questions it declined.
    public func run(in session: PTYSession) throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var declined = 0
        while session.exitStatus == nil {
            guard Date() < deadline else { throw PTYError(description: "timed out after \(Int(timeout)) s") }
            // An answered prompt stays on screen, so only a new one raises the count.
            if Self.prompts(in: session.lines) > declined {
                session.send(.space)
                declined += 1
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return declined
    }

    static func prompts(in lines: [String]) -> Int {
        lines.filter { $0.contains(detachPrompt) }.count
    }
}
