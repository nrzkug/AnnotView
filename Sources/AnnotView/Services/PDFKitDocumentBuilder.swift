import Foundation
import PDFKit

@MainActor
struct PDFKitDocumentBuilder: PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument? {
        guard let document = PDFDocument(data: data) else { return nil }

        // PDFKit renders page content only. All annotations are drawn by the overlay.
        for pageIndex in 0..<document.pageCount {
            document.page(at: pageIndex)?.displaysAnnotations = false
        }

        return LoadedPDFDocument(
            document: document,
            outlineItems: Self.makeOutlineItems(document: document)
        )
    }

    private static func makeOutlineItems(document: PDFDocument) -> [DocumentOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            root.child(at: index).map { makeOutlineItem($0, document: document) }
        }
    }

    private static func makeOutlineItem(
        _ outline: PDFOutline,
        document: PDFDocument
    ) -> DocumentOutlineItem {
        let children = (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { makeOutlineItem($0, document: document) }
        }
        let pageIndex = outline.destination?.page.map(document.index(for:))
        let title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentOutlineItem(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
            pageIndex: pageIndex,
            children: children
        )
    }
}
