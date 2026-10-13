import MoleKit
import XCTest
@testable import Nora

final class StatusParsersTests: XCTestCase {
    // MARK: lsof -F

    func testLsofReadsProcessesAndPortsFromFieldFormat() {
        let text = """
        p101
        cExampleServer
        f3
        PTCP
        n*:8080
        TST=LISTEN
        TQR=0
        f4
        PTCP
        n*:8080
        TST=LISTEN
        p202
        cWorker\\x20One
        f5
        PTCP
        n[::1]:5432
        f6
        PTCP
        n127.0.0.1:5432
        p303
        cEstablishedOnly
        f7
        PTCP
        n10.0.0.2:51514->10.0.0.9:443

        """
        let ports = LsofParser.parse(text)
        XCTAssertEqual(ports.count, 2, "IPv4 and IPv6 on one port collapse to one row; established sockets are not listeners")
        XCTAssertEqual(ports[0], ListeningPort(pid: 101, process: "ExampleServer", address: "*", port: 8080))
        XCTAssertEqual(ports[1], ListeningPort(pid: 202, process: "Worker One", address: "[::1]", port: 5432))
    }

    func testLsofSplitsOnLastColon() {
        XCTAssertEqual(LsofParser.splitAddress("[::1]:5432")?.0, "[::1]")
        XCTAssertEqual(LsofParser.splitAddress("[::1]:5432")?.1, 5432)
        XCTAssertEqual(LsofParser.splitAddress("127.0.0.1:443")?.1, 443)
        XCTAssertNil(LsofParser.splitAddress("no-port-here"))
        XCTAssertNil(LsofParser.splitAddress("*:70000"), "ports above 65535 are rejected")
    }

    func testLsofEmptyOutputMeansNoListeners() {
        XCTAssertEqual(LsofParser.parse(""), [])
    }

    // MARK: nettop CSV

    private let nettopSamples = """
    ,bytes_in,bytes_out,
    Alpha.11,1000,200,
    Beta.22,500,50,
    ,bytes_in,bytes_out,
    Alpha.11,4000,1200,
    Beta.22,500,50,
    Gamma.33,10,10,
    """

    func testNettopSplitsSamplesOnHeaderLines() {
        let samples = NettopParser.samples(nettopSamples)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].count, 2)
        XCTAssertEqual(samples[1].count, 3)
        XCTAssertEqual(samples[1][0], NettopParser.Row(name: "Alpha", pid: 11, bytesIn: 4000, bytesOut: 1200))
    }

    func testNettopSplitsNameAndPidOnLastDot() {
        let row = NettopParser.splitProcess("Example.App.4411")
        XCTAssertEqual(row?.0, "Example.App")
        XCTAssertEqual(row?.1, 4411)
        XCTAssertNil(NettopParser.splitProcess("nopid"))
    }

    func testNettopFindsColumnsByHeaderName() {
        let reordered = """
        ,bytes_out,bytes_in,
        Alpha.11,7,9,
        """
        let rows = NettopParser.samples(reordered).first ?? []
        XCTAssertEqual(rows, [NettopParser.Row(name: "Alpha", pid: 11, bytesIn: 9, bytesOut: 7)])
    }

    // MARK: traffic delta

    func testTrafficRatesAreTheDeltaOverTheWindow() {
        let samples = NettopParser.samples(nettopSamples)
        let report = TrafficMath.report(first: samples[0], second: samples[1], seconds: 1)
        // Alpha: +3000 in, +1000 out. Beta: no change, so it is not listed. Gamma is new, so it has no baseline.
        XCTAssertEqual(report.down, [AppTraffic(name: "Alpha", downBytesPerSecond: 3000, upBytesPerSecond: 1000)])
        XCTAssertEqual(report.up, [AppTraffic(name: "Alpha", downBytesPerSecond: 3000, upBytesPerSecond: 1000)])
    }

    func testTrafficDividesByWindowAndGroupsPidsByName() {
        let first = [NettopParser.Row(name: "Example", pid: 1, bytesIn: 100, bytesOut: 0),
                     NettopParser.Row(name: "Example", pid: 2, bytesIn: 100, bytesOut: 0)]
        let second = [NettopParser.Row(name: "Example", pid: 1, bytesIn: 300, bytesOut: 0),
                      NettopParser.Row(name: "Example", pid: 2, bytesIn: 600, bytesOut: 0)]
        let report = TrafficMath.report(first: first, second: second, seconds: 2)
        XCTAssertEqual(report.down.count, 1)
        XCTAssertEqual(report.down.first?.downBytesPerSecond ?? -1, 350, accuracy: 0.0001)
    }

    func testRestartedProcessCountsAsZeroNotNegative() {
        let first = [NettopParser.Row(name: "Restarted", pid: 9, bytesIn: 5000, bytesOut: 5000)]
        let second = [NettopParser.Row(name: "Restarted", pid: 9, bytesIn: 40, bytesOut: 80)]
        let report = TrafficMath.report(first: first, second: second, seconds: 1)
        XCTAssertEqual(report, .empty)
    }

    func testTrafficKeepsFiveTopEntriesPerDirection() {
        let first = (1...7).map { NettopParser.Row(name: "App\($0)", pid: $0, bytesIn: 0, bytesOut: 0) }
        let second = (1...7).map { NettopParser.Row(name: "App\($0)", pid: $0, bytesIn: Int64($0) * 100, bytesOut: Int64(8 - $0) * 100) }
        let report = TrafficMath.report(first: first, second: second, seconds: 1)
        XCTAssertEqual(report.down.count, 5)
        XCTAssertEqual(report.down.first?.name, "App7")
        XCTAssertEqual(report.up.first?.name, "App1")
    }
}

@MainActor
final class DiskRateTests: XCTestCase {
    /// Mole's `disk_io` rates are MB/s already; the store and the label must show them as is.
    func testDiskRatesStayInMegabytesPerSecond() throws {
        let json = #"{"disk_io":{"read_rate":512.5,"write_rate":3.25}}"#
        let store = StatusStore()
        store.ingest(try StatusSnapshot.decode(Data(json.utf8)))
        XCTAssertEqual(store.diskRead.last, 512.5)
        XCTAssertEqual(store.diskWrite.last, 3.25)
    }
}
