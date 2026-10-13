import SwiftUI

/// The steps every cleaning module goes through.
enum FlowStage: Equatable {
    case start, scanning, review, running, done
}

/// A bullet on a module's start screen: a small tinted glass disc with a symbol and a label.
struct Feature: Identifiable {
    let symbol: String
    let text: LocalizedStringKey
    var id: String { symbol }
}

/// The frame of every module step: top bar and content. The round action is published to
/// `OrbController`, which draws it in a child window over the window's bottom edge.
struct ModuleScene<Content: View>: View {
    let module: Module
    var leading: TopBarAction?
    var orb: OrbAction?
    @ViewBuilder var content: Content
    @Environment(AppModel.self) private var app
    @State private var owner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: module.title, leading: leading)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(height: orb == nil ? 16 : OrbController.clearance)
        }
        .background(alignment: .top) { HeaderShade(palette: module.palette) }
        .onAppear { app.orb.publish(orb, palette: module.palette, owner: owner) }
        .onChange(of: orb?.signature) { app.orb.publish(orb, palette: module.palette, owner: owner) }
        .onDisappear { app.orb.withdraw(owner: owner) }
    }
}

struct OrbAction {
    let title: String
    var busy = false
    var destructive = false
    let action: () -> Void

    var signature: String { "\(title)|\(busy)|\(destructive)" }
}

/// The big round action button with a specular highlight; busy shows a spinning ring.
struct BottomOrb: View {
    let action: OrbAction
    let palette: ScenePalette
    @State private var hovering = false
    @State private var spin = false

    var body: some View {
        Button(action: action.action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.blend(with: .white, by: 0.35), tint, tint.blend(with: palette.depth, by: 0.45)],
                                         center: UnitPoint(x: 0.5, y: 0.25), startRadius: 2, endRadius: 64))
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2.5)
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 64, height: 27).offset(y: -30).blur(radius: 1.5)
                Text(LocalizedStringKey(action.title))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.horizontal, 12)
            }
            .frame(width: OrbController.diameter, height: OrbController.diameter)
            .overlay {
                if action.busy {
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .padding(-9)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }
                    Circle().stroke(.white.opacity(0.18), lineWidth: 5).padding(-9)
                }
            }
            .shadow(color: tint.opacity(hovering ? 0.95 : 0.7), radius: hovering ? 46 : 34)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(Text(LocalizedStringKey(action.title)))
    }

    private var tint: Color { action.destructive ? Palette.pink : palette.glow.blend(with: palette.body, by: 0.25) }
}

/// Start screen: the module's glass object on the left, what it does on the right.
struct ModuleStart<Extra: View>: View {
    let module: Module
    let subtitle: LocalizedStringKey
    let features: [Feature]
    let command: String
    var scanTitle: String = "Scan"
    let action: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        ModuleScene(module: module, orb: OrbAction(title: scanTitle, action: action)) {
            HStack(spacing: 56) {
                Glass3D(name: module.glass, size: 340, glow: module.palette.glow, amplitude: 9, period: 7)
                VStack(alignment: .leading, spacing: 18) {
                    Text(module.title)
                        .font(.system(size: 60, weight: .light))
                    Text(subtitle).font(.system(size: 18)).foregroundStyle(Palette.fg2).lineSpacing(3)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(features) { feature in
                            HStack(spacing: 14) {
                                FeatureDisc(symbol: feature.symbol, tint: module.palette.glow)
                                Text(feature.text).font(.system(size: 17, weight: .semibold))
                            }
                        }
                    }
                    .padding(.top, 6)
                    extra
                    CommandPreview(command: command).frame(maxWidth: 420).padding(.top, 4)
                }
                .frame(maxWidth: 470, alignment: .leading)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ModuleStart where Extra == EmptyView {
    init(module: Module, subtitle: LocalizedStringKey, features: [Feature], command: String,
         scanTitle: String = "Scan", action: @escaping () -> Void) {
        self.init(module: module, subtitle: subtitle, features: features, command: command, scanTitle: scanTitle,
                  action: action, extra: { EmptyView() })
    }
}

/// Small glossy disc with a white symbol (the bullets on start screens and card icons).
struct FeatureDisc: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [tint.blend(with: .white, by: 0.35), tint, tint.blend(with: .black, by: 0.35)],
                                         center: UnitPoint(x: 0.5, y: 0.25), startRadius: 1, endRadius: size * 0.7))
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.7)
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.45), radius: 6)
    }
}

/// Scanning or running: the object in the middle, a large line about what is happening, the
/// current item under it, and Stop in the orb.
struct WorkingView: View {
    let module: Module
    let title: LocalizedStringKey
    var detail: String?
    var onStop: (() -> Void)?

    var body: some View {
        ModuleScene(module: module, orb: onStop.map { OrbAction(title: "Stop", busy: true, action: $0) }) {
            VStack(spacing: 26) {
                Spacer(minLength: 0)
                Glass3D(name: module.glass, size: 300, glow: module.palette.glow)
                VStack(spacing: 10) {
                    Text(title).font(.system(size: 50, weight: .light))
                    Text(detail ?? " ").font(.system(size: 17)).foregroundStyle(Palette.fg2)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 620)
                        .animation(nil, value: detail)
                }
                if onStop == nil { ProgressView().progressViewStyle(.linear).tint(.white).frame(width: 260) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
        }
    }

    /// The last meaningful line of command output, shown as "what is being looked at now".
    static func currentItem(_ lines: [String]) -> String? {
        lines.reversed().lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("=") }
            .map { $0.replacingOccurrences(of: "→ ", with: "").replacingOccurrences(of: "✓ ", with: "") }
    }
}

