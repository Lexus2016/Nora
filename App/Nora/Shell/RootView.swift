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

struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var visibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $visibility) {
            Sidebar(selection: $app.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            ZStack(alignment: .bottom) {
                SceneBackground(palette: app.selection.palette)
                ModuleDetail(module: app.selection)
                    .id(app.selection)
                    .transition(.opacity)
                if app.showConsole {
                    ConsoleView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: app.selection)
            .animation(.easeOut(duration: 0.22), value: app.showConsole)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { app.showConsole.toggle() } label: { Label("Console", systemImage: "terminal") }
                        .keyboardShortcut("j", modifiers: .command)
                        .help(Text("Show the commands Nora ran and their output (⌘J)"))
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

struct ModuleDetail: View {
    let module: Module

    var body: some View {
        switch module {
        case .status: StatusView()
        default: EmptyView()
        }
    }
}

struct Sidebar: View {
    @Binding var selection: Module

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(Module.groups.enumerated()), id: \.offset) { _, group in
                let items = group.1.filter(\.isAvailable)
                if !items.isEmpty {
                    if let title = group.0 {
                        Section(title) { rows(items) }
                    } else {
                        rows(items)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.fg2)
                Spacer()
            }
            .padding(14)
        }
    }

    private func rows(_ items: [Module]) -> some View {
        ForEach(items) { module in
            Label { Text(module.title) } icon: {
                Image(systemName: module.symbol).foregroundStyle(module.palette.glow)
            }
            .tag(module)
        }
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
        .background(Color(hex: 0x090414, opacity: 0.86))
        .overlay(alignment: .top) { Divider().overlay(Palette.line2) }
    }
}
