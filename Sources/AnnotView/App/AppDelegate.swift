import AppKit
import Combine
import SwiftUI

@main
struct AnnotViewApp: App {
    @NSApplicationDelegateAdaptor(AnnotViewAppDelegate.self) private var appDelegate
    @ObservedObject private var model = AnnotViewApplicationModel.shared

    var body: some Scene {
        Settings {
            AppearanceSettingsView(settings: model.appearanceSettings)
                .preferredColorScheme(model.appearanceSettings.appearance.colorScheme)
        }
        .commands {
            SidebarCommands()
            ReaderCommands(
                documentManager: model.documentManager,
                chromeState: model.chromeState,
                searchController: model.documentManager.searchController,
                updater: model.updater,
                appearanceSettings: model.appearanceSettings
            )
            AnnotationUndoCommands(documentManager: model.documentManager)
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

@MainActor
final class AnnotViewApplicationModel: ObservableObject {
    static let shared = AnnotViewApplicationModel()

    @Published private(set) var activeDocument: AnnotPDFDocument?
    @Published var documentManager: PDFDocumentManager
    @Published var chromeState: ReaderChromeState
    let appearanceSettings = AppearanceSettings()
    let updater = AppUpdater()

    private let defaultDocumentManager = PDFDocumentManager()
    private let defaultChromeState = ReaderChromeState()

    private init() {
        self.documentManager = defaultDocumentManager
        self.chromeState = defaultChromeState
    }

    func setActiveDocument(_ doc: AnnotPDFDocument?) {
        self.activeDocument = doc
        if let doc {
            self.documentManager = doc.documentManager
            self.chromeState = doc.chromeState
        } else {
            self.documentManager = defaultDocumentManager
            self.chromeState = defaultChromeState
        }
    }

    func open(url: URL) async {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }
}

final class AnnotViewAppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: PDFDocumentController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = PDFDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AnnotViewApplicationModel.shared.updater.start()

        if let path = CommandLine.arguments.dropFirst().first(where: {
            !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf")
        }) {
            let url = URL(fileURLWithPath: path)
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSDocumentController.shared.openDocument(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
