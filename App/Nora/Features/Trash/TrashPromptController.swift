import AppKit
import SwiftUI

/// Nonactivating, single-space panel. It never calls activate or makeKeyAndOrderFront.
@MainActor
final class TrashPromptController: NSObject, NSWindowDelegate {
    private let model: TrashReminderModel
    private var panel: TrashPanel?
    private let openNora: () -> Void

    init(model: TrashReminderModel, openNora: @escaping () -> Void = {}) {
        self.model = model
        self.openNora = openNora
        super.init()
        model.presentationChanged = { [weak self] shown in
            if shown { self?.show() } else { self?.panel?.orderOut(nil) }
        }
    }

    func shutdown() {
        model.presentationChanged = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    private func show() {
        let panel = panel ?? makePanel()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(Self.origin(in: visible, panelSize: panel.frame.size))
        }
        panel.orderFront(nil)
    }

    static func origin(in visible: NSRect, panelSize: NSSize) -> NSPoint {
        // visibleFrame already excludes the Dock, whether it is at the bottom or either side.
        NSPoint(x: max(visible.minX, min(visible.minX + 16, visible.maxX - panelSize.width)),
                y: max(visible.minY, min(visible.minY + 16, visible.maxY - panelSize.height)))
    }

    private func makePanel() -> TrashPanel {
        let panel = TrashPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("nora-trash-reminder")
        panel.title = String(localized: "Nora Trash review")
        panel.contentMinSize = NSSize(width: 520, height: 260)
        panel.contentMaxSize = NSSize(width: 520, height: 260)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        // In particular: no canJoinAllSpaces and no fullScreenAuxiliary.
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TrashPromptView(model: model, openNora: openNora))
        self.panel = panel
        return panel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.dismiss()
        return false
    }

    private final class TrashPanel: NSPanel {
        override var canBecomeKey: Bool { true } // Explicit keyboard/VoiceOver interaction only.
        override var canBecomeMain: Bool { false }
    }
}
