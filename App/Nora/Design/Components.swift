import SwiftUI

/// A small line chart; `max` fixes the scale (100 for percentages).
struct Sparkline: View {
    let values: [Double]
    var color: Color = Palette.pink
    var maxValue: Double?
    var fill = true

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, in: geo.size, maxValue: maxValue)
            ZStack {
                if fill, points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    points.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .accessibilityHidden(true)
    }

    static func points(_ values: [Double], in size: CGSize, maxValue: Double?) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let top = max(maxValue ?? (values.max() ?? 1) * 1.15, 0.0001)
        let step = size.width / CGFloat(StatusStore.historyLength - 1)
        let offset = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: offset + CGFloat(i) * step, y: size.height - CGFloat(min(v / top, 1)) * size.height)
        }
    }
}

/// A frosted card with a small caption.
struct Card<Content: View>: View {
    let title: LocalizedStringKey
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .semibold)).textCase(.uppercase).tracking(0.6)
            }
            .foregroundStyle(Palette.muted)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassPanel()
    }
}

/// Horizontal fill bar; colour turns amber and pink at 75% and 90%.
struct Meter: View {
    let fraction: Double
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 6)
        .accessibilityValue(Text(Format.percent(fraction * 100)))
    }

    private var color: Color {
        if let tint { return tint }
        return fraction >= 0.9 ? Palette.crit : fraction >= 0.75 ? Palette.warn : Palette.good
    }
}

/// Label on the left, value on the right.
struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.white).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

/// The exact command an action will run, shown before it runs when Settings → Mole → Commands is
/// on (off by default; the console always lists every command). The copy button gives the
/// Terminal form: `sudo -A` needs Nora's password dialog, so it is copied as plain `sudo`.
struct CommandPreview: View {
    let command: String
    /// Settings → Mole → Commands. Off by default; the console always has the commands.
    static let settingKey = "showCommands"
    @AppStorage(CommandPreview.settingKey) private var visible = false
    /// Dark enough for the command text to keep 4.5:1 on the brightest scene (SceneContrastTests).
    static let chipOpacity = 0.5

    /// The command as it runs in Terminal: a `sudo -A` that starts a command becomes `sudo`.
    /// Text inside arguments is left alone.
    static func terminalForm(_ command: String) -> String {
        // Walk the line once, tracking single quotes (the only quoting ShellCommand uses), and drop
        // "-A " only from a sudo that starts a command outside quotes.
        var out = "", quoted = false, atCommandStart = true
        var rest = Substring(command)
        while let character = rest.first {
            if !quoted, atCommandStart, rest.hasPrefix("sudo -A ") {
                out += "sudo "
                rest = rest.dropFirst("sudo -A ".count)
                atCommandStart = false
                continue
            }
            // ShellCommand writes an apostrophe as '\'': outside quotes a backslash escapes the next
            // character, which then neither opens nor closes a quote.
            if !quoted, character == "\\", rest.count > 1 {
                out.append(contentsOf: rest.prefix(2))
                rest = rest.dropFirst(2)
                atCommandStart = false
                continue
            }
            if character == "'" { quoted.toggle() }
            out.append(character)
            rest = rest.dropFirst()
            if !quoted {
                if out.hasSuffix("; ") || out.hasSuffix("&& ") { atCommandStart = true } else if character != " " { atCommandStart = false }
            }
        }
        return out
    }

    var body: some View {
        if visible {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 11))
            Text(command).font(.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.terminalForm(command), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain)
            .help(Text("Copy command"))
        }
        .foregroundStyle(Palette.fg2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.black.opacity(Self.chipOpacity), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Health score ring 0–100.
struct HealthRing: View {
    let score: Int?
    var size: CGFloat = 92

    var body: some View {
        let value = Double(score ?? 0) / 100
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: value)
                .stroke(AngularGradient(colors: [Palette.pink, Palette.cyan, Palette.good, Palette.pink], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: Palette.cyan.opacity(0.5), radius: 6)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "—").font(.system(size: size * 0.3, weight: .medium, design: .rounded))
                Text("Health").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: score)
    }
}
