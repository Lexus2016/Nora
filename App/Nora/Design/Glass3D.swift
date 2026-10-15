import AppKit
import SwiftUI

/// Decoded glass objects, so per-frame animation never touches the disk.
@MainActor
enum GlassLibrary {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }
}

/// A glass object that turns in 3D: the flat render is rotated with perspective, a stack of
/// darkened copies along the depth axis forms its side wall, a highlight slides across the glass
/// with the angle, and the shadow shifts. `amplitude` 0 keeps it still.
struct Glass3D: View {
    let name: String
    var size: CGFloat = 300
    var glow: Color = .clear
    /// Peak rotation in degrees, and seconds for a full left-right-left swing.
    var amplitude: Double = 26
    var period: Double = 3.2
    /// Thickness of the side wall as a share of the size.
    var depth: CGFloat = 0.06

    @Environment(\.controlActiveState) private var activeState
    @State private var windowVisible = true

    var body: some View {
        if amplitude == 0 || !windowVisible {
            frame(angle: 0, tilt: 0, lift: 0)
                .background(VisibilityProbe(visible: $windowVisible))
        } else {
            // The shadow and glow are drawn once under the animation: blurring them again on every
            // frame was most of the cost. A slow idle swing runs at 24 fps, a busy one at 30.
            ZStack {
                shadows
                TimelineView(.animation(minimumInterval: amplitude < 15 ? 1.0 / 24.0 : 1.0 / 30.0,
                                        paused: activeState == .inactive && amplitude < 15)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = sin(t * 2 * .pi / period)
                    frame(angle: amplitude * phase,
                          tilt: 5 * sin(t * 2 * .pi / (period * 1.7)),
                          lift: 6 * sin(t * 2 * .pi / (period * 1.3)),
                          withShadows: false)
                }
            }
            .background(VisibilityProbe(visible: $windowVisible))
        }
    }

    /// The object's drop shadow and coloured glow as one static layer.
    private var shadows: some View {
        ZStack {
            if let image = GlassLibrary.image(name) {
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundStyle(glow.opacity(0.4))
                    .blur(radius: size * 0.12)
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundStyle(.black.opacity(0.45))
                    .blur(radius: size * 0.07)
                    .offset(y: size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func frame(angle: Double, tilt: Double, lift: CGFloat, withShadows: Bool = true) -> some View {
        let image = GlassLibrary.image(name)
        let radians = angle * .pi / 180
        let wall = size * depth
        // At a slow idle swing (under 15°) the side wall moves about 3 pt and is not visible,
        // so it is not drawn; a busy swing shows it with 12 layers.
        let layers = amplitude >= 15 ? 12 : 0
        return ZStack {
            if let image {
                // Side wall: copies receding along the depth axis, darker the deeper they go.
                ForEach(0..<layers, id: \.self) { i in
                    let k = CGFloat(layers - i) / CGFloat(layers)
                    Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .brightness(-0.18 - 0.22 * Double(k))
                        .saturation(1.15)
                        .offset(x: -CGFloat(sin(radians)) * wall * k, y: CGFloat(sin(tilt * .pi / 180)) * wall * k * 0.6 + wall * 0.25 * k)
                }
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .brightness(0.04 * sin(radians * 2))
                // Highlight that slides across the glass as it turns.
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white.opacity(0.55), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.42)
                    .rotationEffect(.degrees(18))
                    .offset(x: CGFloat(sin(radians)) * size * 0.9)
                    .frame(width: size, height: size)
                    .mask(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit))
                    .blendMode(.plusLighter)
                    .opacity(0.42)
            } else {
                Image(systemName: "circle.hexagongrid").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .offset(y: lift)
        .drawingGroup()
        .modifier(GlassShadows(on: withShadows, size: size, glow: glow))
        .accessibilityHidden(true)
    }
}

/// Drop shadow and glow for a still object. The animated object gets none: its shadows are a
/// separate static layer, so they are not blurred again on every frame.
private struct GlassShadows: ViewModifier {
    let on: Bool
    let size: CGFloat
    let glow: Color

    func body(content: Content) -> some View {
        if on {
            content
                .shadow(color: .black.opacity(0.45), radius: size * 0.07, x: 0, y: size * 0.06)
                .shadow(color: glow.opacity(0.4), radius: size * 0.12)
        } else {
            content
        }
    }
}

/// Reports whether the hosting window is on screen (not minimised, not fully covered, not on
/// another Space), so animations and live readings stop when nobody can see them.
struct VisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view, update: { visible = $0 })
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var observer: NSObjectProtocol?

        func attach(to view: NSView, update: @escaping @MainActor @Sendable (Bool) -> Void) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let window = view?.window else { return }
                update(window.occlusionState.contains(.visible))
                self?.observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { update(window?.occlusionState.contains(.visible) ?? false) }
                }
            }
        }
    }
}
