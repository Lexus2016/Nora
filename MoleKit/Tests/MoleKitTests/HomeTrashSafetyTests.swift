import CPTYShim
import Darwin
import Foundation
import XCTest
@testable import MoleKit

/// Every service uses an explicitly generated fixture home. These tests never instantiate the
/// production initializer, inspect the real home Trash, invoke Mole, or request administrator access.
final class HomeTrashSafetyTests: XCTestCase {
    private final class Fixture {
        let home: URL
        var trash: URL { home.appendingPathComponent(".Trash", isDirectory: true) }
        var recovery: URL { home.appendingPathComponent("Library/Application Support/Nora/TrashRecovery", isDirectory: true) }
        init() throws {
            // Resolve the EXISTING parent first. Foundation can leave /var -> /private/var
            // unresolved when resolving a URL whose UUID descendant does not exist yet.
            // Production correctly rejects every symlink component, so fixtures must use
            // the physical temporary path rather than weakening that no-follow contract.
            guard let physicalParent = realpath(FileManager.default.temporaryDirectory.path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "Cannot resolve the existing temporary fixture parent"])
            }
            defer { free(physicalParent) }
            home = URL(fileURLWithPath: String(cString: physicalParent), isDirectory: true)
                .appendingPathComponent("nora-trash-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            let fixtureRoot = try TrashFS.open(home)
            XCTAssertEqual(try TrashFS.identity(fixtureRoot).type, .directory,
                           "The generated fixture must pass the production no-follow root open")
            _ = try TrashFS.open(".Trash", in: fixtureRoot)
        }
        deinit { try? FileManager.default.removeItem(at: home) }
        func file(_ path: String, _ text: String = "fixture", under root: URL? = nil) throws {
            let url = (root ?? trash).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func exists(_ path: String, under root: URL? = nil) -> Bool {
            FileManager.default.fileExists(atPath: (root ?? trash).appendingPathComponent(path).path)
        }
        func text(_ path: String, under root: URL? = nil) throws -> String {
            try String(contentsOf: (root ?? trash).appendingPathComponent(path), encoding: .utf8)
        }
        func batch() throws -> URL {
            let names = try FileManager.default.contentsOfDirectory(atPath: recovery.path)
            let name = try XCTUnwrap(names.first(where: { $0.hasPrefix("run-") }))
            return recovery.appendingPathComponent(name, isDirectory: true)
        }
        func service(limits: TrashScanLimits = TrashScanLimits(),
                     hook: @escaping (TrashTransition) throws -> Void = { _ in }) -> HomeTrashService {
            HomeTrashService(fixtureHome: home, limits: limits, transition: hook)
        }
    }

