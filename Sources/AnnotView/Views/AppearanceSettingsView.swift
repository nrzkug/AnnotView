import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppearanceSettings
    @StateObject private var cliInstaller = CLIInstaller()

    var body: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            cliSection
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }

    private var cliSection: some View {
        Section {
            LabeledContent {
                actionButton(
                    isWorking: cliInstaller.isWorking,
                    isInstalled: cliInstaller.isInstalled,
                    install: { cliInstaller.install() },
                    uninstall: { cliInstaller.uninstall() }
                )
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("annotool CLI")
                        .font(.body.weight(.medium))
                    Text(cliDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Command Line Tool")
        }
        .onAppear { cliInstaller.refresh() }
    }


    @ViewBuilder
    private func actionButton(
        isWorking: Bool,
        isInstalled: Bool,
        install: @escaping () -> Void,
        uninstall: @escaping () -> Void
    ) -> some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else if isInstalled {
            Button("Uninstall", role: .destructive, action: uninstall)
        } else {
            Button("Install", action: install)
        }
    }

    private var cliDescription: String {
        if cliInstaller.isInstalled {
            var text = "Installed at \(cliInstaller.installedURL?.path ?? "unknown")."
            if cliInstaller.binOnPath {
                text += " On PATH — run `annotool` from any terminal or agent."
            } else {
                text += " Not on your current PATH; add the directory or restart your terminal."
            }
            return text
        }
        return "Installs the annotool CLI so terminals and AI agents can read and "
            + "write Acrobat annotations directly."
    }

}
