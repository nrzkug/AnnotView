import AppKit
import Combine
import SwiftUI

private struct AnnotViewDocumentRootView: View {
    @ObservedObject var documentManager: PDFDocumentManager
    @ObservedObject var chromeState: ReaderChromeState
    @ObservedObject var appearanceSettings: AppearanceSettings

    var body: some View {
        ContentView()
            .environmentObject(documentManager)
            .environmentObject(chromeState)
            .environmentObject(documentManager.searchController)
            .preferredColorScheme(appearanceSettings.appearance.colorScheme)
            .frame(minWidth: 720, minHeight: 480)
    }
}

@MainActor
final class AnnotDocumentWindowController: NSWindowController, NSWindowDelegate {
    private var cancellables = Set<AnyCancellable>()
    private unowned let pdfDoc: AnnotPDFDocument

    init(document: AnnotPDFDocument) {
        self.pdfDoc = document
        let rootView = AnnotViewDocumentRootView(
            documentManager: document.documentManager,
            chromeState: document.chromeState,
            appearanceSettings: AnnotViewApplicationModel.shared.appearanceSettings
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = document.fileURL?.lastPathComponent ?? "AnnotView"
        window.representedURL = document.fileURL
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.setFrameAutosaveName("AnnotViewReaderMainWindow")

        super.init(window: window)
        window.delegate = self

        document.documentManager.$documentURL
            .receive(on: RunLoop.main)
            .sink { [weak window] url in
                guard let url else { return }
                window?.title = url.lastPathComponent
                window?.representedURL = url
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowDidBecomeMain(_ notification: Notification) {
        AnnotViewApplicationModel.shared.setActiveDocument(pdfDoc)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AnnotViewApplicationModel.shared.setActiveDocument(pdfDoc)
    }

    func windowWillClose(_ notification: Notification) {
        if AnnotViewApplicationModel.shared.activeDocument === pdfDoc {
            let remaining = NSDocumentController.shared.documents
                .compactMap { $0 as? AnnotPDFDocument }
                .first { $0 !== pdfDoc }
            AnnotViewApplicationModel.shared.setActiveDocument(remaining)
        }
    }
}
