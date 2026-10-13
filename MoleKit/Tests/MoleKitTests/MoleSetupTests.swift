import Foundation
import Testing
@testable import MoleKit

struct MoleSetupTests {
    /// The layout Mole's install.sh leaves behind: launcher in the prefix with SCRIPT_DIR pinned,
    /// lib/ in ~/.config/mole. Built with plain files; the real installer is not run.
    @Test func findsScriptInstallLayout() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/mole")
        let prefix = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("lib/core"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data().write(to: config.appendingPathComponent("lib/core/base.sh"))
        let launcher = "#!/bin/bash\nSCRIPT_DIR=\(config.path.replacingOccurrences(of: " ", with: "\\ "))\nexec bash\n"
        try Data(launcher.utf8).write(to: prefix.appendingPathComponent("mole"))
        try Data("#!/bin/bash\nexec \"$(dirname \"$0\")/mole\" \"$@\"\n".utf8).write(to: prefix.appendingPathComponent("mo"))

        let installation = try MoleInstallation(executable: prefix.appendingPathComponent("mo"))
        #expect(installation.root.standardizedFileURL.path == config.standardizedFileURL.path)
        #expect(MoleInstallation.pinnedScriptDir(prefix.appendingPathComponent("mole"))?.path == config.path)
    }

    /// The script channel creates the prefix, downloads the pinned installer, checks its hash and
    /// only then runs it with the pinned version.
    @Test func scriptInstallIsPinnedAndVerified() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let commands = MoleSetup.installCommands(.script, home: home)
        #expect(commands.map(\.executable) == ["/bin/mkdir", "/usr/bin/curl", "/bin/sh", "/bin/bash"])
        #expect(commands[0].arguments == ["-p", "/Users/someone/.local/bin"])
        #expect(commands[1].arguments.last == "https://raw.githubusercontent.com/tw93/Mole/V1.59.1/install.sh")
        #expect(commands[2].arguments[1].contains(MoleSetup.installScriptSHA256))
        #expect(commands[3].arguments.suffix(3) == ["--prefix", "/Users/someone/.local/bin", "1.59.1"])
    }
}
