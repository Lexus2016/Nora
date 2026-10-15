import XCTest
@testable import Nora

/// Updates for apps from a DMG: version comparison, cask matching by name and bundle ID, and
/// Sparkle feeds. The versions are real pairs seen on a Mac (installed app vs Homebrew catalog).
final class AppsOutsideTests: XCTestCase {
    private func local(_ file: String, _ bundleID: String, _ version: String, build: String? = nil) -> OutsideApps.Local {
        OutsideApps.Local(path: "/Applications/\(file)", name: (file as NSString).deletingPathExtension,
                          bundleID: bundleID, version: version, build: build, feed: nil)
    }

    func testNewerOnlyWhenTheMarketingVersionIsAhead() {
        XCTAssertTrue(OutsideApps.isNewer("5.8.1,2349", than: "5.8"))                 // Alfred
        XCTAssertTrue(OutsideApps.isNewer("2026.2.1.8,rabbit1", than: "2026.1"))      // Android Studio
        XCTAssertTrue(OutsideApps.isNewer("155.0.8059.80", than: "154.0.8037.98"))    // Chrome
        XCTAssertTrue(OutsideApps.isNewer("0.1.907-beta", than: "0.1.815-beta"))      // Unsloth
        XCTAssertTrue(OutsideApps.isNewer("1.3.11", than: "1.3.7"))                   // numeric, not text
    }

    func testEqualOrOlderIsNotAnUpdate() {
        XCTAssertFalse(OutsideApps.isNewer("5.7.1,50701.0.2609301754", than: "5.7.1"))   // CleanMyMac
        XCTAssertFalse(OutsideApps.isNewer("26.8.3.1016,117434", than: "26.8.3.1016"))   // Yandex: build ignored
        XCTAssertFalse(OutsideApps.isNewer("1.7.1", than: "1.8.0"))                      // TypeWhisper: catalog behind
        XCTAssertFalse(OutsideApps.isNewer("5.8.0", than: "5.8"))
    }

    /// A04: versions with different letters do not compare; same-kind pre-releases do.
    func testPreReleasesCompareOnlyWithTheirOwnKind() {
        XCTAssertFalse(OutsideApps.isNewer("2.0rc1", than: "2.0"))
        XCTAssertFalse(OutsideApps.isNewer("2.0", than: "2.0rc1"), "unknown, not offered")
        XCTAssertTrue(OutsideApps.isNewer("159.0b2", than: "159.0b1"))
        XCTAssertTrue(OutsideApps.isNewer("1.0b10", than: "1.0b2"))
        XCTAssertFalse(OutsideApps.isNewer("31.15.5330-HF1", than: "31.15.5330"))
        XCTAssertTrue(OutsideApps.isNewer("8.37.2-1", than: "8.37.2"), "a package revision has no letters")
    }

    func testUnreadableVersionsAreSkipped() {
        XCTAssertFalse(OutsideApps.isNewer("latest", than: "1.0"))
        XCTAssertFalse(OutsideApps.isNewer("2.0", than: ""))
        XCTAssertEqual(OutsideApps.numbers("99999999999999999999.1"), [])
    }

