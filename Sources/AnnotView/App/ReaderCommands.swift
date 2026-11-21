import AppKit
import SwiftUI

struct ReaderCommands: Commands {
    @ObservedObject var documentManager: PDFDocumentManager
    @ObservedObject var chromeState: ReaderChromeState
    @ObservedObject var searchController: PDFSearchController
    @ObservedObject var updater: AppUpdater
    @ObservedObject var appearanceSettings: AppearanceSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") {
                if AnnotViewApplicationModel.shared.activeDocument != nil,
                   documentManager.document == nil {
                    documentManager.requestOpenPanel()
                } else {
                    NSDocumentController.shared.openDocument(nil)
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(documentManager.recentDocuments, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        if let existing = NSDocumentController.shared.document(for: url) {
                            existing.showWindows()
                        } else if AnnotViewApplicationModel.shared.activeDocument != nil,
                                  documentManager.document == nil {
                            Task { await documentManager.open(url: url) }
                        } else {
                            NSDocumentController.shared.openDocument(
                                withContentsOf: url,
                                display: true
                            ) { _, _, _ in }
                        }
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
            Button(chromeState.thumbnailSidebarIsPresented ? "Hide Sidebar" : "Show Sidebar") {
                chromeState.thumbnailSidebarIsPresented.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])

            Button(chromeState.inspectorIsPresented ? "Hide Annotations" : "Show Annotations") {
                withAnimation {
                    chromeState.inspectorIsPresented.toggle()
                }
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

        CommandMenu("Annotate") {
            Picker("Tool", selection: $chromeState.annotationTool.animation()) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Text(tool.label).tag(tool)
                }
            }
            .pickerStyle(.inline)
            .disabled(documentManager.document == nil)

            Divider()

            Button("Highlight Selected Text") {
                NSApp.sendAction(#selector(AnnotationPDFView.applyHighlightToSelection(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("h", modifiers: [.control, .command])
            .disabled(!canApplyMarkup)

            Button("Underline Selected Text") {
                NSApp.sendAction(#selector(AnnotationPDFView.applyUnderlineToSelection(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("u", modifiers: [.control, .command])
            .disabled(!canApplyMarkup)

            Button("Strikethrough Selected Text") {
                NSApp.sendAction(#selector(AnnotationPDFView.applyStrikethroughToSelection(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: [.control, .command])
            .disabled(!canApplyMarkup)
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

    private var canApplyMarkup: Bool {
        documentManager.document != nil
            && chromeState.hasMarkupSelection
            && !documentManager.isSavingAnnotation
            && documentManager.updatingAnnotationIDs.isEmpty
    }
}
