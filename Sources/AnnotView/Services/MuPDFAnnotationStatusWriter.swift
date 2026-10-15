import Foundation

actor MuPDFAnnotationStatusWriter: AnnotationStatusUpdating {
    private struct StatusPayload: Encodable {
        struct Update: Encodable {
            let sourceID: String
            let stateModel: String
            let state: String
        }

        let version = 1
        let updates: [Update]
    }

    func updateStatuses(
        in documentURL: URL,
        updates: [AnnotationStatusUpdate]
    ) async throws {
        guard !updates.isEmpty else { return }
        let payload = StatusPayload(updates: updates.map {
            StatusPayload.Update(
                sourceID: $0.sourceID,
                stateModel: $0.status.stateModel,
                state: $0.status.pdfStateName
            )
        })
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try MuPDFBridge.withTemporaryOutput(named: "updated.pdf") { outputURL in
            try MuPDFBridge.updateStatuses(
                from: documentURL, to: outputURL, statusesJSON: payloadJSON
            )
            try MuPDFBridge.replaceAtomically(documentURL, with: outputURL, action: "update review states")
        }
    }
}
