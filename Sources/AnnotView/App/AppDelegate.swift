import AppKit
import SwiftUI

@main
struct AnnotViewApp: App {
    @NSApplicationDelegateAdaptor(AnnotViewAppDelegate.self) private var appDelegate
    private let model = AnnotViewApplicationModel.shared

    var body: some Scene {
        Window("AnnotView", id: "reader") {
            AnnotViewRootView(model: model)
        }
        .defaultSize(width: 1_200, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF…") {
                    model.openDocument()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            AnnotationUndoCommands(documentManager: model.documentManager)

            CommandGroup(after: .toolbar) {
                Divider()
                Button("Show or Hide Pages") {
                    model.chromeState.thumbnailSidebarIsPresented.toggle()
                }
                Button("Show or Hide Annotations") {
                    model.chromeState.inspectorIsPresented.toggle()
                }
            }

            CommandMenu("Navigate") {
                Button("Find…") {
                    model.chromeState.searchIsPresented = true
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    model.documentManager.selectNextSearchResult()
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    model.documentManager.selectPreviousSearchResult()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Zoom In") {
                    model.documentManager.requestZoom(.inwards)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    model.documentManager.requestZoom(.outwards)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    model.documentManager.requestZoom(.actualSize)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            AppearanceSettingsView(settings: model.appearanceSettings)
                .preferredColorScheme(model.appearanceSettings.appearance.colorScheme)
        }
    }
}

private struct AnnotationUndoCommands: Commands {
    @ObservedObject var documentManager: PDFDocumentManager

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(activeTextUndoManager == nil ? documentManager.undoAnnotationTitle : "Undo") {
                if let undoManager = activeTextUndoManager {
                    undoManager.undo()
                    return
                }
                Task { await documentManager.undoAnnotationChange() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(documentManager.isSavingAnnotation || undoIsDisabled)

            Button(activeTextUndoManager == nil ? documentManager.redoAnnotationTitle : "Redo") {
                if let undoManager = activeTextUndoManager {
                    undoManager.redo()
                    return
                }
                Task { await documentManager.redoAnnotationChange() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(documentManager.isSavingAnnotation || redoIsDisabled)
        }
    }

    private var undoIsDisabled: Bool {
        if let undoManager = activeTextUndoManager {
            return !undoManager.canUndo
        }
        return !documentManager.canUndoAnnotationChange
    }

    private var redoIsDisabled: Bool {
        if let undoManager = activeTextUndoManager {
            return !undoManager.canRedo
        }
        return !documentManager.canRedoAnnotationChange
    }

    private var activeTextUndoManager: UndoManager? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView.undoManager
    }
}

private struct AnnotViewRootView: View {
    let model: AnnotViewApplicationModel
    @ObservedObject private var appearanceSettings: AppearanceSettings

    init(model: AnnotViewApplicationModel) {
        self.model = model
        appearanceSettings = model.appearanceSettings
    }

    var body: some View {
        ContentView()
            .environmentObject(model.documentManager)
            .environmentObject(model.chromeState)
            .environmentObject(model.documentManager.searchController)
            .preferredColorScheme(appearanceSettings.appearance.colorScheme)
    }
}

@MainActor
final class AnnotViewApplicationModel {
    static let shared = AnnotViewApplicationModel()

    let documentManager = PDFDocumentManager()
    let chromeState = ReaderChromeState()
    let appearanceSettings = AppearanceSettings()

    private var initialDocumentFlowStarted = false
    private var receivedExternalDocument = false
    private var externalOpenTask: Task<Void, Never>?
    private weak var readerWindow: NSWindow?

    private init() {}

    func openDocument() {
        Task { await documentManager.presentOpenPanel() }
    }

    func hideReaderWindowForInitialOpen() {
        captureReaderWindow()
        readerWindow?.orderOut(nil)
    }

    func openFromSystem(_ url: URL) {
        receivedExternalDocument = true
        documentManager.cancelOpenPanel()
        externalOpenTask = Task {
            await documentManager.open(url: url)
            showReaderWindowIfReady()
        }
    }

    func runInitialDocumentFlow() async {
        guard !initialDocumentFlowStarted else { return }
        initialDocumentFlowStarted = true

        hideReaderWindowForInitialOpen()
        if readerWindow == nil {
            await Task.yield()
            hideReaderWindowForInitialOpen()
        }

        // Launch Services can deliver an open-document event shortly after the
        // app finishes launching. Keep the reader hidden while allowing that
        // event to arrive before presenting a standalone open panel.
        try? await Task.sleep(for: .milliseconds(250))
        if receivedExternalDocument {
            await externalOpenTask?.value
            showReaderWindowIfReady()
            return
        }

        await documentManager.openCommandLineDocumentIfPresent()
        if documentManager.document != nil || receivedExternalDocument {
            await externalOpenTask?.value
            showReaderWindowIfReady()
            return
        }

        await documentManager.presentOpenPanel()
        if receivedExternalDocument {
            await externalOpenTask?.value
            showReaderWindowIfReady()
            return
        }

        if documentManager.document == nil, documentManager.errorMessage == nil {
            NSApp.terminate(nil)
        } else {
            showReaderWindowIfReady()
        }
    }

    private func captureReaderWindow() {
        guard readerWindow == nil else { return }
        readerWindow = NSApp.windows.first { !($0 is NSPanel) }
    }

    private func showReaderWindowIfReady() {
        guard documentManager.document != nil || documentManager.errorMessage != nil else { return }
        captureReaderWindow()
        readerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AnnotViewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let manager = AnnotViewApplicationModel.shared.documentManager
        return manager.document != nil || manager.errorMessage != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AnnotViewApplicationModel.shared
        let automaticTerminationReason = "Opening the initial PDF document"
        ProcessInfo.processInfo.disableAutomaticTermination(automaticTerminationReason)
        model.hideReaderWindowForInitialOpen()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            defer {
                ProcessInfo.processInfo.enableAutomaticTermination(automaticTerminationReason)
            }
            await model.runInitialDocumentFlow()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        AnnotViewApplicationModel.shared.openFromSystem(url)
    }
}
