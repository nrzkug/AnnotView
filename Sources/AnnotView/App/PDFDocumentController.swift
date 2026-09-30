import AppKit

@MainActor
final class PDFDocumentController: NSDocumentController {
    private var openPanelIsPresented = false

    override var defaultType: String? {
        "PDF document"
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        AnnotPDFDocument.self
    }

    override func openDocument(_ sender: Any?) {
        guard !openPanelIsPresented else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard NSApp.modalWindow == nil else { return }
        super.openDocument(sender)
    }

    override func beginOpenPanel(completionHandler: @escaping ([URL]?) -> Void) {
        guard !openPanelIsPresented else {
            completionHandler(nil)
            return
        }
        openPanelIsPresented = true
        super.beginOpenPanel { [weak self] urls in
            completionHandler(urls)
            Task { @MainActor in
                self?.openPanelIsPresented = false
            }
        }
    }
}
