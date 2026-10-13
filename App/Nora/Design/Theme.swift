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
    static let fg2 = Color.white.opacity(0.76)
    static let muted = Color.white.opacity(0.54)
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

/// The three colours of a module scene: glow, body, depth.
struct ScenePalette: Equatable {
    let glow: Color
    let body: Color
    let depth: Color

    init(_ glow: UInt32, _ body: UInt32, _ depth: UInt32) {
        self.glow = Color(hex: glow)
        self.body = Color(hex: body)
        self.depth = Color(hex: depth)
    }
}

/// Full-bleed neon background of a module scene (prototype `.scene`).
struct SceneBackground: View {
    let palette: ScenePalette

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: palette.body, location: 0), .init(color: palette.depth, location: 0.72)],
                           startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
            EllipticalGradient(colors: [palette.body.opacity(0.9), .clear], center: UnitPoint(x: 0.95, y: 0),
                               startRadiusFraction: 0, endRadiusFraction: 0.7)
            EllipticalGradient(colors: [palette.glow.opacity(0.58), .clear], center: UnitPoint(x: 0.27, y: 0.55),
                               startRadiusFraction: 0, endRadiusFraction: 0.72)
        }
        .ignoresSafeArea()
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
            .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.86)], startPoint: .top, endPoint: .bottom))
            .shadow(color: glow.opacity(0.6), radius: 17)
            .fixedSize(horizontal: false, vertical: true)
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
    var glow: Color = Palette.pink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background(
                Capsule().fill(LinearGradient(colors: [.white, Color(hex: 0xF3EEFF), Color(hex: 0xE6DEFB)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 0.5))
            .shadow(color: glow.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Frosted secondary button; real Liquid Glass on macOS 26 and later.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .modifier(GlassCapsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Glossy pink button for actions that delete.
struct DestructiveButtonStyle: ButtonStyle {
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
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
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
        if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(.black.opacity(0.18)), in: shape)
        } else {
            content
                .background(.ultraThinMaterial.opacity(0.85), in: shape)
                .background(Color.black.opacity(0.18), in: shape)
                .overlay(shape.strokeBorder(Palette.line, lineWidth: 0.5))
        }
    }
}

extension View {
    func glassPanel(radius: CGFloat = 18) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// The round *Scan* button: a glass orb with a specular highlight (prototype `.orb`).
struct OrbButton: View {
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
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.2), value: hovering)
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
