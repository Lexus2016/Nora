import XCTest
@testable import MoleKit

/// Mole's own Analyze (1.65 and 1.68, cmd/analyze/delete.go) refuses to move some paths to the
/// Trash: system roots, the home folder, Docker Desktop and OrbStack state, and iCloud Drive's own
/// folders (trashing one removes that store from every device on the account). Nora's Space Map
/// moves items to the Trash itself, so it must refuse the same paths.
final class SpaceProtectionTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("space-protection-\(UUID().uuidString)")
        for relative in [
            "Library/Mobile Documents/com~apple~CloudDocs/Documents/Sub",
            "Library/Containers/com.docker.docker/Data",
            ".orbstack/data",
            "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
            "Library/Caches/Foo",
            "Downloads",
        ] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: home.appendingPathComponent("Downloads/file.zip"))
        try Data("x".utf8).write(to: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Sub/photo.jpg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func reason(_ relative: String) -> SpaceProtection.Reason? {
        SpaceProtection.reason(forTrashing: home.appendingPathComponent(relative).path, home: home)
    }

    func testTheHomeFolderIsProtected() {
        XCTAssertEqual(SpaceProtection.reason(forTrashing: home.path, home: home), .home)
    }

    func testICloudDriveStructureIsProtectedButItsFilesAreNot() {
        let drive = "Library/Mobile Documents"
        XCTAssertEqual(reason(drive), .iCloud)
        XCTAssertEqual(reason(drive + "/com~apple~CloudDocs"), .iCloud, "iCloud Drive itself")
        XCTAssertEqual(reason(drive + "/com~apple~CloudDocs/Documents"), .iCloud, "a container's Documents folder")
        XCTAssertNil(reason(drive + "/com~apple~CloudDocs/Documents/Sub"), "folders inside stay the user's to remove")
        XCTAssertNil(reason(drive + "/com~apple~CloudDocs/Documents/Sub/photo.jpg"))
        XCTAssertNotNil(reason("Library"), "moving Library would move Mobile Documents and Docker's state with it")
    }

    func testRunningAppStateIsProtectedIncludingItsAncestors() {
        XCTAssertEqual(reason("Library/Containers/com.docker.docker"), .appState)
        XCTAssertEqual(reason("Library/Containers/com.docker.docker/Data"), .appState)
        XCTAssertEqual(reason("Library/Containers"), .appState, "it holds Docker Desktop's state")
        XCTAssertEqual(reason(".orbstack"), .appState)
        XCTAssertEqual(reason(".orbstack/data"), .appState)
        XCTAssertEqual(reason("Library/Group Containers/HUAQ24HBR6.dev.orbstack"), .appState)
    }

    func testAnAbsentRuntimeDoesNotProtectItsAncestor() throws {
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Containers/com.docker.docker"))
        XCTAssertNil(reason("Library/Containers"))
    }

    func testOrdinaryFilesAndCachesAreNotProtected() {
        XCTAssertNil(reason("Downloads/file.zip"))
        XCTAssertNil(reason("Downloads"))
        XCTAssertNil(reason("Library/Caches/Foo"))
    }

    func testSystemRootsAndTreesAreProtected() {
        for path in ["/", "/Applications", "/Library", "/System", "/System/Library/CoreServices", "/Users", "/Volumes",
                     "/usr/local", "/opt/homebrew", "/Applications/Safari.app", "/Applications/Finder.app"] {
            XCTAssertEqual(SpaceProtection.reason(forTrashing: path, home: home), .system, path)
        }
    }

    func testAnotherAccountsHomeIsProtected() {
        XCTAssertEqual(SpaceProtection.reason(forTrashing: "/Users/Shared", home: home), .system)
    }

    func testAnOrdinaryApplicationIsAllowed() {
        XCTAssertNil(SpaceProtection.reason(forTrashing: "/Applications/Some Third Party.app", home: home))
    }

    /// APFS is case-insensitive by default, so these spellings name the same folders as the protected ones.
    func testAnotherCaseOfAProtectedPathIsStillProtected() {
        XCTAssertEqual(SpaceProtection.reason(forTrashing: "/SYSTEM/Library", home: home), .system)
        XCTAssertEqual(SpaceProtection.reason(forTrashing: "/applications", home: home), .system)
        XCTAssertEqual(SpaceProtection.reason(forTrashing: "/system/volumes/data/Users", home: home), .system)
        XCTAssertEqual(SpaceProtection.reason(forTrashing: home.path.uppercased(), home: home), .home)
        XCTAssertEqual(reason("Library/Containers/COM.DOCKER.DOCKER/Data"), .appState)
        XCTAssertEqual(reason(".OrbStack/data"), .appState)
        XCTAssertEqual(reason("library/mobile documents"), .iCloud)
        XCTAssertEqual(reason("LIBRARY/MOBILE DOCUMENTS/COM~APPLE~CLOUDDOCS/DOCUMENTS"), .iCloud)
    }

    /// iCloud Drive's Desktop folder is synced like its Documents folder: trashing it removes it from every device.
    func testICloudDriveDesktopFolderIsProtectedButItsContentsAreNot() {
        let desktop = "Library/Mobile Documents/com~apple~CloudDocs/Desktop"
        XCTAssertEqual(reason(desktop), .iCloud)
        XCTAssertNil(reason(desktop + "/old screenshot.png"))
    }

    /// The Trash moves a symlink itself, never what it points to, so a link to a protected folder is an
    /// ordinary item. A path that reaches a protected folder THROUGH a link is still protected.
    func testASymlinkIsTrashedAsALinkButAPathThroughOneIsStillChecked() throws {
        let fileManager = FileManager.default
        let links = home.appendingPathComponent("Links")
        try fileManager.createDirectory(at: links, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: links.appendingPathComponent("to-applications"),
                                           withDestinationURL: URL(fileURLWithPath: "/Applications"))
        try fileManager.createSymbolicLink(at: links.appendingPathComponent("to-drive"),
                                           withDestinationURL: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"))
        try fileManager.createSymbolicLink(at: links.appendingPathComponent("to-docker"),
                                           withDestinationURL: home.appendingPathComponent("Library/Containers/com.docker.docker"))
        XCTAssertNil(reason("Links/to-applications"), "the link, not /Applications, goes to the Trash")
        XCTAssertNil(reason("Links/to-drive"))
        XCTAssertNil(reason("Links/to-docker"))
        XCTAssertEqual(reason("Links/to-docker/Data"), .appState, "Data is Docker's own folder, reached through a link")
        XCTAssertEqual(reason("Links/to-drive/Documents"), .iCloud)
    }

    func testAFirmlinkSpellingOfAProtectedPathIsStillProtected() {
        XCTAssertEqual(SpaceProtection.reason(forTrashing: "/System/Volumes/Data/Users", home: home), .system)
    }
}
