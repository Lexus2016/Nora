import MoleKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.moleState {
        case .ready: MainView()
        default: OnboardingView()
        }
    }
}

/// Icon rail on the left, the selected module's scene on the right; the scene runs under the
/// hidden title bar like CleanMyMac.
struct MainView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack(alignment: .bottom) {
            SceneBackground(palette: app.selection.palette)
                .animation(.easeInOut(duration: 0.45), value: app.selection)
            HStack(spacing: 0) {
                Rail(selection: $app.selection)
                ModuleDetail(module: app.selection)
                    .id(app.selection)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if app.showConsole {
                ConsoleView()
                    .padding(.leading, Rail.width)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.22), value: app.selection)
        .animation(.easeOut(duration: 0.22), value: app.showConsole)
        .background(Button("") { app.showConsole.toggle() }.keyboardShortcut("j", modifiers: .command).hidden())
    }
}

struct ModuleDetail: View {
    let module: Module

    var body: some View {
        switch module {
        case .status: StatusView()
        case .cleanup: CleanupView()
        case .projects: ProjectsView()
        case .installers: InstallersView()
        case .applications: ApplicationsView()
        default: EmptyView()
        }
    }
}

/// The icon-only sidebar. A module that is scanning or running shows a ring on its icon.
struct Rail: View {
    static let width: CGFloat = 84
    @Binding var selection: Module
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: 50)
            ForEach(Module.available) { module in
                button(module)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 19, weight: .medium)).frame(width: 56, height: 50)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.fg2)
            .help(Text("Settings"))
            .padding(.bottom, 16)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.06)).frame(width: 0.5) }
    }

    private func button(_ module: Module) -> some View {
        let isSelected = module == selection
        return Button { selection = module } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: module.symbol)
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.82))
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: 56, height: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(colors: [module.palette.glow.opacity(0.42), module.palette.body.opacity(0.32)],
                                                     startPoint: .top, endPoint: .bottom))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                                .shadow(color: module.palette.glow.opacity(0.45), radius: 10)
                        }
                    }
                if app.isBusy(module) {
                    BusyRing().frame(width: 16, height: 16).offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(module.title))
        .accessibilityLabel(Text(module.title))
        .animation(.easeOut(duration: 0.2), value: isSelected)
    }
}

/// Small spinning progress ring for a module at work.
struct BusyRing: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.9))
            Circle().trim(from: 0, to: 0.3).stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .padding(3)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
        }
        .onAppear { spin = true }
    }
}

/// Top strip of every module scene: leading action (Start over / Back), the module name in the
/// middle, the console toggle on the right. Sits in the hidden title bar.
struct TopBar: View {
    let title: LocalizedStringKey
    var leading: TopBarAction?
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.fg2)
            HStack {
                if let leading {
                    Button(action: leading.action) {
                        Label(leading.label, systemImage: leading.symbol).font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .keyboardShortcut(.cancelAction)
                    .background(Button("", action: leading.action).keyboardShortcut("[", modifiers: .command).hidden())
                }
                Spacer()
                Button { app.showConsole.toggle() } label: {
                    Image(systemName: "terminal").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.fg2)
                .help(Text("Show the commands Nora ran and their output (⌘J)"))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

struct TopBarAction {
    let label: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    static func startOver(_ action: @escaping () -> Void) -> TopBarAction {
        TopBarAction(label: "Start over", symbol: "arrow.counterclockwise", action: action)
    }

    static func back(_ action: @escaping () -> Void) -> TopBarAction {
        TopBarAction(label: "Back", symbol: "chevron.left", action: action)
    }
}

/// Every command Nora ran, with its exact command line and output (⌘J).
struct ConsoleView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Console").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { app.showConsole = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).frame(height: 30)
            Divider().overlay(Palette.line)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(app.console.entries) { entry in
                            HStack(spacing: 6) {
                                Text("$").foregroundStyle(Palette.pink)
                                Text(entry.command).textSelection(.enabled)
                                Spacer()
                                if entry.isRunning { ProgressView().controlSize(.mini) }
                                else if let status = entry.status { Text("exit \(status)").foregroundStyle(status == 0 ? Palette.good : Palette.crit) }
                                else if let failure = entry.failure { Text(failure).foregroundStyle(Palette.crit) }
                            }
                            .padding(.top, 6)
                            ForEach(Array(entry.output.suffix(400).enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line).foregroundStyle(Color(hex: 0xECE6FF)).textSelection(.enabled)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.mono)
                    .padding(.horizontal, 14).padding(.bottom, 10)
                }
                .onChange(of: app.console.entries.last?.output.count) { proxy.scrollTo("end") }
            }
        }
        .frame(height: 240)
        .background(Color(hex: 0x090414, opacity: 0.9))
        .overlay(alignment: .top) { Divider().overlay(Palette.line2) }
    }
}
