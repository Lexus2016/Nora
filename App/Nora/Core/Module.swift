import SwiftUI

/// Sidebar sections. A module that is not built yet has `isAvailable == false` and is not shown.
enum Module: String, CaseIterable, Identifiable, Hashable {
    case smartCare, cleanup, applications, performance, spaceMap, status, projects, installers
    case protection, security, history, tools

    var id: String { rawValue }

    var title: LocalizedStringKey { LocalizedStringKey(titleText) }

    /// English source title; the String Catalog translates it.
    var titleText: String {
        switch self {
        case .smartCare: "Smart Care"
        case .cleanup: "Cleanup"
        case .applications: "Applications"
        case .performance: "Performance"
        case .spaceMap: "Space Map"
        case .status: "System Status"
        case .projects: "Projects"
        case .installers: "Installers"
        case .protection: "Protection"
        case .security: "Security"
        case .history: "History"
        case .tools: "Tools"
        }
    }

    /// One line for the rail's hover card.
    var summary: String {
        switch self {
        case .smartCare: "One scan for junk, maintenance, build folders and installers."
        case .cleanup: "Caches, logs and leftovers of removed apps. You review every item."
        case .applications: "Remove apps together with their helpers, caches and settings."
        case .performance: "Refresh caches and services, see what slows your Mac."
        case .spaceMap: "See what takes your disk space and move it to the Trash."
        case .status: "Live CPU, memory, disk, network, battery and temperatures."
        case .projects: "Old build folders of your code projects: node_modules, target, build."
        case .installers: "Disk images and installers you no longer need."
        case .protection: "Paths and tasks Mole must never touch."
        case .security: "Launch items, signatures and an antivirus scan."
        case .history: "What Nora and Mole cleaned, and when."
        case .tools: "Touch ID for sudo, external drives, Mole updates."
        }
    }

    var symbol: String {
        switch self {
        case .smartCare: "sparkles"
        case .cleanup: "trash.circle"
        case .applications: "square.grid.2x2"
        case .performance: "bolt"
        case .spaceMap: "chart.pie"
        case .status: "waveform.path.ecg"
        case .projects: "hammer"
        case .installers: "shippingbox"
        case .protection: "lock.shield"
        case .security: "checkmark.shield"
        case .history: "clock.arrow.circlepath"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// Glass object in `Resources/Glass`.
    var glass: String {
        switch self {
        case .smartCare: "vessel"
        case .cleanup: "clean"
        case .applications: "uninstall"
        case .performance: "optimize"
        case .spaceMap: "analyze"
        case .status: "status"
        case .projects: "purge"
        case .installers: "installer"
        case .protection: "protect"
        case .security: "security"
        case .history: "history"
        case .tools: "settings"
        }
    }

    var palette: ScenePalette {
        switch self {
        case .smartCare: ScenePalette(0xFF3EA5, 0x6B22D9, 0x17062F)
        case .cleanup: ScenePalette(0x1FE6A2, 0x0D7D63, 0x04201F)
        case .applications: ScenePalette(0x38C8FF, 0x2F3FE0, 0x0B0A40)
        case .performance: ScenePalette(0xFFA53A, 0xE2491D, 0x360B0C)
        case .spaceMap: ScenePalette(0xB34DFF, 0x5214CF, 0x14053C)
        case .status: ScenePalette(0xFF3D7F, 0x3D1FB0, 0x0C0A2C)
        case .projects: ScenePalette(0xFFC23A, 0xE8662A, 0x38110A)
        case .installers: ScenePalette(0x27ECD2, 0x1572B3, 0x061F3A)
        case .protection: ScenePalette(0x36E2C2, 0x13708A, 0x071D2D)
        case .security: ScenePalette(0xFF3D6E, 0x8A1FB8, 0x1A0620)
        case .history: ScenePalette(0x6A5CFF, 0x2B1C86, 0x0D0A27)
        case .tools: ScenePalette(0xA35CFF, 0x3F1A8C, 0x13072A)
        }
    }

    /// Modules wired to real Mole commands. Unfinished ones stay out of the sidebar.
    static var available: [Module] { allCases.filter(\.isAvailable) }

    var isAvailable: Bool { Module.ready.contains(self) }

    static let ready: Set<Module> = [.smartCare, .status, .cleanup, .projects, .installers, .applications, .performance]

    static var groups: [(LocalizedStringKey?, [Module])] { [
        (nil, [.smartCare]),
        ("Clean", [.cleanup, .applications, .projects, .installers]),
        ("Speed and disk", [.performance, .spaceMap, .status]),
        ("Safety", [.protection, .security]),
        ("More", [.history, .tools]),
    ] }
}

/// Loads a glass object from the bundle (WebP, decoded by ImageIO).
struct GlassImage: View {
    let name: String
    var size: CGFloat = 220
    var glow: Color = .clear

    var body: some View {
        Group {
            if let image = GlassLibrary.image(name) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.hexagongrid").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 14)
        .shadow(color: glow.opacity(0.35), radius: 30)
        .accessibilityHidden(true)
    }
}
