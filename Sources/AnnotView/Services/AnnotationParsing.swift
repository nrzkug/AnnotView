import Foundation

/// MuPDF will implement this protocol in Phase 2. PDFKit is intentionally not used here.
protocol AnnotationParsing: Sendable {
    func annotations(in documentURL: URL) async throws -> [Annotation]
}

struct EmptyAnnotationParser: AnnotationParsing {
    func annotations(in documentURL: URL) async throws -> [Annotation] {
        []
    }
}
