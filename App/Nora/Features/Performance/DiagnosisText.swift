import Foundation
import MoleKit

/// Mole's "Performance diagnosis" in Nora's language. Mole prints a fixed set of sentences
/// (lib/optimize/diagnostics.sh in 1.59); each known one, and each known pattern with numbers,
/// is rewritten here with sizes in Nora's format. A line Nora does not know stays as Mole wrote it.
enum DiagnosisText {
    struct Holder: Hashable {
        let name: String
        let size: String
    }

    private static let icons = ["◎ ", "⊙ ", "• ", "ℹ ", "✓ ", "→ "]

    /// Findings to read, and the processes that hold the most memory. Findings start with one of
    /// Mole's icons; the process rows under the memory finding have none.
    static func split(_ diagnosis: [String]) -> (lines: [String], holders: [Holder]) {
        var lines: [String] = [], holders: [Holder] = []
        for raw in diagnosis {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !icons.contains(where: line.hasPrefix), let holder = holder(line) { holders.append(holder) } else { lines.append(localize(line)) }
        }
        return (lines, holders)
    }

    static func localize(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        for icon in icons where line.hasPrefix(icon) { line.removeFirst(icon.count) }
        if let fixed = fixed[line] { return fixed }
        if let m = line.firstMatch(of: #/^Likely bottleneck: (.+) \(~([\d.]+)% CPU sustained\)$/#) {
            return String(localized: "Likely cause: \(family(String(m.1))), about \(num(m.2))% of the processor for a long time")
        }
        if let m = line.firstMatch(of: #/^Memory pressure: swap (\S+) of (\S+) used \((\d+)%\), (\d+)% free$/#) {
            return String(localized: "Memory is tight: swap \(size(m.1)) of \(size(m.2)) in use (\(num(m.3))%), \(num(m.4))% of memory free")
        }
        if let m = line.firstMatch(of: #/^Gatekeeper status: (.+)$/#) {
            return String(localized: "Gatekeeper: \(String(m.1))")
        }
        if let m = line.firstMatch(of: #/^Virtual machine holding (\S+) with no running containers \(likely Docker Desktop\)$/#) {
            return String(localized: "A virtual machine holds \(size(m.1)) with no containers running, most likely Docker Desktop")
        }
        if let m = line.firstMatch(of: #/^Virtual machine holding (\S+)$/#) {
            return String(localized: "A virtual machine holds \(size(m.1))")
        }
        if let m = line.firstMatch(of: #/^Virtual machine using (\S+)(?: \((\d+) containers running\))?$/#) {
            if let running = m.2 { return String(localized: "A virtual machine uses \(size(m.1)), containers running: \(String(running))") }
            return String(localized: "A virtual machine uses \(size(m.1))")
        }
        if let m = line.firstMatch(of: #/^(.+) has burned ([\d.]+)h CPU over ([\d.]+)h of runtime \(~([\d.]+)% sustained\)$/#) {
            return String(localized: "\(String(m.1)) has used \(num(m.2)) h of processor time in \(num(m.3)) h of running (about \(num(m.4))%)")
        }
        if let m = line.firstMatch(of: #/^Sustained for its whole lifetime; if it is not doing real work: (kill -TERM \d+)$/#) {
            return String(localized: "It has done this since it started. If it is not doing real work, stop it: \(String(m.1))")
        }
        if let m = line.firstMatch(of: #/^Would offer detach for (\d+) mounted image\(s\)$/#) {
            return String(localized: "Mounted disk images that could be detached: \(String(m.1))")
        }
        if let m = line.firstMatch(of: #/^(.+) ~([\d.]+)%$/#) {
            return "\(family(String(m.1))) ~\(num(m.2))%"
        }
        return line
    }

    /// `name<padding>size` rows under the memory finding. Long reverse-DNS names arrive cut from
    /// the left ("…m.apple.WebKit.WebContent"); their last two parts name the service.
    static func holder(_ line: String) -> Holder? {
        guard let m = line.firstMatch(of: #/^(\S.*?)\s+([\d.]+(?:B|KB|MB|GB|TB))$/#), MoleSize.parse(String(m.2)) != nil else { return nil }
        var name = String(m.1)
        let cut = name.hasPrefix("…")
        if cut { name.removeFirst() }
        let parts = name.split(separator: ".")
        if parts.count >= 3 { name = parts.suffix(2).joined(separator: " ") } else if cut { name = "…" + name }
        return Holder(name: name, size: size(m.2))
    }

    /// Mole's "73.8" in the reader's notation ("73,8" in Ukrainian).
    private static func num(_ text: Substring) -> String {
        Double(String(text)).map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? String(text)
    }

    private static func size(_ text: Substring) -> String {
        MoleSize.parse(String(text)).map { Format.bytes($0) } ?? String(text)
    }

    private static func family(_ label: String) -> String {
        switch label {
        case "Spotlight indexing": String(localized: "Spotlight indexing")
        case "CoreSimulator disk images": String(localized: "CoreSimulator disk images")
        default: label
        }
    }

    private static let fixed: [String: String] = [
        "No sustained high-CPU bottleneck detected": String(localized: "Nothing has kept the processor busy for long."),
        "Additional sustained pressure:": String(localized: "Also busy for a long time:"),
        "External enterprise agent pressure detected. Mole will not terminate enterprise security processes; restart or policy checks must happen outside Mole.":
            String(localized: "A corporate security agent is busy. Nora and Mole do not stop such agents; a restart or a policy check has to happen outside Nora."),
        "Gatekeeper and code-signature assessment activity is elevated.":
            String(localized: "Gatekeeper is busy checking app signatures."),
        "Desktop composition is busy. When another family is higher, treat this as a likely symptom rather than the root cause.":
            String(localized: "The system is busy drawing windows. If something else is higher, this is more likely a symptom than the cause."),
        "Metadata indexing or import work is consuming CPU.":
            String(localized: "Spotlight is indexing files and using the processor."),
        "Simulator runtime disk-image services are active.":
            String(localized: "Xcode simulator disk-image services are running."),
        "Only system-managed CoreSimulator images are mounted, informational only, not a detach target":
            String(localized: "Only the system's own simulator images are mounted. Nothing to detach."),
        "pressure is spread across many small processes":
            String(localized: "Memory is spread across many small processes."),
        "If this is Docker Desktop, quitting it reclaims all of it; it reserves memory even when idle":
            String(localized: "If this is Docker Desktop, quitting it frees all of this memory: it keeps it even when idle."),
        "Check Docker Desktop, UTM, or other virtualization tools for reclaimable memory":
            String(localized: "Check Docker Desktop, UTM or other virtual machine apps: they may free memory."),
        "Review these mounted images and detach any you no longer need":
            String(localized: "Look through these mounted disk images and detach the ones you no longer need."),
        "Mounted image adds assessment overhead:": String(localized: "A mounted disk image slows down app checks:"),
        "Mounted images add assessment overhead:": String(localized: "Mounted disk images slow down app checks:"),
    ]
}
