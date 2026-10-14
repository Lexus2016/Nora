import XCTest
@testable import Nora

/// Homebrew parsing and the upgrade command, on synthetic brew JSON (v2 shapes).
final class AppsBrewTests: XCTestCase {
    private let outdatedJSON = Data("""
    {"formulae": [],
     "casks": [
       {"name": "example-app", "installed_versions": ["1.0"], "current_version": "1.1", "pinned": false, "pinned_version": null},
       {"name": "sample-tool", "installed_versions": ["2.0", "2.1"], "current_version": "3.0"},
       {"name": "no-version-app", "current_version": null}
     ]}
    """.utf8)

    private let infoJSON = Data("""
    {"casks": [
       {"token": "example-app", "name": ["Example App"], "installed": "1.0", "auto_updates": true},
       {"token": "sample-tool", "name": [], "installed": "2.1", "auto_updates": null},
       {"token": "two-apps", "name": ["Two"], "auto_updates": false,
        "artifacts": [{"uninstall": [{"quit": "com.example.two"}]}, {"app": ["Two.app", {"target": "Two Helper.app"}], "target": "/Applications/Two.app"}, {"zap": [{"trash": "~/Library/Two"}]}]},
       {"token": "odd-artifacts", "name": ["Odd"], "artifacts": "not a list"}
     ]}
    """.utf8)

    func testParsesOutdatedCasksByToken() throws {
        let items = try Homebrew.parseOutdated(outdatedJSON)
        XCTAssertEqual(items.map(\.token), ["example-app", "sample-tool", "no-version-app"])
        XCTAssertEqual(items[0], Homebrew.Outdated(token: "example-app", installed: "1.0", latest: "1.1"))
        XCTAssertEqual(items[1].installed, "2.0, 2.1")
        XCTAssertEqual(items[2].installed, "")
        XCTAssertEqual(items[2].latest, "?")
    }

    func testEmptyOutdatedListParses() throws {
        XCTAssertEqual(try Homebrew.parseOutdated(Data(#"{"formulae": [], "casks": []}"#.utf8)), [])
        XCTAssertEqual(try Homebrew.parseOutdated(Data("{}".utf8)), [])
    }

    func testParsesInfoAndTolerantlyReadsNullAndEmptyFields() throws {
        let info = try Homebrew.parseInfo(infoJSON)
        XCTAssertEqual(info["example-app"], Homebrew.CaskInfo(name: "Example App", autoUpdates: true))
        XCTAssertEqual(info["sample-tool"], Homebrew.CaskInfo(name: nil, autoUpdates: false))
    }

    func testMergeTakesDisplayNameAndSelfUpdateFlagAndFallsBackToToken() throws {
        let merged = Homebrew.merge(outdated: try Homebrew.parseOutdated(outdatedJSON), info: try Homebrew.parseInfo(infoJSON))
        let byToken = Dictionary(uniqueKeysWithValues: merged.map { ($0.token, $0) })
        XCTAssertEqual(byToken["example-app"]?.name, "Example App")
        XCTAssertEqual(byToken["example-app"]?.autoUpdates, true)
        XCTAssertEqual(byToken["sample-tool"]?.name, "sample-tool")
        XCTAssertEqual(byToken["sample-tool"]?.autoUpdates, false)
        XCTAssertEqual(byToken["no-version-app"]?.name, "no-version-app")
        XCTAssertEqual(merged.count, 3)
    }

    func testUpgradeCommandListsTokensAfterUpgradeCask() {
        let command = Homebrew.upgradeCommand(tokens: ["example-app", "sample-tool"], executable: "/example/bin/brew")
        XCTAssertEqual(command?.arguments, ["upgrade", "--cask", "example-app", "sample-tool"])
        XCTAssertEqual(command?.description, "HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask example-app sample-tool")
    }

    func testUpgradeCommandQuotesTokensForDisplayOnly() {
        let command = Homebrew.upgradeCommand(tokens: ["font-fira code"], executable: "/example/bin/brew")
        XCTAssertEqual(command?.arguments, ["upgrade", "--cask", "font-fira code"])
        XCTAssertTrue(command?.description.hasSuffix("brew upgrade --cask 'font-fira code'") == true)
    }

    func testUpgradeCommandRefusesEmptyListsFlagsAndControlCharacters() {
        XCTAssertNil(Homebrew.upgradeCommand(tokens: [], executable: "/example/bin/brew"))
        XCTAssertNil(Homebrew.upgradeCommand(tokens: ["example-app", "--greedy"], executable: "/example/bin/brew"))
        XCTAssertNil(Homebrew.upgradeCommand(tokens: ["bad\ntoken"], executable: "/example/bin/brew"))
        XCTAssertNil(Homebrew.upgradeCommand(tokens: [""], executable: "/example/bin/brew"))
    }

    func testScanCommandKeepsTheReadOnlyVariables() {
        let outdated = Homebrew.command("/example/bin/brew", Homebrew.outdatedArguments())
        XCTAssertEqual(outdated.description, "HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --cask --greedy --json=v2")
    }

    func testInfoReadsTheAppBundlesACaskInstalls() throws {
        let info = try Homebrew.parseInfo(infoJSON)
        XCTAssertEqual(info["two-apps"]?.apps, ["Two.app", "Two Helper.app"])
        XCTAssertEqual(info["example-app"]?.apps, [])
        XCTAssertEqual(info["odd-artifacts"]?.apps, [], "unreadable artifacts still list the cask")
        let merged = Homebrew.merge(outdated: [Homebrew.Outdated(token: "two-apps", installed: "1", latest: "2")], info: info)
        XCTAssertEqual(merged.first?.apps, ["Two.app", "Two Helper.app"])
    }
}