    private let catalogJSON = Data("""
    [
     {"token": "telegram", "version": "13.0,283305", "auto_updates": true, "depends_on": {"macos": {}},
      "artifacts": [{"app": ["Telegram.app"], "target": "/Applications/Telegram.app"}, {"zap": [{"trash": ["~/Library/Preferences/ru.keepcoder.Telegram.plist"]}]}]},
     {"token": "docker-desktop", "version": "4.95.0,242831", "depends_on": {"macos": {">=": ["14"]}},
      "artifacts": [{"app": ["Docker.app"]}, {"binary": ["$APPDIR/Docker.app/Contents/Resources/bin/docker"]}, {"uninstall": [{"quit": "com.docker.docker"}]}]},
     {"token": "needs-java", "version": "2.0", "depends_on": {"cask": ["temurin"]},
      "artifacts": [{"app": ["Javaish.app"]}, {"zap": [{"trash": "com.example.javaish"}]}]},
     {"token": "telegram-desktop", "version": "7.3.1", "auto_updates": true,
      "artifacts": [{"app": ["Telegram.app"]}, {"zap": [{"trash": ["~/Library/Application Support/Telegram Desktop"]}]}]},
     {"token": "telegram-desktop@beta", "version": "7.3.1", "artifacts": [{"app": ["Telegram.app"]}]},
     {"token": "block-buzz", "version": "0.5.28", "auto_updates": null,
      "artifacts": [{"app": ["Buzz.app"]}, {"uninstall": [{"quit": "xyz.block.buzz.app"}]}]},
     {"token": "buzz", "version": "1.4.5", "artifacts": [{"app": ["Buzz.app"]}, {"zap": [{"trash": ["~/Library/Buzz"]}]}]},
     {"token": "renamed", "version": "2.0", "artifacts": [{"app": ["Other.app", {"target": "Pretty Name.app"}]}, {"zap": [{"trash": "com.example.pretty"}]}]},
     {"token": "subfolder", "version": "2.0", "artifacts": [{"app": ["Tool.app", {"target": "Suite/Tool.app"}]}, {"zap": [{"trash": "com.example.tool"}]}]},
     {"token": "editor-pro", "version": "3.0", "artifacts": [{"app": ["Editor.app"]}, {"zap": [{"trash": "~/Library/Preferences/com.example.editor.pro.plist"}]}]},
     {"token": "old-thing", "version": "9.9", "deprecated": true, "artifacts": [{"app": ["Old.app"]}]},
     {"token": "nightly", "version": "latest", "artifacts": [{"app": ["Nightly.app"]}]},
     {"token": "a-font", "version": "1.0", "artifacts": [{"font": ["A.ttf"]}]}
    ]
    """.utf8)

    func testCatalogDropsVariantsDeprecatedLatestAndCasksWithoutApps() throws {
        let tokens = try OutsideApps.parseCatalog(catalogJSON).map(\.token)
        XCTAssertEqual(tokens, ["telegram", "docker-desktop", "needs-java", "telegram-desktop", "block-buzz", "buzz", "renamed", "editor-pro"])
    }

    func testOnlyCasksThatInstallJustTheAppCanBeInstalledByNora() throws {
        let casks = Dictionary(uniqueKeysWithValues: try OutsideApps.parseCatalog(catalogJSON).map { ($0.token, $0) })
        XCTAssertEqual(casks["telegram"]?.installsOnlyApp, true)
        XCTAssertEqual(casks["block-buzz"]?.installsOnlyApp, true)
        XCTAssertEqual(casks["docker-desktop"]?.installsOnlyApp, false)   // a binary link and more
        XCTAssertEqual(casks["needs-java"]?.installsOnlyApp, false)       // another cask comes along
    }

    func testMatchNeedsTheBundleIDNotJustTheName() throws {
        let index = OutsideApps.index(try OutsideApps.parseCatalog(catalogJSON))
        XCTAssertEqual(OutsideApps.match(local("Telegram.app", "ru.keepcoder.Telegram", "13.0"), in: index)?.token, "telegram")
        XCTAssertEqual(OutsideApps.match(local("Buzz.app", "xyz.block.buzz.app", "0.5.27"), in: index)?.token, "block-buzz")
        XCTAssertEqual(OutsideApps.match(local("Pretty Name.app", "com.example.pretty", "1.0"), in: index)?.token, "renamed")
        // A02: the renamed source never exists on disk, and an ID prefix is another app's ID.
        XCTAssertNil(OutsideApps.match(local("Other.app", "com.example.pretty", "1.0"), in: index))
        XCTAssertNil(OutsideApps.match(local("Tool.app", "com.example.tool", "1.0"), in: index), "installed in a subfolder")
        XCTAssertNil(OutsideApps.match(local("Editor.app", "com.example.editor", "1.0"), in: index))
        XCTAssertEqual(OutsideApps.match(local("Editor.app", "com.example.editor.pro", "1.0"), in: index)?.token, "editor-pro")
        XCTAssertNil(OutsideApps.match(local("Telegram.app", "org.other.telegram", "1.0"), in: index))
        XCTAssertNil(OutsideApps.match(local("Unknown.app", "ru.keepcoder.Telegram", "1.0"), in: index))
    }

