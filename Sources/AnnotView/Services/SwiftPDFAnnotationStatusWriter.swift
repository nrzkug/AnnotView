import Foundation

/// Pure-Swift PDF annotation review-status writer using incremental updates.
/// Maintains 100% behavioral parity with `MuPDFAnnotationStatusWriter`.
actor SwiftPDFAnnotationStatusWriter: AnnotationStatusUpdating {
    private let storeCache: PDFDocumentStoreCache

    init(storeCache: PDFDocumentStoreCache = .shared) {
        self.storeCache = storeCache
    }

    enum StatusWriterError: LocalizedError {
        case annotationNotFound(String)

        var errorDescription: String? {
            switch self {
            case .annotationNotFound(let sourceID):
                "Annotation object \(sourceID) was not found."
            }
        }
    }

    func updateStatuses(
        in documentURL: URL,
        updates: [AnnotationStatusUpdate]
    ) async throws {
        guard !updates.isEmpty else { return }

        let store = try await storeCache.store(for: documentURL)
        let writer = PDFIncrementalWriter(store: store)
        let pages = store.pages()

        for update in updates {
            guard let targetObjNum = SwiftPDFAnnotationWriter.parseObjectNumber(from: update.sourceID),
                  let found = findAnnotation(objNum: targetObjNum, pages: pages, writer: writer) else {
                throw StatusWriterError.annotationNotFound(update.sourceID)
            }

            var dict = found.dict
            dict["StateModel"] = .name(update.status.stateModel)
            dict["State"] = .name(update.status.pdfStateName)
            writer.setObject(.dict(dict), number: found.objNum, generation: found.genNum)
        }

        let suffix = try writer.saveIncrementally(to: documentURL)
        if !suffix.isEmpty {
            await storeCache.update(appending: suffix, to: store, for: documentURL)
        }
    }

    private func findAnnotation(
        objNum targetObjNum: Int,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) -> (objNum: Int, genNum: Int, dict: [String: PDFObject])? {
        for page in pages {
            for entry in writer.pageAnnots(for: page) {
                if case let .indirectRef(objNum, genNum) = entry, objNum == targetObjNum {
                    if let dict = writer.currentObject(number: objNum, generation: genNum)?.dictValue {
                        return (objNum, genNum, dict)
                    }
                }
            }
        }
        return nil
    }
}
