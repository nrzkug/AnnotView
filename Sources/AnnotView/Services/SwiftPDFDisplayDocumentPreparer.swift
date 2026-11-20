import Foundation

/// Pure-Swift display document preparer that strips annotations via an in-memory
/// incremental update (clearing `/Annots` on every page) and returns the resulting PDF bytes.
actor SwiftPDFDisplayDocumentPreparer: PDFDisplayDocumentPreparing {
    enum PreparerError: LocalizedError {
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .emptyOutput:
                "Failed to prepare the PDF for display: empty output."
            }
        }
    }

    func displayData(for documentURL: URL) async throws -> Data {
        let store = try PDFDocumentStore(url: documentURL)
        return try stripAnnotations(in: store)
    }

    func stripAnnotations(in store: PDFDocumentStore) throws -> Data {
        let writer = PDFIncrementalWriter(store: store)
        for page in store.pages() {
            if page.pageDict["Annots"] != nil {
                writer.setPageAnnots([], for: page)
            }
        }
        let data = writer.buildData()
        guard !data.isEmpty else {
            throw PreparerError.emptyOutput
        }
        return data
    }
}