    func testCaskUpdateKeepsOnlyTheMarketingPartOfTheVersion() throws {
        let index = OutsideApps.index(try OutsideApps.parseCatalog(catalogJSON))
        let telegram = local("Telegram.app", "ru.keepcoder.Telegram", "12.4")
        let cask = try XCTUnwrap(OutsideApps.match(telegram, in: index))
        let update = OutsideApps.update(telegram, cask: cask, brewFound: true)
        XCTAssertEqual(update?.latest, "13.0")
        XCTAssertEqual(update?.installed, "12.4")
        XCTAssertEqual(update?.action, .brew("telegram"))
        XCTAssertNil(OutsideApps.update(local("Telegram.app", "ru.keepcoder.Telegram", "13.0"), cask: cask, brewFound: true))
    }

    func testOpenInsteadOfHomebrewWhenNoraCannotInstallTheCaskSafely() throws {
        let index = OutsideApps.index(try OutsideApps.parseCatalog(catalogJSON))
        let telegram = local("Telegram.app", "ru.keepcoder.Telegram", "12.4")
        let cask = try XCTUnwrap(OutsideApps.match(telegram, in: index))
        XCTAssertEqual(OutsideApps.update(telegram, cask: cask, brewFound: false)?.action, .open)
        let elsewhere = OutsideApps.Local(path: "/Users/someone/Applications/Telegram.app", name: "Telegram", bundleID: "ru.keepcoder.Telegram",
                                          version: "12.4", build: nil, feed: nil)
        XCTAssertEqual(OutsideApps.update(elsewhere, cask: cask, brewFound: true)?.action, .open)
        var rootOwned = telegram
        rootOwned.movable = false
        XCTAssertEqual(OutsideApps.update(rootOwned, cask: cask, brewFound: true)?.action, .open, "Nora cannot move it aside")
        let docker = local("Docker.app", "com.docker.docker", "4.86.0")
        XCTAssertEqual(OutsideApps.update(docker, cask: try XCTUnwrap(OutsideApps.match(docker, in: index)), brewFound: true)?.action, .open)
    }

    /// Grok Bot installed 0.71.2 itself when Nora quit it: that is the update, not a change to refuse.
    func testAnAppThatUpdatedItselfOnQuitCountsAsUpdated() {
        let item = OutsideApps.Update(path: "/Applications/Grok Bot.app", name: "Grok Bot", bundleID: "com.anysphere.sand",
                                      installed: "0.70.2", latest: "0.71.2", action: .brew("grok-bot"))
        XCTAssertTrue(OutsideApps.updatedItself(item, now: local("Grok Bot.app", "com.anysphere.sand", "0.71.2")))
        XCTAssertTrue(OutsideApps.updatedItself(item, now: local("Grok Bot.app", "com.anysphere.sand", "0.72.0")))
        XCTAssertFalse(OutsideApps.updatedItself(item, now: local("Grok Bot.app", "com.anysphere.sand", "0.70.2")))
        XCTAssertFalse(OutsideApps.updatedItself(item, now: local("Grok Bot.app", "com.anysphere.sand", "0.70.9")), "newer, but not the update")
        XCTAssertFalse(OutsideApps.updatedItself(item, now: local("Grok Bot.app", "com.other", "0.71.2")))
    }

    func testTheFeedWinsWhenItIsAheadOfTheCask() {
        func update(_ latest: String, _ action: OutsideApps.Action) -> OutsideApps.Update {
            OutsideApps.Update(path: "/Applications/A.app", name: "A", bundleID: "com.example.a", installed: "1.0", latest: latest, action: action)
        }
        XCTAssertEqual(OutsideApps.choose(feed: update("1.9", .open), cask: update("1.7", .brew("a")))?.action, .open)
        XCTAssertEqual(OutsideApps.choose(feed: update("1.7", .open), cask: update("1.7", .brew("a")))?.action, .brew("a"))
        XCTAssertEqual(OutsideApps.choose(feed: nil, cask: update("1.7", .brew("a")))?.action, .brew("a"))
        XCTAssertEqual(OutsideApps.choose(feed: update("1.9", .open), cask: nil)?.latest, "1.9")
        XCTAssertNil(OutsideApps.choose(feed: nil, cask: nil))
        var builds = update("512", .open)
        builds.builds = true
        XCTAssertEqual(OutsideApps.choose(feed: builds, cask: update("6.0", .brew("a")))?.action, .open, "a build does not compare with 6.0")
    }

