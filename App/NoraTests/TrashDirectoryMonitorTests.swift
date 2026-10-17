import Foundation
import XCTest
@testable import Nora

@MainActor
final class TrashDirectoryMonitorTests: XCTestCase {
    /// The only filesystem fixture used by this app watcher test is an isolated temporary folder.
    func testRootProbeIgnoresNestedContentsAndDetectsReplacement() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("nora-trash-watch-\(UUID().uuidString)", isDirectory: true)
        let root = fixture.appendingPathComponent("fixture-trash", isDirectory: true)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("sample.txt")
        try Data("before".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let monitor = TrashDirectoryMonitor(root: root)
        monitor.start(onChange: {}, onWake: {})
        defer { monitor.stop() }
        XCTAssertFalse(monitor.sampleRoot())
        try Data("changed nested file".utf8).write(to: file)
        XCTAssertFalse(monitor.sampleRoot(), "The fallback probes the root only; subtree changes are FSEvents' responsibility")
        let old = fixture.appendingPathComponent("old-root", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: old)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(monitor.sampleRoot(), "Root identity replacement triggers rebind and a new bounded review")
        XCTAssertFalse(monitor.sampleRoot())
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(monitor.sampleRoot(), "Missing is an availability change, never a fabricated empty snapshot")
        XCTAssertFalse(monitor.sampleRoot())
    }
}
