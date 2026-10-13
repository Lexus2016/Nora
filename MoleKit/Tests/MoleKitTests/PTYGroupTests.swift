import Foundation
import Testing
@testable import MoleKit

struct PTYGroupTests {
    /// A leader that exits at once can leave a helper running in its group. The group counts as
    /// alive until the helper is gone, and terminate() stops the helper too.
    @Test func terminateStopsHelpersLeftByAnExitedLeader() throws {
        let session = try PTYSession(executable: "/bin/sh", arguments: ["-c", "(trap '' HUP; sleep 30) & exit 0"],
                                     environment: ["PATH": "/bin:/usr/bin"])
        _ = try session.waitForExit(timeout: 5)
        usleep(200_000)
        #expect(ChildProcesses.groupAlive(session.pid), "the helper keeps the group alive after the leader exits")
        session.terminate(grace: 2)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, ChildProcesses.groupAlive(session.pid) { usleep(50_000) }
        #expect(!ChildProcesses.groupAlive(session.pid))
    }
}
