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
     {"token": "renamed", "version": "2.0", "artifacts": [{"app": [{"target": "Pretty Name.app"}, "Ignored/Other.app"]}, {"zap": [{"trash": "com.example.pretty"}]}]},
     {"token": "old-thing", "version": "9.9", "deprecated": true, "artifacts": [{"app": ["Old.app"]}]},
     {"token": "nightly", "version": "latest", "artifacts": [{"app": ["Nightly.app"]}]},
     {"token": "a-font", "version": "1.0", "artifacts": [{"font": ["A.ttf"]}]}
    ]
    """.utf8)

    func testCatalogDropsVariantsDeprecatedLatestAndCasksWithoutApps() throws {
        let tokens = try OutsideApps.parseCatalog(catalogJSON).map(\.token)
        XCTAssertEqual(tokens, ["telegram", "docker-desktop", "needs-java", "telegram-desktop", "block-buzz", "buzz", "renamed"])
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
        XCTAssertEqual(OutsideApps.match(local("Other.app", "com.example.pretty", "1.0"), in: index)?.token, "renamed")
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
        let docker = local("Docker.app", "com.docker.docker", "4.86.0")
        XCTAssertEqual(OutsideApps.update(docker, cask: try XCTUnwrap(OutsideApps.match(docker, in: index)), brewFound: true)?.action, .open)
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

    // MARK: - Handover journal

    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Trash"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func bundle(_ url: URL, _ version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data(version.utf8).write(to: url.appendingPathComponent("Contents/version"))
    }

    private func version(_ url: URL) -> String? {
        (try? Data(contentsOf: url.appendingPathComponent("Contents/version"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testRecoverPutsTheOldCopyBackWhenTheInstallNeverFinished() throws {
        let dir = try sandbox()
        let original = dir.appendingPathComponent("Applications/A.app"), trashed = dir.appendingPathComponent("Trash/A.app")
        try bundle(trashed, "1.0")
        let journal = OutsideApps.Journal(url: dir.appendingPathComponent("journal.json"))
        journal.add(.init(original: original.path, trashed: trashed.path))
        XCTAssertEqual(journal.recover(), [original.path])
        XCTAssertEqual(version(original), "1.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path))
        XCTAssertEqual(journal.entries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.url.path), "an empty journal leaves no file")
    }

    func testRecoverLeavesTheNewVersionAndTheTrashAlone() throws {
        let dir = try sandbox()
        let original = dir.appendingPathComponent("Applications/A.app"), trashed = dir.appendingPathComponent("Trash/A.app")
        try bundle(original, "2.0")
        try bundle(trashed, "1.0")
        let journal = OutsideApps.Journal(url: dir.appendingPathComponent("journal.json"))
        journal.add(.init(original: original.path, trashed: trashed.path))
        journal.add(.init(original: dir.appendingPathComponent("Applications/B.app").path, trashed: dir.appendingPathComponent("Trash/B.app").path))
        XCTAssertEqual(journal.recover(), [])
        XCTAssertEqual(version(original), "2.0")
        XCTAssertEqual(version(trashed), "1.0")
        XCTAssertEqual(journal.entries(), [], "taken places and emptied copies are both done")
    }

    func testAddAndRemoveKeepOneEntryPerApp() throws {
        let dir = try sandbox()
        let journal = OutsideApps.Journal(url: dir.appendingPathComponent("journal.json"))
        let a = OutsideApps.Journal.Entry(original: "/Applications/A.app", trashed: "/Trash/A.app")
        let b = OutsideApps.Journal.Entry(original: "/Applications/B.app", trashed: "/Trash/B.app")
        journal.add(a); journal.add(a); journal.add(b)
        XCTAssertEqual(journal.entries(), [a, b])
        journal.remove(a)
        XCTAssertEqual(journal.entries(), [b])
    }
}
