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

/// Shared decorative-motion gate. Functional labels and progress tracks remain visible.
enum DecorativeMotion {
    static func isAllowed(reduceMotion: Bool, activeState: ControlActiveState, visible: Bool = true) -> Bool {
        !reduceMotion && activeState != .inactive && visible
    }
}

/// Bounded geometry shared by live rendering and deterministic visual tests.
enum GlassMotion {
    static let maximumFramesPerSecond = 24.0
    static let maximumSideLayers = 6
    static let maximumAngle = 18.0
    static let minimumPeriod = 4.8

    struct Pose: Equatable {
        let angle: Double
        let tilt: Double
        let lift: CGFloat
        static let rest = Pose(angle: -4, tilt: 1, lift: 0)
    }

    static func sideLayers(amplitude: Double) -> Int { abs(amplitude) >= 15 ? maximumSideLayers : 0 }

    static func pose(time: TimeInterval, amplitude: Double, period: Double) -> Pose {
        let boundedAmplitude = min(abs(amplitude), maximumAngle)
        let phase = time * 2 * .pi / max(period, minimumPeriod)
        let weight = boundedAmplitude / maximumAngle
        return Pose(angle: boundedAmplitude * sin(phase),
                    tilt: 1.6 * weight * sin(phase + .pi / 3),
                    lift: CGFloat(1.8 * weight * sin(phase)))
    }
}

/// Keeps the original glass artwork, with a compact tinted bevel and a restrained light sweep.
/// Only visible, active windows schedule decorative frames, at no more than 24 fps.
struct Glass3D: View {
    let name: String
    var size: CGFloat = 300
    var glow: Color = .clear
    var amplitude: Double = 26
    var period: Double = 4.8
    var depth: CGFloat = 0.06

    #if DEBUG
    /// Fixed native screenshot pose, with no animation scheduler. Never a production preference.
    var snapshotTime: TimeInterval?
    #endif

    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var windowVisible = false

    private var fixedTime: TimeInterval? {
        #if DEBUG
        snapshotTime
        #else
        nil
        #endif
    }

    var body: some View {
        let layers = GlassMotion.sideLayers(amplitude: amplitude)
        // Resolve colour-space blends once per view update, not for each layer on every tick.
        let sideColors = (0..<layers).map { i in
            glow.blend(with: .black, by: 0.52 + 0.18 * Double(layers - i) / Double(layers))
        }
        ZStack {
            // Blur is outside the timeline: only the crisp artwork/bevel changes each frame.
            shadows
            if let fixedTime {
                frame(pose: GlassMotion.pose(time: fixedTime, amplitude: amplitude, period: period), sideColors: sideColors)
            } else if amplitude != 0 && DecorativeMotion.isAllowed(reduceMotion: reduceMotion, activeState: activeState, visible: windowVisible) {
                TimelineView(.animation(minimumInterval: 1 / GlassMotion.maximumFramesPerSecond)) { context in
                    frame(pose: GlassMotion.pose(time: context.date.timeIntervalSinceReferenceDate,
                                                 amplitude: amplitude, period: period), sideColors: sideColors)
                }
            } else {
                // Inactive, hidden and Reduce Motion all remove the timeline entirely.
                frame(pose: .rest, sideColors: sideColors)
            }
        }
        .frame(width: size, height: size)
        .background(VisibilityProbe(visible: $windowVisible))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var shadows: some View {
        ZStack {
            if let image = GlassLibrary.image(name) {
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundStyle(glow.opacity(0.28))
                    .blur(radius: size * 0.10)
                Image(nsImage: image).resizable().renderingMode(.template).aspectRatio(contentMode: .fit)
                    .foregroundStyle(.black.opacity(0.36))
                    .blur(radius: size * 0.055)
                    .offset(y: size * 0.055)
            }
        }
        .frame(width: size, height: size)
    }

    private func frame(pose: GlassMotion.Pose, sideColors: [Color]) -> some View {
        let image = GlassLibrary.image(name)
        let radians = pose.angle * .pi / 180
        let wall = size * min(max(depth, 0), 0.065)
        let layers = sideColors.count
        return ZStack {
            if let image {
                // Six silhouette layers, rather than twelve copies of the bright face artwork.
                // The baked-in volume is enough at idle, so idle still adds no side layers.
                ForEach(0..<layers, id: \.self) { i in
                    let k = CGFloat(layers - i) / CGFloat(layers)
                    Image(nsImage: image).resizable().renderingMode(.template).interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(sideColors[i])
                        .offset(x: -CGFloat(sin(radians)) * wall * k, y: wall * 0.14 * k)
                }
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .brightness(0.025 * sin(radians))
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .white.opacity(0.32), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: size * 0.34)
                    .rotationEffect(.degrees(18))
                    .offset(x: CGFloat(sin(radians)) * size * 0.65 - size * 0.1)
                    .frame(width: size, height: size)
                    .mask(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit))
                    .blendMode(.plusLighter)
                    .opacity(0.28)
            } else {
                Image(systemName: "circle.hexagongrid").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .rotation3DEffect(.degrees(pose.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        .rotation3DEffect(.degrees(pose.tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.35)
        .offset(y: pose.lift)
        .drawingGroup()
    }
}

/// Reports whether the hosting window is on screen (not minimised, not fully covered, not on
/// another Space), so animations and live readings stop when nobody can see them.
struct VisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { visible = $0 }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onChange = { visible = $0 }
    }

    /// Every spinner carries a probe, so its observer must go when the spinner does.
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.stopObserving()
    }

    /// Follows the window it is in. AppKit calls `viewDidMoveToWindow` when the view enters a
    /// window and again (with none) when it leaves, so the observer always belongs to the current
    /// window and is never missed the way a one-off async look at `window` can be.
    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return report(false) }
            report(window.occlusionState.contains(.visible))
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated { self?.report(window?.occlusionState.contains(.visible) ?? false) }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }

        /// On the next turn of the run loop: AppKit can move the view during a SwiftUI update,
        /// when state must not change.
        private func report(_ value: Bool) {
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
    }
}
