import Foundation
import PDFKit

struct LoadedPDFDocument {
    let document: PDFDocument
    let outlineItems: [DocumentOutlineItem]
}

@MainActor
protocol PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument?
    func build(from url: URL) -> LoadedPDFDocument?
}

extension PDFDocumentBuilding {
    func build(from url: URL) -> LoadedPDFDocument? {
        (try? Data(contentsOf: url)).flatMap { build(from: $0) }
    }
}
