import Foundation
import XCTest
@testable import MoleKit

final class OverlayConflictRegressionTests: XCTestCase {
    private func sandbox() throws -> (URL, WhitelistOverlay) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nora-overlay-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (home, WhitelistOverlay(home: home, journalURL: home.appendingPathComponent("support/journal.json")))
    }

    func testExternalEditAndJournalSurviveRecoveryConflict() throws {
        let (home, overlay) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        try overlay.apply(protecting: ["/synthetic/protected"], defaults: [], runID: "fixture")
        let edited = Data("/synthetic/external-edit\n".utf8)
        try edited.write(to: overlay.whitelistURL)
        XCTAssertThrowsError(try overlay.recover(runID: "fixture")) { error in
            XCTAssertEqual(error as? WhitelistOverlayError, .conflictingChanges(overlay.whitelistURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: overlay.whitelistURL), edited)
        XCTAssertTrue(overlay.needsRecovery)
        XCTAssertThrowsError(try overlay.apply(protecting: [], defaults: [], runID: "next"))
    }

    func testCrashBeforeApplyAndAfterRestoreAreRecoverable() throws {
        for original: Data? in [nil, Data("/synthetic/original\n".utf8)] {
            let (home, overlay) = try sandbox()
            defer { try? FileManager.default.removeItem(at: home) }
            if let original {
                try FileManager.default.createDirectory(at: overlay.whitelistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try original.write(to: overlay.whitelistURL)
            }
            let journal = WhitelistOverlay.Journal(runID: "fixture", whitelistPath: overlay.whitelistURL.path,
                originalContents: original, createdAt: Date(), appliedContents: Data("overlay bytes".utf8))
            try WhitelistOverlay.writeDurably(JSONEncoder().encode(journal), to: overlay.journalURL)
            try overlay.recoverIfNeeded()
            XCTAssertFalse(overlay.needsRecovery)
            XCTAssertEqual(try? Data(contentsOf: overlay.whitelistURL), original)
        }
    }

    func testOldJournalWithoutAppliedBytesRemainsReadable() throws {
        let (home, overlay) = try sandbox()
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = WhitelistOverlay.Journal(runID: "legacy", whitelistPath: overlay.whitelistURL.path,
                                               originalContents: nil, createdAt: Date())
        try WhitelistOverlay.writeDurably(JSONEncoder().encode(journal), to: overlay.journalURL)
        try overlay.recoverIfNeeded()
        XCTAssertFalse(overlay.needsRecovery)
    }
}
