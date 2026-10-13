import MoleKit
import SwiftUI
import UniformTypeIdentifiers

/// Shown until a supported Mole is found: install it, point Nora at it, or update it.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var working = false
    @State private var error: String?
    private let palette = Module.smartCare.palette

    var body: some View {
        ZStack(alignment: .bottom) {
            SceneBackground(palette: palette)
            HStack(spacing: 40) {
                GlassImage(name: "vessel", size: 280, glow: palette.glow)
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.warn).font(.system(size: 12))
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if app.showConsole || working { ConsoleView() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch app.moleState {
        case .locating:
            SceneTitle(text: "Looking for Mole…", glow: palette.glow)
            ProgressView().controlSize(.small).tint(.white)
        case .missing:
            SceneTitle(text: "Welcome to Nora", glow: palette.glow)
            Text("Nora is a window for Mole, a free command-line tool that cleans and tunes your Mac. Mole is not installed yet. Nora installs it for you, no password needed.")
                .font(.system(size: 15)).foregroundStyle(Palette.fg2).fixedSize(horizontal: false, vertical: true)
            installBlock
        case .unsupported(let mole):
            SceneTitle(text: "Mole needs an update", glow: palette.glow)
            Text("Nora works with Mole \(Mole.minimumVersion) or newer. This Mac has \(mole.version).")
                .font(.system(size: 15)).foregroundStyle(Palette.fg2)
            let command = MoleSetup.updateCommand(for: mole)
            CommandPreview(command: command.description)
            Button("Update Mole") { perform([command]) }.buttonStyle(PrimaryButtonStyle(glow: palette.glow)).disabled(working)
        case .broken(let path, let reason):
            SceneTitle(text: "Mole does not start", glow: palette.glow)
            Text("Nora found \(path), but it did not run: \(reason)").font(.system(size: 13)).foregroundStyle(Palette.fg2).textSelection(.enabled)
            installBlock
        case .ready:
            EmptyView()
        }
    }

    private var installBlock: some View {
        let channel = MoleSetup.preferredChannel()
        let commands = MoleSetup.installCommands(channel, home: app.home)
        return VStack(alignment: .leading, spacing: 12) {
            switch channel {
            case .homebrew: Text("Nora will use Homebrew:").font(.system(size: 12)).foregroundStyle(Palette.muted)
            case .script: Text("Nora will run Mole's official installer into ~/.local/bin:").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            ForEach(commands, id: \.self) { CommandPreview(command: $0.description) }
            HStack(spacing: 10) {
                Button {
                    perform(commands)
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Install Mole") }
                }
                .buttonStyle(PrimaryButtonStyle(glow: palette.glow))
                .disabled(working)
                Button("Choose mo…") { choose() }.buttonStyle(GlassButtonStyle()).disabled(working)
                Button("Check again") { Task { await app.locate() } }.buttonStyle(GlassButtonStyle()).disabled(working)
            }
        }
    }

    private func perform(_ commands: [ShellCommand]) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try FileManager.default.createDirectory(at: app.home.appendingPathComponent("Library/Caches/Nora"), withIntermediateDirectories: true)
                for command in commands {
                    try await app.stream(command, environment: Mole.environment(home: app.home))
                }
                await app.locate()
            } catch {
                self.error = String(localized: "Installation failed. The console shows the output.")
                app.showConsole = true
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the mo executable")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "molePath")
        Task { await app.locate() }
    }
}