    private let feedXML = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
     <channel>
      <item><title>2.1 beta</title><sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://example.com/b.dmg" sparkle:version="210" sparkle:shortVersionString="2.1"/></item>
      <item><title>2.0</title><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
        <enclosure url="https://example.com/a.dmg" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
      <item><title>3.0</title><sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
        <sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString></item>
      <item><title>1.9</title><sparkle:version>190</sparkle:version><sparkle:shortVersionString>1.9</sparkle:shortVersionString></item>
     </channel>
    </rss>
    """.utf8)

    func testFeedSkipsBetaAndReleasesThisMacCannotRun() {
        let items = OutsideApps.parseFeed(feedXML)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(OutsideApps.newest(items, system: [26, 0])?.shortVersion, "2.0")
        XCTAssertEqual(OutsideApps.newest(items, system: [13, 6])?.shortVersion, "1.9")
    }

    func testFeedUpdateComparesMarketingVersionsOrElseBuilds() {
        let items = OutsideApps.parseFeed(feedXML)
        XCTAssertEqual(OutsideApps.update(local("A.app", "com.example.a", "1.9"), feed: items, system: [26, 0])?.latest, "2.0")
        XCTAssertNil(OutsideApps.update(local("A.app", "com.example.a", "2.0"), feed: items, system: [26, 0]))
        let buildsOnly = [OutsideApps.FeedItem(shortVersion: nil, version: "512")]
        XCTAssertEqual(OutsideApps.update(local("B.app", "com.example.b", "5.1", build: "500"), feed: buildsOnly, system: [26, 0])?.latest, "512")
        XCTAssertNil(OutsideApps.update(local("B.app", "com.example.b", "5.1"), feed: buildsOnly, system: [26, 0]))
        XCTAssertNil(OutsideApps.update(local("A.app", "com.example.a", "1.0"), feed: OutsideApps.parseFeed(Data("not xml".utf8)), system: [26, 0]))
    }

    // MARK: - Handover

    private func sandbox() throws -> (dir: URL, journal: OutsideApps.Journal) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)", isDirectory: true)
        let trash = dir.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var journal = OutsideApps.Journal(url: dir.appendingPathComponent("Support/app-handover.json"))
        journal.trash = { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent(UUID().uuidString)) }
        return (dir, journal)
    }

    /// A minimal app bundle: an Info.plist with an ID and a version, which is all `local` reads.
    private func bundle(_ url: URL, _ version: String, id: String = "com.example.a") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func version(_ url: URL) -> String? {
        OutsideApps.local(path: url.path, name: "A", excluding: nil)?.version
    }

    private func trashCount(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Trash").path).count) ?? -1
    }

    private func installed(_ dir: URL) throws -> (URL, OutsideApps.Local) {
        let original = dir.appendingPathComponent("Applications/A.app")
        try bundle(original, "1.0")
        return (original, try XCTUnwrap(OutsideApps.local(path: original.path, name: "A", excluding: nil)))
    }

    @MainActor func testHandoverKeepsAVerifiedNewVersionAndTrashesTheOldCopy() async throws {
        let (dir, journal) = try sandbox()
        let (original, app) = try installed(dir)
        let outcome = await OutsideApps.Handover(journal: journal).run(app) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "the old copy is set aside first")
            XCTAssertEqual(try? journal.entries().count, 1, "and journaled before that")
            try? self.bundle(original, "2.0")
        }
        XCTAssertEqual(outcome, .updated("2.0"))
        XCTAssertEqual(version(original), "2.0")
        XCTAssertEqual(trashCount(dir), 1)
        XCTAssertEqual(try journal.entries(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journal.staging.path), [])
    }

    /// A01/A03: nothing installed, an empty bundle, another app's bundle or an older version all
    /// put the old copy back; what brew left goes to the Trash.
    @MainActor func testHandoverPutsTheOldCopyBackUnlessTheNewBundleChecksOut() async throws {
        let results: [(String, (URL) throws -> Void)] = [
            ("nothing", { _ in }),
            ("empty bundle", { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }),
            ("other app", { try self.bundle($0, "2.0", id: "com.example.other") }),
            ("older", { try self.bundle($0, "0.9") }),
        ]
        for (label, install) in results {
            let (dir, journal) = try sandbox()
            let (original, app) = try installed(dir)
            let outcome = await OutsideApps.Handover(journal: journal).run(app) { try? install(original) }
            XCTAssertEqual(outcome, .restored, label)
            XCTAssertEqual(version(original), "1.0", label)
            XCTAssertEqual(try journal.entries(), [], label)
            XCTAssertEqual(trashCount(dir), label == "nothing" ? 0 : 1, label)
        }
    }

    func testAPermissionErrorIsDescribedWithoutTheStagingFolder() {
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/x/Handover/69C8/A.app"])
        XCTAssertFalse(OutsideApps.Handover.describeMove(denied).contains("69C8"))
        XCTAssertTrue(OutsideApps.Handover.describeMove(denied).contains("App Management"))
    }

    @MainActor func testHandoverChangesNothingWhenTheJournalCannotBeWritten() async throws {
        let (dir, journal) = try sandbox()
        let (original, app) = try installed(dir)
        try Data("not json".utf8).write(to: { try? FileManager.default.createDirectory(at: journal.url.deletingLastPathComponent(), withIntermediateDirectories: true); return journal.url }())
        var installs = 0
        let outcome = await OutsideApps.Handover(journal: journal).run(app) { installs += 1 }
        guard case .untouched = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(version(original), "1.0")
        XCTAssertThrowsError(try journal.entries(), "a damaged journal is an error, not an empty list")
    }

    /// A stop mid-install: the place is empty or holds a partial bundle, so the old copy comes back.
    func testRecoverPutsTheOldCopyBackWhenTheInstallNeverFinished() throws {
        for partial in [false, true] {
            let (dir, journal) = try sandbox()
            let original = dir.appendingPathComponent("Applications/A.app")
            let staged = journal.staging.appendingPathComponent("X/A.app")
            try bundle(staged, "1.0")
            if partial { try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true) }
            try journal.add(.init(original: original.path, staged: staged.path, bundleID: "com.example.a"))
            XCTAssertEqual(journal.recover(), [original.path])
            XCTAssertEqual(version(original), "1.0")
            XCTAssertEqual(trashCount(dir), partial ? 1 : 0)
            XCTAssertEqual(try journal.entries(), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path), "an empty journal leaves no file")
        }
    }

    func testRecoverKeepsAVerifiedNewVersion() throws {
        let (dir, journal) = try sandbox()
        let original = dir.appendingPathComponent("Applications/A.app")
        let staged = journal.staging.appendingPathComponent("X/A.app")
        try bundle(original, "2.0")
        try bundle(staged, "1.0")
        try journal.add(.init(original: original.path, staged: staged.path, bundleID: "com.example.a"))
        XCTAssertEqual(journal.recover(), [])
        XCTAssertEqual(version(original), "2.0")
        XCTAssertEqual(trashCount(dir), 1)
        XCTAssertEqual(try journal.entries(), [])
    }

    /// 1.1.0 journaled a copy in the Trash; it is read, and that copy is left where it is.
    func testRecoverReadsA110EntryAndLeavesItsTrashCopy() throws {
        let (dir, journal) = try sandbox()
        let original = dir.appendingPathComponent("Applications/A.app"), trashed = dir.appendingPathComponent("Old/A.app")
        try bundle(original, "2.0")
        try bundle(trashed, "1.0")
        try FileManager.default.createDirectory(at: journal.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"original":"\#(original.path)","trashed":"\#(trashed.path)"}]"#.utf8).write(to: journal.url)
        XCTAssertEqual(try journal.entries().first?.staged, trashed.path)
        XCTAssertEqual(journal.recover(), [])
        XCTAssertEqual(version(original), "2.0")
        XCTAssertEqual(version(trashed), "1.0")
        XCTAssertEqual(try journal.entries(), [])
    }

    func testAddAndRemoveKeepOneEntryPerApp() throws {
        let (_, journal) = try sandbox()
        let a = OutsideApps.Journal.Entry(original: "/Applications/A.app", staged: "/S/1/A.app", bundleID: "com.example.a")
        let b = OutsideApps.Journal.Entry(original: "/Applications/B.app", staged: "/S/2/B.app", bundleID: nil)
        try journal.add(a); try journal.add(a); try journal.add(b)
        XCTAssertEqual(try journal.entries(), [a, b])
        try journal.remove(a)
        XCTAssertEqual(try journal.entries(), [b])
    }
}