    func testCompleteManifestIncludesHiddenFilesAndSymlinksAsLeaves() throws {
        let fixture = try Fixture()
        try fixture.file(".hidden", "abc")
        try fixture.file("folder/inside", "12345")
        try fixture.file("outside/untouched", "outside", under: fixture.home)
        try FileManager.default.createSymbolicLink(at: fixture.trash.appendingPathComponent("link"),
                                                    withDestinationURL: fixture.home.appendingPathComponent("outside"))
        let service = fixture.service()
        let snapshot = try service.scan()
        XCTAssertEqual(snapshot.entries.map(\.relativePath), [".hidden", "folder", "folder/inside", "link"])
        XCTAssertEqual(snapshot.topLevelItemCount, 3)
        XCTAssertEqual(snapshot.entryCount, 4)
        XCTAssertEqual(snapshot.entries.last?.type, .symbolicLink)
        XCTAssertTrue(snapshot.matchesContents(of: try service.scan()))
        let result = service.execute(snapshot)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.deletedEntryCount, 4)
        XCTAssertEqual(try fixture.text("outside/untouched", under: fixture.home), "outside")
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
    }

    func testMissingAndSymlinkTrashAreUnavailableNotEmpty() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.trash)
        XCTAssertThrowsError(try fixture.service().scan())
        try FileManager.default.createDirectory(at: fixture.home.appendingPathComponent("outside"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.trash, withDestinationURL: fixture.home.appendingPathComponent("outside"))
        XCTAssertThrowsError(try fixture.service().scan())
    }

    func testBoundedPartialAndCancelledScansDoNotProduceSnapshots() throws {
        let fixture = try Fixture()
        try fixture.file("folder/one")
        var limits = TrashScanLimits()
        limits.maximumEntries = 1
        XCTAssertThrowsError(try fixture.service(limits: limits).scan())
        limits = TrashScanLimits()
        limits.maximumDepth = 0
        XCTAssertThrowsError(try fixture.service(limits: limits).scan())
        limits = TrashScanLimits()
        limits.timeout = 0
        XCTAssertThrowsError(try fixture.service(limits: limits).scan())
        XCTAssertThrowsError(try fixture.service { event in
            if event == .scanning("folder") { throw TrashSafetyError.io("injected permission error") }
        }.scan())
        let cancellation = TrashCancellationToken()
        cancellation.cancel()
        XCTAssertThrowsError(try fixture.service().scan(cancellation: cancellation))
        XCTAssertTrue(fixture.exists("folder/one"))
    }

    func testModifiedSnapshotRequiresNewReviewBeforeAnyMove() throws {
        let fixture = try Fixture()
        try fixture.file("item", "old")
        let service = fixture.service()
        let snapshot = try service.scan()
        try fixture.file("item", "different contents")
        XCTAssertEqual(service.execute(snapshot).status, .requiresNewReview)
        XCTAssertEqual(try fixture.text("item"), "different contents")
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
    }

    func testNewRootArrivalDuringStagingIsNeverAddedToBatch() throws {
        let fixture = try Fixture()
        try fixture.file("reviewed")
        let service = fixture.service { event in
            if event == .afterStage(0) { try fixture.file("new-arrival", "keep") }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertEqual(try fixture.text("new-arrival"), "keep")
    }

    func testUnexpectedNestedArrivalBeforeValidationStopsAllDeletion() throws {
        let fixture = try Fixture()
        try fixture.file("folder/reviewed")
        let service = fixture.service { event in
            if event == .afterStage(0) { try fixture.file("items/item-0/new-arrival", "keep", under: fixture.batch()) }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .requiresNewReview)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertTrue(fixture.exists("folder/reviewed"))
        XCTAssertEqual(try fixture.text("folder/new-arrival"), "keep")
    }

    func testSameNameReplacementBeforeStagingIsNotDeleted() throws {
        let fixture = try Fixture()
        try fixture.file("item", "old")
        let service = fixture.service { event in
            if event == .beforeStage(0) {
                try FileManager.default.moveItem(at: fixture.trash.appendingPathComponent("item"),
                                                to: fixture.home.appendingPathComponent("original"))
                try fixture.file("item", "replacement")
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .requiresNewReview)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertEqual(try fixture.text("item"), "replacement")
        XCTAssertEqual(try fixture.text("original", under: fixture.home), "old")
    }

    func testHeldParentReplacementDoesNotDeleteThroughStaleDescriptor() throws {
        let fixture = try Fixture()
        try fixture.file("folder/leaf", "original")
        let service = fixture.service { event in
            if event == .beforeCapture(1) {
                let batch = try fixture.batch()
                try FileManager.default.moveItem(at: batch.appendingPathComponent("items/item-0"),
                                                to: fixture.home.appendingPathComponent("held-parent"))
                try fixture.file("items/item-0/leaf", "replacement", under: batch)
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertEqual(try fixture.text("held-parent/leaf", under: fixture.home), "original")
        XCTAssertEqual(try fixture.text("items/item-0/leaf", under: fixture.batch()), "replacement")
    }

    func testNestedSymlinkSwapCannotReachOutsideTarget() throws {
        let fixture = try Fixture()
        try fixture.file("folder/leaf")
        try fixture.file("outside", "keep", under: fixture.home)
        let service = fixture.service { event in
            if event == .beforeCapture(1) {
                let leaf = try fixture.batch().appendingPathComponent("items/item-0/leaf")
                try FileManager.default.moveItem(at: leaf, to: fixture.home.appendingPathComponent("saved-leaf"))
                try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: fixture.home.appendingPathComponent("outside"))
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .requiresNewReview)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertEqual(try fixture.text("outside", under: fixture.home), "keep")
        XCTAssertTrue(fixture.exists("saved-leaf", under: fixture.home))
    }

    func testCapturedCandidateReplacementIsPreservedAndBlocksNewRuns() throws {
        let fixture = try Fixture()
        try fixture.file("item", "original")
        let service = fixture.service { event in
            if event == .afterCapture(0) {
                let candidate = try fixture.batch().appendingPathComponent("candidates/entry-0")
                try FileManager.default.moveItem(at: candidate, to: fixture.home.appendingPathComponent("saved-original"))
                try Data("replacement".utf8).write(to: candidate)
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertEqual(try fixture.text("candidates/entry-0", under: fixture.batch()), "replacement")
        XCTAssertEqual(try fixture.text("saved-original", under: fixture.home), "original")
        XCTAssertTrue(fixture.service().recoveryStatus().blocksNewRun)
        XCTAssertTrue(fixture.service().recover().blocksNewRun)
    }

    func testNoOverwriteMoveFailureHasNoRecursiveOrCopyDeleteFallback() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if event == .beforeStage(0) { throw TrashSafetyError.io("injected ENOTSUP from exclusive rename") }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertTrue(fixture.exists("item"))
    }

    func testCancellationAfterCaptureRestoresTheCandidate() throws {
        let fixture = try Fixture()
        try fixture.file("folder/leaf")
        let cancellation = TrashCancellationToken()
        let service = fixture.service { event in
            if event == .afterCapture(1) { cancellation.cancel() }
        }
        let result = service.execute(try service.scan(), cancellation: cancellation)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertTrue(fixture.exists("folder/leaf"))
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
    }

    func testRestoreCollisionPreservesBothVersionsAndGatesNextRun() throws {
        let fixture = try Fixture()
        try fixture.file("item", "original")
        let cancellation = TrashCancellationToken()
        let service = fixture.service { event in
            if event == .afterStage(0) {
                try fixture.file("item", "new arrival")
                cancellation.cancel()
            }
        }
        let result = service.execute(try service.scan(), cancellation: cancellation)
        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(try fixture.text("item"), "new arrival")
        XCTAssertEqual(try fixture.text("items/item-0", under: fixture.batch()), "original")
        XCTAssertTrue(fixture.service().recover().blocksNewRun)
        XCTAssertEqual(fixture.service().execute(try fixture.service().scan()).status, .recoveryRequired)
    }

    func testJournalWriteFailureBeforeMoveLeavesAllDataAndBlocksUnsafeRetry() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if case .beforeJournal = event { throw TrashSafetyError.io("injected journal write failure") }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertTrue(fixture.exists("item"))
        XCTAssertTrue(fixture.service().recoveryStatus().blocksNewRun)
    }

    func testAbruptRestartReconcilesEveryDestructiveTransitionWithoutResumingDeletion() throws {
        let interruptions: [TrashTransition] = [.afterStage(0), .afterJournal("capturing"), .afterCapture(1),
                                                 .beforeDelete(1), .afterDelete(1)]
        for interruption in interruptions {
            let fixture = try Fixture()
            try fixture.file("folder/leaf", "original")
            let service = fixture.service { event in
                if event == interruption { throw TrashInjectedFailure.simulatedCrash }
            }
            let result = service.execute(try service.scan())
            XCTAssertEqual(result.status, .recoveryRequired, "\(interruption)")
            let restarted = fixture.service()
            XCTAssertTrue(restarted.recoveryStatus().blocksNewRun)
            XCTAssertFalse(restarted.recover().blocksNewRun, "\(interruption)")
            XCTAssertTrue(fixture.exists("folder"))
            if interruption == .afterDelete(1) {
                XCTAssertFalse(fixture.exists("folder/leaf"))
            } else {
                XCTAssertEqual(try fixture.text("folder/leaf"), "original", "\(interruption)")
            }
        }
    }

    func testMalformedJournalBlocksRecoveryAndNewExecution() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if event == .afterStage(0) { throw TrashInjectedFailure.simulatedCrash }
        }
        XCTAssertEqual(service.execute(try service.scan()).status, .recoveryRequired)
        try Data("not a journal".utf8).write(to: fixture.batch().appendingPathComponent("journal.json"))
        let restarted = fixture.service()
        XCTAssertTrue(restarted.recoveryStatus().blocksNewRun)
        XCTAssertTrue(restarted.recover().blocksNewRun)
        XCTAssertEqual(restarted.execute(try restarted.scan()).status, .recoveryRequired)
        XCTAssertEqual(try fixture.text("items/item-0", under: fixture.batch()), "fixture")
    }

    func testCandidateDirectoryWithNewChildCannotBeRecursivelyRemoved() throws {
        let fixture = try Fixture()
        try fixture.file("folder/leaf")
        let service = fixture.service { event in
            if event == .beforeDelete(0) {
                try fixture.file("candidates/entry-0/arrival", "keep", under: fixture.batch())
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .requiresNewReview)
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertEqual(try fixture.text("folder/arrival"), "keep")
    }

    func testExisting0755SupportAncestorsAreAcceptedWithoutChangingTheirModes() throws {
        let fixture = try Fixture()
        let nora = fixture.recovery.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: nora, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(nora.path, 0o755), 0)
        try fixture.file("item")
        let service = fixture.service()
        XCTAssertEqual(service.execute(try service.scan()).status, .completed)
        let attributes = try FileManager.default.attributesOfItem(atPath: nora.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testUnlinkSucceededButDirectorySyncFailedReportsPermanentDeletion() throws {
        let fixture = try Fixture()
        try fixture.file("folder/leaf")
        var failed = false
        let service = fixture.service { event in
            if event == .beforeRemovalSync(1), !failed {
                failed = true
                throw TrashSafetyError.io("injected directory fsync failure after successful unlink")
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertTrue(fixture.exists("folder"))
        XCTAssertFalse(fixture.exists("folder/leaf"))
        XCTAssertFalse(service.recoveryStatus().blocksNewRun)
    }

    func testCancellationAfterFirstUnlinkReturnsPartialCountAndRestoresRemainingItems() throws {
        let fixture = try Fixture()
        try fixture.file("folder/a")
        try fixture.file("folder/b")
        let cancellation = TrashCancellationToken()
        let service = fixture.service { event in
            if event == .afterUnlink(1) { cancellation.cancel() }
        }
        let result = service.execute(try service.scan(), cancellation: cancellation)
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertFalse(fixture.exists("folder/a"))
        XCTAssertTrue(fixture.exists("folder/b"))
    }

    func testInterruptedJournalTemporaryIsCleanedOnlyAfterPayloadRestore() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if event == .afterStage(0) {
                let temporary = try fixture.batch().appendingPathComponent(".journal-\(UUID().uuidString)")
                try Data("partial interrupted metadata".utf8).write(to: temporary)
                XCTAssertEqual(chmod(temporary.path, 0o600), 0)
                throw TrashInjectedFailure.simulatedCrash
            }
        }
        XCTAssertEqual(service.execute(try service.scan()).status, .recoveryRequired)
        XCTAssertFalse(fixture.service().recover().blocksNewRun)
        XCTAssertTrue(fixture.exists("item"))
    }

    func testJournalRemovalCrashWindowOnlyCleansMetadataOnRestart() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if event == .afterJournalRemoval { throw TrashInjectedFailure.simulatedCrash }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .recoveryRequired)
        XCTAssertEqual(result.deletedEntryCount, 1)
        XCTAssertFalse(fixture.exists("item"))
        XCTAssertTrue(fixture.service().recoveryStatus().blocksNewRun)
        XCTAssertFalse(fixture.service().recover().blocksNewRun)
    }

    func testInitialPartialJournalAndEmptyRunOrphansCanRecoverWithoutPayloadDeletion() throws {
        let fixture = try Fixture()
        try fixture.file("untouched")
        // First create only the private staging hierarchy through an empty reviewed run.
        let service = fixture.service()
        let snapshot = try service.scan()
        XCTAssertEqual(service.execute(snapshot).status, .completed)
        try fixture.file("untouched", "new")
        for partial in [false, true] {
            let run = fixture.recovery.appendingPathComponent("run-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            if partial {
                let temporary = run.appendingPathComponent(".journal-\(UUID().uuidString)")
                try Data("partial metadata".utf8).write(to: temporary)
                XCTAssertEqual(chmod(temporary.path, 0o600), 0)
            }
            XCTAssertFalse(service.recover().blocksNewRun)
            XCTAssertEqual(try fixture.text("untouched"), "new")
        }
    }

    func testCompactProgressJournalDoesNotContainOrRewriteTheManifest() throws {
        let fixture = try Fixture()
        for index in 0..<200 { try fixture.file("folder/item-\(index)") }
        var manifestBytes: Data?
        var observations = 0
        let cancellation = TrashCancellationToken()
        let service = fixture.service { event in
            if case .afterJournal = event {
                let batch = try fixture.batch()
                let manifest = try Data(contentsOf: batch.appendingPathComponent("manifest.json"))
                let progress = try Data(contentsOf: batch.appendingPathComponent("journal.json"))
                if let manifestBytes { XCTAssertEqual(manifest, manifestBytes) } else { manifestBytes = manifest }
                XCTAssertLessThan(progress.count, 1024)
                observations += 1
            }
            if event == .afterDelete(1) { cancellation.cancel() }
        }
        XCTAssertEqual(service.execute(try service.scan(), cancellation: cancellation).status, .cancelled)
        XCTAssertGreaterThan(observations, 5)
        XCTAssertGreaterThan(try XCTUnwrap(manifestBytes).count, 10_000)
    }

    func testRecoveryKeepsCrossServiceLockUntilAllRestoresFinish() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let crashed = fixture.service { event in
            if event == .afterStage(0) { throw TrashInjectedFailure.simulatedCrash }
        }
        XCTAssertEqual(crashed.execute(try crashed.scan()).status, .recoveryRequired)
        var checked = false
        let recovery = fixture.service { event in
            if event == .beforeRestore("item") {
                checked = true
                let other = fixture.service()
                XCTAssertTrue(other.recover().blocksNewRun, "Another service must not acquire the recovery lock")
            }
        }
        XCTAssertFalse(recovery.recover().blocksNewRun)
        XCTAssertTrue(checked)
        XCTAssertTrue(fixture.exists("item"))
    }

    func testExtendedACLOnPrivateStagingFailsClosed() throws {
        let fixture = try Fixture()
        let service = fixture.service()
        XCTAssertEqual(service.execute(try service.scan()).status, .completed)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow write,delete_child,file_inherit,directory_inherit", fixture.recovery.path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0, "The isolated macOS ACL fixture must be created")
        XCTAssertTrue(service.recoveryStatus().blocksNewRun)
        try fixture.file("item", "keep")
        XCTAssertEqual(service.execute(try service.scan()).status, .recoveryRequired)
        XCTAssertEqual(try fixture.text("item"), "keep")
    }

    func testDarwinACLWrappersDistinguishAbsentDenyAndAllowEntries() throws {
        let fixture = try Fixture()
        let directory = try TrashFS.open(fixture.home)
        func setACL(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/chmod")
            process.arguments = arguments + [fixture.home.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "The isolated ACL fixture must be configured")
        }
        // Remove inherited ACLs on this generated directory only. An absent FILESEC_ACL
        // property is valid; NULL/ENOENT from acl_get_fd_np was not a directory-read failure.
        try setACL(["-N"])
        XCTAssertNoThrow(try TrashFS.requireNoACL(directory))
        XCTAssertNoThrow(try TrashFS.requireNoGrantACL(directory))

        // Ancestors permit deny-only entries and must successfully iterate past the final
        // entry (-1/EINVAL on Darwin). Private staging requires no entries at all.
        try setACL(["+a", "everyone deny delete"])
        try setACL(["+a", "everyone deny write"])
        XCTAssertThrowsError(try TrashFS.requireNoACL(directory))
        XCTAssertNoThrow(try TrashFS.requireNoGrantACL(directory))

        try setACL(["+a", "everyone allow read"])
        XCTAssertThrowsError(try TrashFS.requireNoACL(directory))
        XCTAssertThrowsError(try TrashFS.requireNoGrantACL(directory))
        try setACL(["-N"])
        XCTAssertNoThrow(try TrashFS.requireNoACL(directory))
        XCTAssertNoThrow(try TrashFS.requireNoGrantACL(directory))
    }

    func testDarwinACLWrappersRejectUnknownDescriptorFailures() {
        let privateResult = nora_trash_require_no_acl(-1)
        let privateError = errno
        let ancestorResult = nora_trash_require_no_grant_acl(-1)
        let ancestorError = errno
        XCTAssertEqual(privateResult, -1)
        XCTAssertEqual(privateError, EBADF)
        XCTAssertEqual(ancestorResult, -1)
        XCTAssertEqual(ancestorError, EBADF)
    }

    func testSymlinkSupportAncestorDoesNotRedirectStaging() throws {
        let fixture = try Fixture()
        let outside = fixture.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.home.appendingPathComponent("Library"),
                                                    withDestinationURL: outside)
        try fixture.file("item")
        let service = fixture.service()
        XCTAssertEqual(service.execute(try service.scan()).status, .recoveryRequired)
        XCTAssertTrue(fixture.exists("item"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testNonUTF8FilenameMakesScanIncomplete() throws {
        let fixture = try Fixture()
        let bytes = fixture.trash.path.utf8.map { CChar(bitPattern: $0) } + [47, -1, 0]
        let descriptor = bytes.withUnsafeBufferPointer {
            open($0.baseAddress!, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let code = errno
            if code == EILSEQ || code == EINVAL {
                throw XCTSkip("This filesystem rejects non-UTF-8 filenames (\(String(cString: strerror(code)))); the scanner case cannot be created here.")
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create the isolated invalid-filename fixture"])
        }
        close(descriptor)
        XCTAssertThrowsError(try fixture.service().scan())
    }

    func testCTimeOnlyChangesAfterStagingAndBeforeNestedCaptureRequireNewReview() throws {
        for nested in [false, true] {
            let fixture = try Fixture()
            try fixture.file(nested ? "folder/leaf" : "item")
            let trigger: TrashTransition = nested ? .beforeCapture(1) : .afterStage(0)
            let service = fixture.service { event in
                if event == trigger {
                    let target = try fixture.batch().appendingPathComponent(nested ? "items/item-0/leaf" : "items/item-0")
                    let original = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
                    XCTAssertEqual(chmod(target.path, 0o600), 0)
                    XCTAssertEqual(chmod(target.path, mode_t(original.uint32Value)), 0)
                }
            }
            let result = service.execute(try service.scan())
            XCTAssertEqual(result.status, .requiresNewReview)
            XCTAssertEqual(result.deletedEntryCount, 0)
            XCTAssertTrue(fixture.exists(nested ? "folder/leaf" : "item"))
        }
    }

    func testHardLinkedAliasesFailClosedWhenStagingChangesTheirSharedMetadata() throws {
        let fixture = try Fixture()
        try fixture.file("a", "shared data")
        try FileManager.default.linkItem(at: fixture.trash.appendingPathComponent("a"),
                                         to: fixture.trash.appendingPathComponent("b"))
        let service = fixture.service()
        let result = service.execute(try service.scan())
        // Alias ctime changes are deliberately not normalized away. A filesystem that does
        // not expose such changes may complete both approved aliases; neither outcome is
        // allowed to remove an unreviewed pathname or report more than the reviewed count.
        XCTAssertTrue([TrashExecutionStatus.completed, .requiresNewReview].contains(result.status))
        XCTAssertLessThanOrEqual(result.deletedEntryCount, 2)
        if result.status == .requiresNewReview {
            XCTAssertTrue(fixture.exists("a") || fixture.exists("b"))
        }
    }

    func testCTimeOnlyChangeAfterCaptureIsNotAcceptedAsOwnRename() throws {
        let fixture = try Fixture()
        try fixture.file("item")
        let service = fixture.service { event in
            if event == .afterCapture(0) {
                let target = try fixture.batch().appendingPathComponent("candidates/entry-0")
                let original = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
                XCTAssertEqual(chmod(target.path, 0o600), 0)
                XCTAssertEqual(chmod(target.path, mode_t(original.uint32Value)), 0)
            }
        }
        let result = service.execute(try service.scan())
        XCTAssertEqual(result.status, .requiresNewReview)
        XCTAssertEqual(result.deletedEntryCount, 0)
        XCTAssertTrue(fixture.exists("item"))
    }
}
