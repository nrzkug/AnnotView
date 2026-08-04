import Foundation

protocol AnnotationStatusUpdating: Sendable {
    func updateStatus(
        in documentURL: URL,
        sourceID: String,
        status: Annotation.Status
    ) async throws
}
