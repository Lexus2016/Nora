import MoleKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Mole") {
                if let mole = app.mole {
                    LabeledContent("Version", value: mole.version)
                    LabeledContent("Location", value: mole.executable.path)
                } else {
                    Text("Mole is not installed.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
