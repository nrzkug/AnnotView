import Foundation
import PDFKit

@MainActor
struct PDFKitDocumentBuilder: PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument? {
        Self.buildDocument(from: data)
    }

    func build(from url: URL) -> LoadedPDFDocument? {
        Self.buildDocument(from: url)
    }

    func load(from data: Data) async -> LoadedPDFDocument? {
        await Task.detached(priority: .userInitiated) {
            Self.buildDocument(from: data)
        }.value
    }

    func load(from url: URL) async -> LoadedPDFDocument? {
        await Task.detached(priority: .userInitiated) {
            Self.buildDocument(from: url)
        }.value
    }

    nonisolated private static func buildDocument(from data: Data) -> LoadedPDFDocument? {
        guard let document = PDFDocument(data: data) else { return nil }
        prepareDocument(document)
        return LoadedPDFDocument(
            document: document,
            outlineItems: makeOutlineItems(document: document)
        )
    }

    nonisolated private static func buildDocument(from url: URL) -> LoadedPDFDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        prepareDocument(document)
        return LoadedPDFDocument(
            document: document,
            outlineItems: makeOutlineItems(document: document)
        )
    }

    nonisolated private static func prepareDocument(_ document: PDFDocument) {
        // PDFKit renders page content only. Annotations are drawn by AnnotView's custom overlay.
        // Strip non-link annotations in memory so PDFKit will not render them natively,
        // while preserving native Link annotations for document navigation.
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if pageMayHaveAnnotations(page) {
                let nonLinks = page.annotations.filter { $0.type != "Link" }
                for annotation in nonLinks {
                    page.removeAnnotation(annotation)
                }
            }
            page.displaysAnnotations = false
        }
    }

    nonisolated private static func pageMayHaveAnnotations(_ page: PDFPage) -> Bool {
        guard let pageDict = page.pageRef?.dictionary else {
            return true
        }
        var annotsObject: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(pageDict, "Annots", &annotsObject) else {
            return false
        }
        var annotsArray: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(pageDict, "Annots", &annotsArray),
           let annotsArray,
           CGPDFArrayGetCount(annotsArray) == 0 {
            return false
        }
        return true
    }

    nonisolated private static func makeOutlineItems(document: PDFDocument) -> [DocumentOutlineItem] {
        guard let root = document.outlineRoot else { return [] }
        return (0..<root.numberOfChildren).compactMap { index in
            root.child(at: index).map { makeOutlineItem($0, document: document) }
        }
    }

    nonisolated private static func makeOutlineItem(
        _ outline: PDFOutline,
        document: PDFDocument
    ) -> DocumentOutlineItem {
        let children = (0..<outline.numberOfChildren).compactMap { index in
            outline.child(at: index).map { makeOutlineItem($0, document: document) }
        }
        let pageIndex = outline.destination?.page.flatMap(document.validPageIndex(for:))
        let title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DocumentOutlineItem(
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
            pageIndex: pageIndex,
            children: children
        )
    }
}

extension PDFDocument {
    nonisolated func validPageIndex(for page: PDFPage) -> Int? {
        let index = self.index(for: page)
        guard index != NSNotFound, index >= 0, index < pageCount else { return nil }
        return index
    }
}
