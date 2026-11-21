import Foundation
import PDFKit

struct LoadedPDFDocument: @unchecked Sendable {
    let document: PDFDocument
    let outlineItems: [DocumentOutlineItem]
}

@MainActor
protocol PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument?
    func build(from url: URL) -> LoadedPDFDocument?
    func load(from data: Data) async -> LoadedPDFDocument?
    func load(from url: URL) async -> LoadedPDFDocument?
}

extension PDFDocumentBuilding {
    func build(from url: URL) -> LoadedPDFDocument? {
        (try? Data(contentsOf: url)).flatMap { build(from: $0) }
    }

    func load(from data: Data) async -> LoadedPDFDocument? {
        build(from: data)
    }

    func load(from url: URL) async -> LoadedPDFDocument? {
        build(from: url)
    }
}
