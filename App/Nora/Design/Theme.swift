import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Fixed colours shared by every scene (prototype tokens).
enum Palette {
    static let window = Color(hex: 0x140A26)
    static let desk = Color(hex: 0x0A0612)
    static let ink = Color(hex: 0x1B1033)
    static let fg2 = Color.white.opacity(0.82)
    /// Hints and small captions. Bright enough for 4.5:1 on every card (SceneContrastTests).
    static let mutedOpacity = 0.78
    static let muted = Color.white.opacity(mutedOpacity)
    static let surface = Color.white.opacity(0.09)
    static let surface2 = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.13)
    static let line2 = Color.white.opacity(0.24)
    static let good = Color(hex: 0x62F5B5)
    static let warn = Color(hex: 0xFFD36E)
    static let crit = Color(hex: 0xFF6B98)
    static let pink = Color(hex: 0xFF3EA5)
    static let cyan = Color(hex: 0x2EE6FF)
    static let amber = Color(hex: 0xFFB02E)
    static let violet = Color(hex: 0xC98BFF)
    static let series: [Color] = [Color(hex: 0x2EE6D6), Color(hex: 0xFFB02E), Color(hex: 0x8B97FF),
                                  Color(hex: 0xFF6B98), Color(hex: 0xB9F45F), Color(hex: 0xC98BFF), Color(hex: 0xA3ABC0)]
}

/// The three colours of a module scene: glow, body, depth. `cardScrim` is how much of the depth
/// colour a card lays over the scene so card text keeps 4.5:1 on its brightest part
/// (SceneContrastTests measures it).
struct ScenePalette: Equatable {
    let glow: Color
    let body: Color
    let depth: Color
    let cardScrim: Double

    init(_ glow: UInt32, _ body: UInt32, _ depth: UInt32, cardScrim: Double = 0.35) {
        self.glow = Color(hex: glow)
        self.body = Color(hex: body)
        self.depth = Color(hex: depth)
        self.cardScrim = cardScrim
    }
}

extension EnvironmentValues {
    /// The scene a view sits on, so cards can keep their text readable on bright scenes.
    @Entry var scenePalette = Module.smartCare.palette
}

/// Full-bleed neon background of a module scene (prototype `.scene`).
struct SceneBackground: View {
    let palette: ScenePalette

    var body: some View {
        // Saturated like CleanMyMac: a bright pool of colour near the object, the body colour across,
        // and a depth that stays coloured instead of muddy.
        ZStack {
            LinearGradient(stops: [.init(color: palette.body.blend(with: palette.glow, by: 0.18), location: 0),
                                   .init(color: palette.depth.blend(with: palette.body, by: 0.38), location: 0.85)],
                           startPoint: UnitPoint(x: 0.05, y: 0), endPoint: UnitPoint(x: 0.95, y: 1))
            EllipticalGradient(colors: [palette.body.opacity(0.75), .clear], center: UnitPoint(x: 0.95, y: 0.02),
                               startRadiusFraction: 0, endRadiusFraction: 0.62)
            EllipticalGradient(colors: [palette.glow.opacity(0.62), palette.glow.opacity(0.12), .clear], center: UnitPoint(x: 0.3, y: 0.52),
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
        }
        .saturation(1.3)
        .ignoresSafeArea()
    }
}

/// Darkens the top of a module scene behind its header with the same depth colour and opacity
/// as the cards, so header subtitles keep 4.5:1 on bright scenes (SceneContrastTests).
struct HeaderShade: View {
    let palette: ScenePalette

    var body: some View {
        let shade = palette.depth.opacity(palette.cardScrim)
        LinearGradient(stops: [.init(color: shade, location: 0), .init(color: shade, location: 0.62),
                               .init(color: palette.depth.opacity(0), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 250)
            .allowsHitTesting(false)
    }
}

/// Large light heading with the module's glow (prototype `.title`).
struct SceneTitle: View {
    let text: LocalizedStringKey
    let glow: Color

    var body: some View {
        Text(text)
            .font(.system(size: 44, weight: .light, design: .default))
            .tracking(-0.4)
            .foregroundStyle(.white)
            
    }
}

extension Font {
    static let numberLarge = Font.system(size: 34, weight: .medium, design: .rounded)
    static let numberMedium = Font.system(size: 22, weight: .medium, design: .rounded)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Buttons

/// Glossy white primary button (prototype `.btn.primary`).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    var glow: Color = Palette.pink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(Color(hex: 0x111111))
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(configuration.isPressed ? Color(hex: 0xE8E8E8) : .white))
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            .scaleEffect(configuration.isPressed && DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? 0.97 : 1)
            .animation(DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? .easeOut(duration: 0.15) : nil, value: configuration.isPressed)
    }
}

/// Frosted secondary button; real Liquid Glass on macOS 26 and later.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(configuration.isPressed ? 0.36 : 0.24)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
    }
}

/// Glossy pink button for actions that delete.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(Capsule().fill(LinearGradient(colors: [Color(hex: 0xFF7AB8), Palette.pink, Color(hex: 0xD61F7E)],
                                                      startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.5))
            .shadow(color: Palette.pink.opacity(0.45), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed && DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? 0.97 : 1)
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.06)).interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line2, lineWidth: 0.5))
        }
    }
}

/// Rounded frosted panel used for cards and lists.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(VolumeFill(radius: radius))
            .overlay(shape.strokeBorder(Color.white.opacity(0.17), lineWidth: 1))
    }
}

extension View {
    func glassPanel(radius: CGFloat = 18) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// The round *Scan* button: a glass orb with a specular highlight (prototype `.orb`).
struct OrbButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    let title: LocalizedStringKey
    let palette: ScenePalette
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [palette.glow.blend(with: .white, by: 0.3), palette.glow, palette.glow.blend(with: palette.body, by: 0.5)],
                                         center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: 80))
                Circle().strokeBorder(.white.opacity(0.55), lineWidth: 2)
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 84, height: 40)
                    .offset(y: -36)
                    .blur(radius: 2)
                if busy {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                }
            }
            .frame(width: 132, height: 132)
            .background(Circle().stroke(.white.opacity(0.07), lineWidth: 18))
            .shadow(color: palette.glow.opacity(hovering ? 0.95 : 0.75), radius: hovering ? 44 : 35)
            .scaleEffect(hovering && DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? 1.03 : 1)
            .animation(DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState) ? .easeOut(duration: 0.2) : nil, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(busy)
        .accessibilityLabel(Text(title))
    }
}

extension Color {
    /// Linear sRGB mix, like CSS `color-mix(in srgb, a, b p%)`.
    func blend(with other: Color, by amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        let t = CGFloat(amount)
        return Color(.sRGB,
                     red: Double(a.redComponent * (1 - t) + b.redComponent * t),
                     green: Double(a.greenComponent * (1 - t) + b.greenComponent * t),
                     blue: Double(a.blueComponent * (1 - t) + b.blueComponent * t),
                     opacity: Double(a.alphaComponent * (1 - t) + b.alphaComponent * t))
    }
}
