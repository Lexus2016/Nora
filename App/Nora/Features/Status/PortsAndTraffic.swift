import Foundation
import MoleKit

/// A TCP port in LISTEN state, as `lsof` reports it.
struct ListeningPort: Sendable, Equatable, Identifiable {
    let pid: Int
    let process: String
    let address: String
    let port: Int

    var id: String { "\(pid) \(address):\(port)" }
}

/// Per-process traffic: rate over the sampling window.
struct AppTraffic: Sendable, Equatable, Identifiable {
    let name: String
    let downBytesPerSecond: Double
    let upBytesPerSecond: Double

    var id: String { name }
}

/// Top processes by download and by upload, five each.
struct TrafficReport: Sendable, Equatable {
    let down: [AppTraffic]
    let up: [AppTraffic]

    static let empty = TrafficReport(down: [], up: [])
}

/// `lsof -nP -iTCP -sTCP:LISTEN -F pcnPT`. Each field is one line tagged by its first character:
/// `p` starts a process, `c` names it, `f` starts a file, `P` is the protocol, `n` is the address.
enum LsofParser {
    static func parse(_ output: String) -> [ListeningPort] {
        var result: [ListeningPort] = []
        var seen: Set<String> = []
        var pid: Int?
        var command = ""

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int(value)
                command = ""
            case "c":
                command = value.replacingOccurrences(of: "\\x20", with: " ")
            case "n":
                guard let pid, !value.contains("->"), let (address, port) = splitAddress(value) else { continue }
                // IPv4 and IPv6 sockets on the same port show up as two lines; keep one.
                guard seen.insert("\(pid) \(port)").inserted else { continue }
                result.append(ListeningPort(pid: pid, process: command, address: address, port: port))
            default:
                continue
            }
        }
        return result.sorted { ($0.process, $0.port) < ($1.process, $1.port) }
    }

    /// Splits on the last colon, so `[::1]:5432` and `*:7000` both work.
    static func splitAddress(_ name: String) -> (String, Int)? {
        guard let colon = name.lastIndex(of: ":") else { return nil }
        let host = String(name[..<colon])
        guard let port = Int(name[name.index(after: colon)...]), (0...65535).contains(port) else { return nil }
        return (host, port)
    }
}

/// `nettop -P -L 2 -s 1 -x -J bytes_in,bytes_out`: CSV blocks, one per sample. Each block starts
/// with a header such as `,bytes_in,bytes_out,` and rows read `name.pid,bytes_in,bytes_out,`.
enum NettopParser {
    struct Row: Sendable, Equatable {
        let name: String
        let pid: Int
        let bytesIn: Int64
        let bytesOut: Int64
    }

    /// Columns are found by header name, so a reordered header still parses.
    static func samples(_ output: String) -> [[Row]] {
        var samples: [[Row]] = []
        var columns: (inIndex: Int, outIndex: Int)?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            if line.hasPrefix(",") {
                // Header line: a new sample begins.
                guard let i = fields.firstIndex(of: "bytes_in"), let o = fields.firstIndex(of: "bytes_out") else {
                    columns = nil
                    continue
                }
                columns = (i, o)
                samples.append([])
                continue
            }
            guard let columns, fields.count > max(columns.inIndex, columns.outIndex) else { continue }
            guard let (name, pid) = splitProcess(fields[0]),
                  let bytesIn = Int64(fields[columns.inIndex]),
                  let bytesOut = Int64(fields[columns.outIndex]) else { continue }
            samples[samples.count - 1].append(Row(name: name, pid: pid, bytesIn: bytesIn, bytesOut: bytesOut))
        }
        return samples
    }

    /// `name.pid`, split on the last dot, since process names can contain dots.
    static func splitProcess(_ key: String) -> (String, Int)? {
        guard let dot = key.lastIndex(of: "."), let pid = Int(key[key.index(after: dot)...]) else { return nil }
        let name = String(key[..<dot])
        return name.isEmpty ? nil : (name, pid)
    }
}

/// Turns two `nettop` samples into rates. Counters are cumulative, so the rate is the difference
/// over the window; a process that restarted (counter went down) counts as zero.
enum TrafficMath {
    static func report(first: [NettopParser.Row], second: [NettopParser.Row], seconds: Double, top: Int = 5) -> TrafficReport {
        guard seconds > 0 else { return .empty }
        var byPid: [Int: NettopParser.Row] = [:]
        for row in first { byPid[row.pid] = row }

        var down: [String: Double] = [:]
        var up: [String: Double] = [:]
        for row in second {
            guard let before = byPid[row.pid] else { continue }
            down[row.name, default: 0] += Double(max(0, row.bytesIn - before.bytesIn)) / seconds
            up[row.name, default: 0] += Double(max(0, row.bytesOut - before.bytesOut)) / seconds
        }
        let names = Set(down.keys).union(up.keys)
        let all = names.map { AppTraffic(name: $0, downBytesPerSecond: down[$0] ?? 0, upBytesPerSecond: up[$0] ?? 0) }
        return TrafficReport(
            down: Array(all.filter { $0.downBytesPerSecond > 0 }.sorted { $0.downBytesPerSecond > $1.downBytesPerSecond }.prefix(top)),
            up: Array(all.filter { $0.upBytesPerSecond > 0 }.sorted { $0.upBytesPerSecond > $1.upBytesPerSecond }.prefix(top))
        )
    }
}

/// Runs the two read-only commands. Cancelling the task terminates the children (ProcessRunner does that).
enum PortsAndTrafficSampler {
    private static let environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    static func listeningPorts() async -> [ListeningPort]? {
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/sbin/lsof"),
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT"],
            environment: environment
        ) else { return nil }
        // lsof exits 1 when nothing listens; that is an empty list, not an error.
        return LsofParser.parse(result.stdout)
    }

    /// nettop takes about two seconds: the two samples are one second apart.
    static func traffic() async -> TrafficReport? {
        guard let result = try? await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/nettop"),
            ["-P", "-L", "2", "-s", "1", "-x", "-J", "bytes_in,bytes_out"],
            environment: environment
        ) else { return nil }
        let samples = NettopParser.samples(result.stdout)
        guard samples.count >= 2 else { return nil }
        // The window between the two samples is nettop's `-s 1` interval.
        return TrafficMath.report(first: samples[0], second: samples[1], seconds: 1)
    }
}
