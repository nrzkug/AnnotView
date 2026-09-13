import Foundation
import PDFKit

@MainActor
struct PDFKitDocumentBuilder: PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument? {
        guard let document = PDFDocument(data: data) else { return nil }
        Self.prepareDocument(document)
        return LoadedPDFDocument(
            document: document,
            outlineItems: Self.makeOutlineItems(document: document)
        )
    }

    func build(from url: URL) -> LoadedPDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        Self.prepareDocument(document)
        return LoadedPDFDocument(
            document: document,
            outlineItems: Self.makeOutlineItems(document: document)
        )
    }

    private static func prepareDocument(_ document: PDFDocument) {
        // PDFKit renders page content only. Annotations are drawn by AnnotView's custom overlay.
        // Strip non-link annotations in memory so PDFKit will not render them natively,
        // while preserving native Link annotations for document navigation.
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let nonLinks = page.annotations.filter { $0.type != "Link" }
            for annotation in nonLinks {
                page.removeAnnotation(annotation)
            }
            page.displaysAnnotations = false
        }
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
