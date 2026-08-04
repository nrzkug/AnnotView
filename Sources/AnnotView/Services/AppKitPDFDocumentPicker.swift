import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppKitPDFDocumentPicker: PDFDocumentPicking {
    private var activePanel: NSOpenPanel?

    func pickDocument() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Open PDF"
        activePanel = panel

        let response = panel.runModal()
        if activePanel === panel { activePanel = nil }
        return response == .OK ? panel.url : nil
    }

    func cancel() {
        activePanel?.cancel(nil)
        activePanel = nil
    }
}
