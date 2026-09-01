import Foundation

struct AnnotationStatusUpdate: Sendable {
    let sourceID: String
    let status: Annotation.Status
}

protocol AnnotationStatusUpdating: Sendable {
    func updateStatuses(
        in documentURL: URL,
        updates: [AnnotationStatusUpdate]
    ) async throws
}

extension AnnotationStatusUpdating {
    func updateStatus(
        in documentURL: URL,
        sourceID: String,
        status: Annotation.Status
    ) async throws {
        try await updateStatuses(
            in: documentURL,
            updates: [AnnotationStatusUpdate(sourceID: sourceID, status: status)]
        )
    }
}
