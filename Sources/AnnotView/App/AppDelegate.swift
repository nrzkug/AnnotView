import AppKit
import Combine
import SwiftUI

@main
struct AnnotViewApp: App {
    @NSApplicationDelegateAdaptor(AnnotViewAppDelegate.self) private var appDelegate
    private let model = AnnotViewApplicationModel.shared

    var body: some Scene {
        Settings {
            AppearanceSettingsView(settings: model.appearanceSettings)
                .preferredColorScheme(model.appearanceSettings.appearance.colorScheme)
        }
        .commands {
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
            .frame(minWidth: 720, minHeight: 480)
    }
}

@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    private var cancellables = Set<AnyCancellable>()

    convenience init(model: AnnotViewApplicationModel) {
        let rootView = AnnotViewRootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "AnnotView"
        window.setContentSize(NSSize(width: 1_200, height: 760))
        window.minSize = NSSize(width: 720, height: 480)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AnnotViewReaderMainWindow")

        self.init(window: window)
        window.delegate = self

        model.documentManager.$documentURL
            .receive(on: RunLoop.main)
            .sink { [weak window] url in
                window?.title = url?.lastPathComponent ?? "AnnotView"
                window?.representedURL = url
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class AnnotViewApplicationModel: ObservableObject {
    static let shared = AnnotViewApplicationModel()

    let documentManager = PDFDocumentManager()
    let chromeState = ReaderChromeState()
    let appearanceSettings = AppearanceSettings()
    let updater = AppUpdater()

    private(set) var windowController: ReaderWindowController?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        documentManager.$document
            .combineLatest(documentManager.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] document, errorMessage in
                if document != nil || errorMessage != nil {
                    self?.showReaderWindow()
                }
            }
            .store(in: &cancellables)
    }

    func open(url: URL) async {
        documentManager.cancelOpenPanel()
        await documentManager.open(url: url)
        showReaderWindow()
    }

    func presentInitialOpenPanel() async {
        await documentManager.presentOpenPanel()
        if documentManager.document == nil && documentManager.errorMessage == nil {
            if windowController?.window?.isVisible != true {
                NSApp.terminate(nil)
            }
        } else {
            showReaderWindow()
        }
    }

    func showReaderWindow() {
        guard documentManager.document != nil || documentManager.errorMessage != nil else { return }
        if windowController == nil {
            windowController = ReaderWindowController(model: self)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AnnotViewAppDelegate: NSObject, NSApplicationDelegate {
    private var openedInitialDocument = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AnnotViewApplicationModel.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        model.updater.start()

        if let path = CommandLine.arguments.dropFirst().first(where: {
            !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf")
        }) {
            openedInitialDocument = true
            Task { @MainActor in
                await model.open(url: URL(fileURLWithPath: path))
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        openedInitialDocument = true
        Task { @MainActor in
            await AnnotViewApplicationModel.shared.open(url: url)
        }
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !openedInitialDocument else { return true }
        Task { @MainActor in
            await AnnotViewApplicationModel.shared.presentInitialOpenPanel()
        }
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in
                await AnnotViewApplicationModel.shared.presentInitialOpenPanel()
            }
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let manager = AnnotViewApplicationModel.shared.documentManager
        return manager.document != nil || manager.errorMessage != nil
    }
}
