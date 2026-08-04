import Foundation
import PDFKit

struct LoadedPDFDocument {
    let document: PDFDocument
    let outlineItems: [DocumentOutlineItem]
}

@MainActor
protocol PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument?
}
