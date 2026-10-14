import XCTest
@testable import Nora

/// S1: a file is known by its version, so a name reused for a new download is checked again.
@MainActor
final class DownloadsWatchTests: XCTestCase {
    func testANameReusedForANewFileIsHandedOverAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("old".utf8).write(to: dir.appendingPathComponent("present.zip"))

        var ready: [String] = []
        let watch = DownloadsWatch(directory: dir) { ready.append($0.lastPathComponent) }
        try watch.start()
        defer { watch.stop() }

        func wait(for count: Int) async throws {
            for _ in 0..<100 where ready.count < count { try await Task.sleep(for: .milliseconds(100)) }
        }
        let sample = dir.appendingPathComponent("sample.zip")
        try Data("first".utf8).write(to: sample)
        try await wait(for: 1)
        XCTAssertEqual(ready, ["sample.zip"], "a file present at the start is not scanned")

        try FileManager.default.removeItem(at: sample)
        try Data("second, longer".utf8).write(to: sample)
        try await wait(for: 2)
        XCTAssertEqual(ready, ["sample.zip", "sample.zip"], "the new file under the same name is checked")

        // An atomic replace of a file that was there at the start is a new arrival too.
        try Data("replaced".utf8).write(to: dir.appendingPathComponent("present.zip"), options: .atomic)
        try await wait(for: 3)
        XCTAssertEqual(ready.last, "present.zip")
    }
}
