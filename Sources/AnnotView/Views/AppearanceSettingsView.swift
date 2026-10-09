import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
