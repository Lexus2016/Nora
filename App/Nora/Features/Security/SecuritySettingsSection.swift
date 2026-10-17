import SwiftUI

/// Settings → Security. Engine packages and signature databases have independent lifecycles.
struct SecuritySettingsSection: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app
    @AppStorage(SecuritySettings.scheduleKey) private var scheduleOn = false
    @AppStorage(SecuritySettings.cadenceKey) private var cadence = ScanCadence.daily.rawValue
    @AppStorage(SecuritySettings.scopeKey) private var scope = ScanScope.quick.rawValue

    var body: some View {
        Group {
            engineSection
            definitionsSection
            automationSection
        }
        .task {
            // Screenshots and fixture rendering must never execute installed tools or use a network.
            if !app.isVisualSnapshot { model.refreshClamAVStatus(app) }
        }
    }

    private var engineSection: some View {
        Section("ClamAV engine") {
            LabeledContent("Installation", value: model.clamavInstallationStatus)
            LabeledContent("Installed engine", value: model.installedEngine?.engine ?? String(localized: "Not checked"))
            if let scanner = model.clamav.clamscan {
                LabeledContent("Location") { Text(scanner.path).textSelection(.enabled).font(.caption) }
            }
            if let catalog = model.engineCatalog, let checkedAt = model.engineCheckedAt {
                LabeledContent("Homebrew catalog version", value: catalog.packageVersion)
                LabeledContent("Catalog checked", value: checkedAt.formatted(date: .abbreviated, time: .shortened))
                if !catalog.installedVersions.isEmpty {
                    Text(catalog.outdated ? "Engine package update available" : "No engine update in this catalog")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Engine update availability has not been checked.").foregroundStyle(.secondary)
            }
            Text("Availability uses Homebrew's current catalog, which may need refreshing. Engine updates do not update virus definitions.")
                .font(.caption).foregroundStyle(.secondary)

            if !model.homebrewAvailable {
                Text("Homebrew was not found. Install Homebrew first.").foregroundStyle(.orange)
                Link("brew.sh", destination: URL(string: "https://brew.sh")!)
            } else if !model.clamav.isInstalled {
                Button("Install ClamAV with Homebrew") { model.install("clamav", app) }
                    .disabled(model.securityBusy)
                Text("Installs the engine and then downloads Nora's virus definitions.").font(.caption).foregroundStyle(.secondary)
            } else if !model.engineManagedByHomebrew {
                Text("Engine updates need a Homebrew-managed ClamAV installation.").font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Refresh installed version") { model.refreshClamAVStatus(app) }
                    .disabled(model.securityBusy || model.clamav.clamscan == nil)
                Button("Check engine updates") { model.checkEngineUpdate(app) }
                    .disabled(model.securityBusy || !model.homebrewAvailable)
            }
            Button("Update ClamAV engine") { model.upgradeEngine(app) }
                .disabled(!model.canUpgradeEngine)
            if model.watchStopping {
                Text("ClamAV is still stopping. Wait before restarting the watch or updating the engine.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.watchActive || model.watchStarting {
                Text("Turn off Watch Downloads before updating the engine. Turn it back on afterwards to load the installed engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.installing != nil || model.upgradingEngine || model.checkingEngine || model.refreshingClamAV {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.downloadingDatabase ? "Downloading the virus database…" : model.upgradingEngine ? "Updating ClamAV engine…" : model.installing != nil ? "Installing…" : "Checking ClamAV…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelSetup() }
                }
            }
            if let date = model.lastEngineSuccess {
                LabeledContent("Last verified engine install", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let result = model.engineResult { Text(result).font(.caption).textSelection(.enabled) }
        }
    }

    private var definitionsSection: some View {
        Section("ClamAV virus definitions") {
            Text(model.databaseStatus).foregroundStyle(.secondary)
            if let version = model.installedEngine?.databaseVersion {
                LabeledContent("Definitions version", value: version)
            }
            if let date = model.installedEngine?.databaseDate {
                LabeledContent("Definitions built", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let date = model.lastDatabaseSuccess {
                LabeledContent("Last successful definitions check", value: date.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("No successful definitions update recorded.").foregroundStyle(.secondary)
            }
            Text("Age is read from Nora's on-disk database. A successful freshclam check may leave unchanged definitions; it does not upgrade the engine.")
                .font(.caption).foregroundStyle(.secondary)
            if model.watchActive || model.watchStarting {
                Text("The active Downloads watch may still use its previously loaded definitions until ClamAV reloads them or you restart the watch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Update virus definitions") { model.updateDatabase(app) }
                    .disabled(!model.clamav.isInstalled || model.securityBusy)
                if model.updatingDatabase {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelSetup() }
                }
            }
            if let result = model.databaseResult { Text(result).font(.caption).textSelection(.enabled) }
            if model.securityBusy && !model.clamavSetupBusy {
                Text("Another security task is running. Wait for it to finish.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Show ClamAV console") {
                app.showMain(.security)
                app.showConsole = true
            }
            Text("Choose History in the main window's console (⌘J) to review previous commands, output and stopped actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var automationSection: some View {
        Section("Security") {
            Toggle("Scheduled antivirus scan", isOn: $scheduleOn)
                .onChange(of: scheduleOn) { _, on in
                    if on { SecurityNotifier.requestAuthorization() }
                }
            Picker("Frequency", selection: $cadence) {
                ForEach(ScanCadence.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!scheduleOn)
            Picker("Scope", selection: $scope) {
                ForEach(ScanScope.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .disabled(!scheduleOn)
            Text("Runs ClamAV in the background and posts a notification when it finds something. Nothing is moved without your click.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle(isOn: Binding(
                get: { model.watchActive || model.watchStarting },
                set: { model.setWatch($0, app) })) {
                HStack(spacing: 8) {
                    Text("Watch Downloads")
                    if model.watchStarting {
                        ProgressView().controlSize(.small)
                        Text("Starting ClamAV…").foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(model.upgradingEngine || model.installing != nil || model.watchStopping)
            if let error = model.watchError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("The Downloads watch keeps ClamAV's virus database in memory: about 1 GB, and up to 2.4 GB during the daily reload. Turn it off to free that memory.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}
