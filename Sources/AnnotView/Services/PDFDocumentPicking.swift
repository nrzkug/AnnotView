import Foundation

@MainActor
protocol PDFDocumentPicking: AnyObject {
    func pickDocument() -> URL?
    func cancel()
}
