import XCTest
import MoleKit
@testable import Nora

@MainActor
final class NavigationConsistencyRegressionTests: XCTestCase {
    func testSameNamedInstallersRemainIndividuallySelectable() {
        let model = InstallersModel()
        model.files = [
            .init(name: "Example.dmg", sizeText: "1MB", source: "Downloads"),
            .init(name: "Example.dmg", sizeText: "2MB", source: "Downloads"),
            .init(name: "Example.dmg", sizeText: "1MB", source: "Downloads"),
        ]
        let ids = model.files.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        model.selected = Set(ids)
        XCTAssertEqual(model.selected.count, 3)
        XCTAssertEqual(model.selectedSize, model.files.reduce(0) { $0 + $1.size })

        model.selected.remove(ids[0])
        XCTAssertEqual(model.files.filter { model.selected.contains($0.id) }.count, 2)
        XCTAssertEqual(model.selectedSize, model.files[1].size + model.files[2].size)
    }

    func testReviewResetsCategoryAndConsoleButPreservesReturnRoute() {
        let app = AppModel()
        app.cleanup.showList = true
        app.cleanup.listSection = "Old category"
        app.showConsole = true
        app.reviewFromSmartCare(.cleanup)
        XCTAssertFalse(app.cleanup.showList)
        XCTAssertNil(app.cleanup.listSection)
        XCTAssertFalse(app.showConsole)
        app.selection = .performance
        app.selection = .cleanup
        XCTAssertEqual(app.reviewOrigin, .cleanup)
    }

    func testSmartCareCannotRunACompletedOrIncompleteModule() {
        let app = AppModel()
        app.smartCare.phase = .results
        app.smartCare.enabled = [.projects, .installers]
        app.projects.selected = ["/tmp/build"]
        app.projects.stage = .review
        app.installers.selected = ["old"]
        app.installers.stage = .done
        XCTAssertTrue(app.smartCare.runnableModules(app).isEmpty)
        XCTAssertNil(app.smartCare.finding(.installers, app))
        app.smartCare.run(app)
        XCTAssertEqual(app.smartCare.phase, .results)
    }

    func testResetDoesNotDiscardAnIndependentScan() {
        let app = AppModel()
        app.projects.stage = .scanning
        app.smartCare.phase = .results
        app.smartCare.reset(app)
        XCTAssertEqual(app.projects.stage, .scanning)
        XCTAssertEqual(app.smartCare.phase, .results)
        app.projects.reset()
        XCTAssertEqual(app.projects.stage, .scanning)
    }

    func testDisabledOrbChangesPublicationSignature() {
        let enabled = OrbAction(title: "Remove", action: {})
        let disabled = OrbAction(title: "Remove", enabled: false, disabledReason: "Select files", action: {})
        XCTAssertNotEqual(enabled.signature, disabled.signature)
    }

    func testConsoleRevisionsIncludeSameLengthReplacementAndCompletion() {
        let log = ConsoleLog()
        let id = log.begin(ShellCommand("/bin/echo", []))
        log.mirror(id, ["first"])
        let first = log.entries.last!.revision
        log.mirror(id, ["other"])
        XCTAssertGreaterThan(log.entries.last!.revision, first)
        let second = log.entries.last!.revision
        log.finish(id, status: 0)
        XCTAssertGreaterThan(log.entries.last!.revision, second)
        log.replace(id, Array(repeating: "line", count: 4100))
        XCTAssertEqual(log.entries.last!.output.count, 4000)
        XCTAssertEqual(log.entries.last!.omittedLines, 100)
    }
}
