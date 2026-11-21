import Foundation

/// Pure-Swift display document preparer that strips non-link annotations via an in-memory
/// incremental update (preserving `/Subtype /Link` entries on every page) and returns the resulting PDF bytes.
actor SwiftPDFDisplayDocumentPreparer: PDFDisplayDocumentPreparing {
    private let storeCache: PDFDocumentStoreCache

    init(storeCache: PDFDocumentStoreCache = .shared) {
        self.storeCache = storeCache
    }

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
        let store = try await storeCache.store(for: documentURL)
        return try stripAnnotations(in: store)
    }

    func stripAnnotations(in store: PDFDocumentStore) throws -> Data {
        let writer = PDFIncrementalWriter(store: store)
        for page in store.pages() {
            let existing = writer.pageAnnots(for: page)
            guard !existing.isEmpty else { continue }
            let linksOnly = existing.filter { entry in
                guard let dict = store.resolve(entry)?.dictValue else { return false }
                return store.resolve(dict["Subtype"])?.nameValue == "Link"
            }
            if linksOnly.count != existing.count {
                writer.setPageAnnots(linksOnly, for: page)
            }
        }
        let data = writer.buildData()
        guard !data.isEmpty else {
            throw PreparerError.emptyOutput
        }
        return data
    }
}
