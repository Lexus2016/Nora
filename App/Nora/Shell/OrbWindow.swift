import AppKit
import SwiftUI

/// The round action button lives in its own transparent child window that straddles the main
/// window's bottom edge, so it and its glow extend past the window like in CleanMyMac.
/// Module scenes publish their action here; the panel follows the main window.
@MainActor @Observable
final class OrbController {
    private(set) var action: OrbAction?
    private(set) var palette = Module.smartCare.palette
    var hidden = false

    @ObservationIgnored private var owner: UUID?
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var parent: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var mouseMonitor: Any?

    static let diameter: CGFloat = 104
    /// Large enough for the orb's glow (shadow radius up to 46 pt on hover) so it is never clipped.
    static let panelSize: CGFloat = 320
    /// How far the orb's centre sits above the window's bottom edge.
    static let lift: CGFloat = 20
    /// Space a scene keeps free above the bottom edge: the orb's radius, its progress ring
    /// (9 pt out, 5 pt wide) and a gap, so the busy orb never covers a card.
    static let clearance: CGFloat = lift + diameter / 2 + 12 + 14
    /// In full screen the orb rises fully into the window, so scenes keep more room.
    static let fullScreenLift: CGFloat = diameter / 2 + 16
    /// The space the current scene must keep free; larger in full screen.
    private(set) var bottomClearance: CGFloat = OrbController.clearance

    func publish(_ action: OrbAction?, palette: ScenePalette, owner: UUID) {
        self.owner = owner
        self.action = action
        self.palette = palette
        updateHitArea()
    }

    func withdraw(owner: UUID) {
        guard self.owner == owner else { return }
        action = nil
        updateHitArea()
    }

    /// The panel is mostly glow, so it takes the mouse only while the cursor is over the orb
    /// itself; everywhere else clicks reach the content underneath (the review footer, list rows).
    func updateHitArea() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let distance = hypot(mouse.x - panel.frame.midX, mouse.y - panel.frame.midY)
        panel.ignoresMouseEvents = action == nil || hidden || distance > Self.diameter / 2 + 6
    }

    func attach(to window: NSWindow, app: AppModel) {
        guard parent !== window else { return }
        parent = window
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        window.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: OrbHost().environment(app))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
            })
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.updateHitArea() }
            return event
        }
        reposition()
    }

    func reposition() {
        guard let parent, let panel else { return }
        let frame = parent.frame
        let inFullScreen = parent.styleMask.contains(.fullScreen)
        // In full screen there is no outside, so the orb rises fully into the window.
        let lift = inFullScreen ? Self.fullScreenLift : Self.lift
        let clearance = Self.clearance + lift - Self.lift
        if bottomClearance != clearance { bottomClearance = clearance }
        panel.setFrameOrigin(NSPoint(x: frame.minX + Rail.width + (frame.width - Rail.width) / 2 - Self.panelSize / 2,
                                     y: frame.minY + lift - Self.panelSize / 2))
        updateHitArea()
    }
}

/// The SwiftUI side of the orb panel.
private struct OrbHost: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let orb = app.orb
        ZStack {
            if let action = orb.action, !orb.hidden, !app.showConsole {
                BottomOrb(action: action, palette: orb.palette)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: OrbController.panelSize, height: OrbController.panelSize)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: orb.action?.signature)
        .preferredColorScheme(.dark)
    }
}

/// Gives SwiftUI views access to their NSWindow. AppKit calls `viewDidMoveToWindow` once the view
/// is in a window, so the callback cannot be missed the way an async peek at `view.window` can.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
    }

    final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
