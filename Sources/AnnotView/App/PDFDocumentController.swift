import AppKit

@MainActor
final class PDFDocumentController: NSDocumentController {
    override var defaultType: String? {
        "PDF document"
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        AnnotPDFDocument.self
    }
}