/// A result card: what was found in one category, with Review and an optional one-click action.
/// A large card carries the module's glass object bleeding off its corner, like CleanMyMac.
struct CategoryCard: View {
    let value: String
    let caption: String
    var detail: String?
    let symbol: String
    let tint: Color
    var large = false
    var glass: String?
    var reviewTitle: LocalizedStringKey = "Review"
    var actionTitle: LocalizedStringKey?
    let review: () -> Void
    var action: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(value).font(.system(size: large ? 40 : 28, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                    Text(caption).font(.system(size: large ? 18 : 15, weight: .semibold)).foregroundStyle(Palette.fg2).lineLimit(2)
                }
                Spacer(minLength: 8)
                if glass == nil { FeatureDisc(symbol: symbol, tint: tint, size: 44) }
            }
            if let detail { Text(detail).font(.system(size: 15)).foregroundStyle(Palette.fg2).lineLimit(4).frame(maxWidth: 320, alignment: .leading) }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(reviewTitle, action: review).buttonStyle(GlassButtonStyle()).fixedSize()
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle(glow: tint)).fixedSize()
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(alignment: .bottomLeading) {
            if let glass {
                GlassImage(name: glass, size: 250, glow: tint).offset(x: -56, y: 64).opacity(0.95)
            }
        }
        .background(VolumeFill(radius: 22))
        .clipShape(shape)
        .volumeCard(radius: 22, tint: tint)
    }
}

/// Header of a results or review step: the big sentence and an optional button under it.
struct ResultHeadline: View {
    let text: String
    var button: (LocalizedStringKey, () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Text(text).font(.system(size: 32, weight: .semibold)).multilineTextAlignment(.center)
            if let button {
                Button(button.0, action: button.1).buttonStyle(GlassButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
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
        ModuleScene(module: module, leading: .startOver(onDone), orb: OrbAction(title: "Done", action: onDone)) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                GlassImage(name: module.glass, size: 230, glow: failed ? Palette.crit : module.palette.glow)
                Text(failed ? String(localized: "Something went wrong") : String(localized: "Well done!"))
                    .font(.system(size: 18)).foregroundStyle(Palette.fg2)
                Text(headline).font(.system(size: 46, weight: .light, design: .rounded)).multilineTextAlignment(.center)
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 13)).foregroundStyle(Palette.fg2).textSelection(.enabled)
                        }
                    }
                    .padding(16).frame(maxWidth: 560, alignment: .leading).glassPanel()
                }
                Button("Show log") { app.showConsole = true }.buttonStyle(GlassButtonStyle())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 40)
        }
    }
}

/// Header of a detailed review list.
struct StepHeader<Trailing: View>: View {
    let module: Module
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            GlassImage(name: module.glass, size: 64, glow: module.palette.glow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 30, weight: .light))
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Palette.fg2) }
            }
            Spacer()
            trailing
        }
    }
}

extension StepHeader where Trailing == EmptyView {
    init(module: Module, title: LocalizedStringKey, subtitle: String? = nil) {
        self.init(module: module, title: title, subtitle: subtitle, trailing: { EmptyView() })
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
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(VolumeFill(radius: 9))
    }
}

/// The bottom strip of a review list: the exact command, a note, and the main action.
struct ReviewFooter: View {
    /// Nil when the action is Nora's own file work rather than a command; the note explains it.
    let command: String?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command { CommandPreview(command: command).frame(maxWidth: 520) }
            if let note { Text(note).font(.system(size: 11)).foregroundStyle(Palette.fg2).padding(.horizontal, 4) }
        }
        .padding(8)
        .background(VolumeFill(radius: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gentle left-right rocking around the vertical axis with perspective, so a glass object shows
/// its depth while its module works.
struct Rocking: ViewModifier {
    var amplitude: Double = 24
    var period: Double = 2.6
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(phase ? amplitude : -amplitude), axis: (x: 0.12, y: 1, z: 0.04), anchor: .center, perspective: 0.55)
            .rotation3DEffect(.degrees(phase ? -4 : 4), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
            .offset(y: phase ? -5 : 5)
            .brightness(phase ? 0.05 : -0.03)
            .animation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

extension View {
    func rocking(amplitude: Double = 24, period: Double = 2.6) -> some View {
        modifier(Rocking(amplitude: amplitude, period: period))
    }

    /// A card with depth: lit top edge, soft inner shade at the bottom, deep drop shadow.
    func volumeCard(radius: CGFloat, tint: Color) -> some View {
        modifier(VolumeCard(radius: radius, tint: tint))
    }
}

/// The body of a volume card: a light, slightly brighter top over the scene colour.
struct VolumeFill: View {
    let radius: CGFloat
    @Environment(\.scenePalette) private var palette

    var body: some View {
        // Smoked glass in the scene's own depth colour, so cards stay in the scene's hue and white
        // text stays readable over its brightest glow; a faint sheen along the top keeps the volume.
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(palette.depth.opacity(palette.cardScrim))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom)))
    }
}

/// Crisp card edge like CleanMyMac: a clear 1 pt light border, brighter along the top, and a
/// short soft shadow that lifts the card without blurring it.
struct VolumeCard: ViewModifier {
    let radius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.16)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
    }
}
