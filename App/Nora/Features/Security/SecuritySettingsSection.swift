import SwiftUI

/// Settings → Security. Scheduled scan and Downloads watch are both off until the user turns them on.
struct SecuritySettingsSection: View {
    let model: SecurityModel
    @Environment(AppModel.self) private var app
    @AppStorage(SecuritySettings.scheduleKey) private var scheduleOn = false
    @AppStorage(SecuritySettings.cadenceKey) private var cadence = ScanCadence.daily.rawValue
    @AppStorage(SecuritySettings.scopeKey) private var scope = ScanScope.quick.rawValue

    var body: some View {
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
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Watch Downloads", isOn: Binding(
                get: { model.watchActive },
                set: { model.setWatch($0, app) }))
            Text("The Downloads watch keeps ClamAV's virus database in memory: about 1 GB, and up to 2.4 GB during the daily reload. Turn it off to free that memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("ClamAV database") {
                HStack {
                    Text(model.databaseStatus).foregroundStyle(.secondary)
                    Button("Update now") { model.updateDatabase(app) }
                        .disabled(!model.clamav.isInstalled)
                }
            }
        }
    }
}
