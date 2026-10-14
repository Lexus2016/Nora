import MoleKit
import ServiceManagement
import Sparkle
import SwiftUI

/// Settings window (⌘,): General, Mole, Security, Updates.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    /// Debug builds take `-NoraSettingsTab security` for screenshots.
    @State private var tab = Self.initialTab

    private static var initialTab: String {
        #if DEBUG
        UserDefaults.standard.string(forKey: "NoraSettingsTab") ?? "general"
        #else
        "general"
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            MoleSettings().tabItem { Label("Mole", systemImage: "terminal") }.tag("mole")
            Form { SecuritySettingsSection(model: app.security) }
                .formStyle(.grouped)
                .tabItem { Label("Security", systemImage: Module.security.symbol) }
                .tag("security")
            UpdateSettings().tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }.tag("updates")
        }
        .font(.system(size: 14))
        .frame(width: 640, height: 580)
    }
}

/// Menu bar tile choices: any four of six.
enum MenuTile: String, CaseIterable, Identifiable {
    case cpu, memory, network, disk, gpu, fan
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .cpu: "Processor"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .gpu: "Graphics"
        case .fan: "Fan"
        }
    }

    static let defaults: [MenuTile] = [.cpu, .memory, .network, .disk]

    static var chosen: [MenuTile] {
        let raw = UserDefaults.standard.string(forKey: "menuTiles") ?? ""
        let tiles = raw.split(separator: ",").compactMap { MenuTile(rawValue: String($0)) }
        // Any one to four tiles the user picked; none picked falls back to the defaults.
        return tiles.isEmpty ? defaults : Array(tiles.prefix(4))
    }
}

/// How the menu bar item looks.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case icon, cpu, memory, both
    var id: String { rawValue }

    /// The CPU temperature with a coloured dot, next to any style. Off by default.
    static let temperatureKey = "menuBarTemperature"
    var title: LocalizedStringKey {
        switch self {
        case .icon: "Icon only"
        case .cpu: "Icon and CPU"
        case .memory: "Icon and memory"
        case .both: "CPU and memory"
        }
    }
}

private struct GeneralSettings: View {
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("menuBarStyle") private var style = MenuBarStyle.icon.rawValue
    @AppStorage(MenuBarStyle.temperatureKey) private var showTemperature = false
    @AppStorage("menuTiles") private var tilesRaw = MenuTile.defaults.map(\.rawValue).joined(separator: ",")
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Nora at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.system(size: 12)).foregroundStyle(.red) }
            }
            Section("Menu bar") {
                Toggle("Show Nora in the menu bar", isOn: $showMenuBar)
                Picker("Menu bar item", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .disabled(!showMenuBar)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show the CPU temperature", isOn: $showTemperature)
                    Text("A dot shows how hot it runs: green below 70 °C, orange from 70 °C, red from 90 °C.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .disabled(!showMenuBar)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tiles in the quick menu (one to four)")
                    HStack {
                        ForEach(MenuTile.allCases) { tile in
                            Toggle(isOn: Binding(get: { tiles.contains(tile) }, set: { on in toggle(tile, on) })) { Text(tile.title) }
                                .toggleStyle(.button)
                                .disabled(!tiles.contains(tile) && tiles.count >= 4)
                        }
                    }
                    Text("Shortcut: ⌥⌘N opens the quick menu.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .disabled(!showMenuBar)
            }
            Section {
                Text("Nora follows your Mac's language: English, Ukrainian or Russian. Change it per app in System Settings → General → Language & Region → Applications.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// What the menu shows: the defaults until the user picks their own.
    private var tiles: [MenuTile] {
        let picked = tilesRaw.split(separator: ",").compactMap { MenuTile(rawValue: String($0)) }
        return picked.isEmpty ? MenuTile.defaults : picked
    }

    /// One to four tiles: the last one cannot be switched off.
    private func toggle(_ tile: MenuTile, _ on: Bool) {
        var list = tiles
        if on, !list.contains(tile), list.count < 4 { list.append(tile) }
        if !on, list.count > 1 { list.removeAll { $0 == tile } }
        tilesRaw = list.map(\.rawValue).joined(separator: ",")
    }
}

private struct MoleSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(CommandPreview.settingKey) private var showCommands = false
    @AppStorage("moleNoOpLog") private var noOpLog = false

    var body: some View {
        Form {
            Section("Mole") {
                LabeledContent("Version", value: app.mole?.version ?? "—")
                LabeledContent("Location", value: app.mole?.executable.path ?? "—")
                LabeledContent("Installed with", value: app.mole?.isHomebrew == true ? "Homebrew" : String(localized: "Mole installer"))
                HStack {
                    Button("Choose another mo…") {
                        let panel = NSOpenPanel()
                        panel.treatsFilePackagesAsDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            UserDefaults.standard.set(url.path, forKey: "molePath")
                            Task { await app.locate() }
                        }
                    }
                    Button("Find again") {
                        UserDefaults.standard.removeObject(forKey: "molePath")
                        Task { await app.locate() }
                    }
                }
            }
            Section("Commands") {
                Toggle("Show the Mole and ClamAV commands under each action", isOn: $showCommands)
                Text("Off by default. The console (⌘J) always shows every command Nora runs and its output.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Logs") {
                Toggle("Do not write Mole's operations log (MO_NO_OPLOG)", isOn: $noOpLog)
                Text("The History screen reads the operations log, so it stays empty while this is on.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Section("Credits") {
                Text("Nora is a window for Mole by tw93 (github.com/tw93/Mole, GPL-3.0). Nora is not affiliated with Mole.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("ClamAV by Cisco Talos (clamav.net, GPL-2.0) runs as a separate program that you install with Homebrew. ClamAV is a registered trademark of Cisco Systems, Inc.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("YARA by VirusTotal (BSD-3-Clause) runs Apple's XProtect rules. Updates come through Sparkle (sparkle-project.org, MIT).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let notices = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") {
                    Button("Third-party licenses") { NSWorkspace.shared.open(notices) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @AppStorage("SUEnableAutomaticChecks") private var automatic = true

    var body: some View {
        Form {
            Section("Nora") {
                LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                Toggle("Check for updates automatically", isOn: $automatic)
                Button("Check for updates now") { Updater.shared.checkForUpdates() }
                Text("Updates come from GitHub Releases and are verified with Nora's EdDSA signature.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Sparkle 2 with the standard UI. The feed and public key are in Info.plist.
@MainActor
final class Updater {
    static let shared = Updater()
    let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
