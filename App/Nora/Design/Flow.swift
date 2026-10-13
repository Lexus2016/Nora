import SwiftUI

/// The steps every cleaning module goes through.
enum FlowStage: Equatable {
    case start, scanning, review, running, done
}

/// Start screen: glass object, title, three or four bullets, the exact command and the orb.
struct ModuleStart<Extra: View>: View {
    let module: Module
    let subtitle: LocalizedStringKey
    let bullets: [LocalizedStringKey]
    let command: String
    var scanTitle: LocalizedStringKey = "Scan"
    var busy = false
    let action: () -> Void
    @ViewBuilder var extra: Extra
    @State private var float = false

    var body: some View {
        HStack(spacing: 48) {
            GlassImage(name: module.glass, size: 300, glow: module.palette.glow)
                .offset(y: float ? -8 : 8)
                .rotation3DEffect(.degrees(float ? 3 : -3), axis: (x: 0.4, y: 1, z: 0))
                .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: float)
                .onAppear { float = true }
            VStack(alignment: .leading, spacing: 16) {
                SceneTitle(text: module.title, glow: module.palette.glow)
                Text(subtitle).font(.system(size: 16)).foregroundStyle(Palette.fg2)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(module.palette.glow).frame(width: 6, height: 6).shadow(color: module.palette.glow, radius: 4)
                            Text(bullet).font(.system(size: 14)).foregroundStyle(Palette.fg2)
                        }
                    }
                }
                extra
                CommandPreview(command: command).frame(maxWidth: 440)
                OrbButton(title: scanTitle, palette: module.palette, busy: busy, action: action)
                    .padding(.top, 8)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ModuleStart where Extra == EmptyView {
    init(module: Module, subtitle: LocalizedStringKey, bullets: [LocalizedStringKey], command: String,
         scanTitle: LocalizedStringKey = "Scan", busy: Bool = false, action: @escaping () -> Void) {
        self.init(module: module, subtitle: subtitle, bullets: bullets, command: command, scanTitle: scanTitle,
                  busy: busy, action: action, extra: { EmptyView() })
    }
}

/// Header of every step after the start: ← back (Esc, ⌘[), title and a trailing slot.
struct StepHeader<Trailing: View>: View {
    let module: Module
    let title: LocalizedStringKey
    var subtitle: String?
    let back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .modifier(GlassCircle())
                .keyboardShortcut(.cancelAction)
                .background(Button("", action: back).keyboardShortcut("[", modifiers: .command).hidden())
                .help(Text("Back"))
            }
            GlassImage(name: module.glass, size: 64, glow: module.palette.glow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 28, weight: .light)).shadow(color: module.palette.glow.opacity(0.5), radius: 12)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.fg2) }
            }
            Spacer()
            trailing
        }
    }
}

extension StepHeader where Trailing == EmptyView {
    init(module: Module, title: LocalizedStringKey, subtitle: String? = nil, back: (() -> Void)?) {
        self.init(module: module, title: title, subtitle: subtitle, back: back, trailing: { EmptyView() })
    }
}

struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle()).overlay(Circle().strokeBorder(Palette.line2, lineWidth: 0.5))
        }
    }
}

/// Scanning or running: pulsing object, what is happening, the last lines of output and Stop.
struct WorkingView: View {
    let module: Module
    let title: LocalizedStringKey
    var lines: [String] = []
    var onStop: (() -> Void)?
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            GlassImage(name: module.glass, size: 220, glow: module.palette.glow)
                .scaleEffect(pulse ? 1.04 : 0.97)
                .shadow(color: module.palette.glow.opacity(pulse ? 0.9 : 0.3), radius: pulse ? 46 : 18)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            Text(title).font(.system(size: 26, weight: .light))
            ProgressView().progressViewStyle(.linear).tint(module.palette.glow).frame(width: 280)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.mono).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(width: 520, alignment: .leading)
            }
            if let onStop {
                Button("Stop", action: onStop).buttonStyle(GlassButtonStyle()).keyboardShortcut(".", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Result screen: the headline number, Mole's own summary lines and Done.
struct DoneView: View {
    let module: Module
    let headline: String
    var lines: [String] = []
    var failed = false
    let onDone: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 18) {
            GlassImage(name: module.glass, size: 200, glow: failed ? Palette.crit : module.palette.glow)
            Text(failed ? String(localized: "Something went wrong") : String(localized: "Done!"))
                .font(.system(size: 18)).foregroundStyle(Palette.fg2)
            Text(headline).font(.system(size: 44, weight: .light, design: .rounded)).multilineTextAlignment(.center)
                .shadow(color: module.palette.glow.opacity(0.6), radius: 18)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 13)).foregroundStyle(Palette.fg2).textSelection(.enabled)
                    }
                }
                .padding(16).frame(maxWidth: 560, alignment: .leading).glassPanel()
            }
            HStack(spacing: 10) {
                Button("Show log") { app.showConsole = true }.buttonStyle(GlassButtonStyle())
                Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle(glow: module.palette.glow)).keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// A row with a checkbox, a title, an optional detail line and a size.
struct CheckRow: View {
    @Binding var isOn: Bool
    let title: String
    var detail: String?
    var size: Int64?
    var tint: Color = Palette.pink

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 8)
                if let size { Text(Format.bytes(size)).font(.system(size: 12, design: .rounded)).monospacedDigit().foregroundStyle(Palette.fg2) }
            }
        }
        .toggleStyle(.checkbox)
        .tint(tint)
        .padding(.vertical, 3)
    }
}

/// Small notice line used for skipped sections and warnings.
struct Notice: View {
    let text: String
    var symbol = "exclamationmark.circle"
    var color = Palette.warn

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: symbol) }
            .font(.system(size: 12))
            .foregroundStyle(color)
    }
}
