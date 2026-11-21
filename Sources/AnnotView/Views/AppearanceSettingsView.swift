import Foundation
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings

    private var systemAuthorName: String {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fullName.isEmpty ? NSUserName() : fullName
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                TextField("Reviewer Name", text: $settings.defaultAuthorName, prompt: Text(systemAuthorName))
            } header: {
                Text("Annotations")
            } footer: {
                Text("Used as the author name when creating new annotations. Leave empty to use your macOS user name.")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 440)
    }
}
