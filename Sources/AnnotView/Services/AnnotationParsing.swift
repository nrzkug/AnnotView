import Foundation

/// Implemented by MuPDFAnnotationParser. PDFKit is intentionally not used here:
/// it cannot expose PDF object identifiers or Acrobat's review-state fields.
protocol AnnotationParsing: Sendable {
    func annotations(in documentURL: URL) async throws -> [Annotation]
}
