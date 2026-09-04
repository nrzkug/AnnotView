import SwiftUI

struct ReaderCommands: Commands {
    @ObservedObject var documentManager: PDFDocumentManager
    @ObservedObject var chromeState: ReaderChromeState
    @ObservedObject var searchController: PDFSearchController
    @ObservedObject var updater: AppUpdater
    @ObservedObject var appearanceSettings: AppearanceSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") { documentManager.requestOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(documentManager.recentDocuments, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        Task { await documentManager.open(url: url) }
                    }
                    .help(url.deletingLastPathComponent().path)
                }
                Divider()
                Button("Clear Menu") { documentManager.clearRecentDocuments() }
            }
            .disabled(documentManager.recentDocuments.isEmpty)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(chromeState.thumbnailSidebarIsPresented ? "Hide Pages" : "Show Pages") {
                chromeState.thumbnailSidebarIsPresented.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button(chromeState.inspectorIsPresented ? "Hide Annotations" : "Show Annotations") {
                chromeState.inspectorIsPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        CommandMenu("Navigate") {
            Button("Find…") { chromeState.searchIsPresented = true }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(documentManager.document == nil)
            Button("Find Next") { documentManager.selectNextSearchResult() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(searchController.results.isEmpty)
            Button("Find Previous") { documentManager.selectPreviousSearchResult() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(searchController.results.isEmpty)
            Divider()
            Button("Zoom In") { documentManager.requestZoom(.inwards) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(documentManager.document == nil)
            Button("Zoom Out") { documentManager.requestZoom(.outwards) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(documentManager.document == nil)
            Button("Actual Size") { documentManager.requestZoom(.actualSize) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(documentManager.document == nil)
        }

        CommandGroup(after: .help) {
            Button("Copy Debug Info") {
                AppDiagnostics.copy(
                    documentManager: documentManager,
                    appearance: appearanceSettings.appearance,
                    updater: updater
                )
            }
        }
    }
}
