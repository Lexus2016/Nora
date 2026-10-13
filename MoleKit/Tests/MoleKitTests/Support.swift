import Foundation

enum TestSandbox {
    /// A fresh directory standing in for `$HOME`, as a canonical (`/private/var/...`) path.
    static func make(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nora-\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func writeRandom(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).write(to: url)
    }
}

/// Tests that run the real `mo` are opt-in: `NORA_MOLE_E2E=1 swift test`.
/// They only ever run Mole against a sandbox `$HOME`, never with sudo.
enum MoleE2E {
    static var executable: URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["NORA_MO"], "/opt/homebrew/bin/mo", "/usr/local/bin/mo"].compactMap { $0 }
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["NORA_MOLE_E2E"] == "1" && executable != nil
    }

    /// The child's whole environment. No SUDO_*, no USER: nothing that points back at the real home.
    /// `noAuth` sets Mole's own test switch, which skips sudo and the System Events
    /// login-item AppleScript that `mo uninstall` would otherwise run (an Automation prompt).
    static func environment(home: URL, noAuth: Bool = false) -> [String: String] {
        var environment = [
            "HOME": home.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "TMPDIR": home.appendingPathComponent("tmp").path + "/",
        ]
        if noAuth { environment["MOLE_TEST_NO_AUTH"] = "1" }
        return environment
    }

    /// Writes a transcript with the sandbox path replaced, when `NORA_RECORD_FIXTURES=1`.
    static func recordFixture(_ bytes: [UInt8], name: String, version: String, home: URL) throws {
        guard ProcessInfo.processInfo.environment["NORA_RECORD_FIXTURES"] == "1" else { return }
        var text = String(decoding: bytes, as: UTF8.self)
        for form in [home.path, home.path.replacingOccurrences(of: "/private/var/", with: "/var/")] {
            text = text.replacingOccurrences(of: form, with: "$SANDBOX")
        }
        let url = Fixtures.directory(version: version).appendingPathComponent(name)
        try TestSandbox.write(text, to: url)
    }
}

enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func directory(version: String) -> URL {
        root.appendingPathComponent(version)
    }

    static func all(named name: String) -> [URL] {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return versions.sorted().map { directory(version: $0).appendingPathComponent(name) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum SpikeBinary {
    /// The `molekit-spike` helper built next to the test bundle.
    static var url: URL? {
        if let path = ProcessInfo.processInfo.environment["NORA_SPIKE_BIN"] {
            return URL(fileURLWithPath: path)
        }
        let fromBundles = Bundle.allBundles
            .filter { $0.bundlePath.hasSuffix(".xctest") }
            .map { $0.bundleURL.deletingLastPathComponent().appendingPathComponent("molekit-spike") }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fromBuildDir = packageRoot.appendingPathComponent(".build/debug/molekit-spike")
        return (fromBundles + [fromBuildDir]).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
