import CMuPDF
import Foundation

actor MuPDFAnnotationStatusWriter: AnnotationStatusUpdating {
    enum WriterError: LocalizedError {
        case executableNotFound
        case scriptNotFound
        case processFailed(status: Int32, message: String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                "MuPDF's mutool executable was not found."
            case .scriptNotFound:
                "The bundled MuPDF status-writing script is missing."
            case .processFailed(let status, let message):
                "MuPDF could not update the annotation (status \(status)): \(message)"
            case .emptyOutput:
                "MuPDF did not produce an updated PDF."
            }
        }
    }

    init(executableURL: URL? = nil, scriptURL: URL? = nil) {}

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
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotView-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("updated.pdf")
        let payload = StatusPayload(updates: updates.map {
            StatusPayload.Update(
                sourceID: $0.sourceID,
                stateModel: $0.status.stateModel,
                state: $0.status.pdfStateName
            )
        })
        let payloadData = try JSONEncoder().encode(payload)
        guard let payloadString = String(data: payloadData, encoding: .utf8) else {
            throw WriterError.emptyOutput
        }

        var outError: UnsafeMutablePointer<CChar>?
        let success = documentURL.path.withCString { inPath in
            outputURL.path.withCString { outPath in
                payloadString.withCString { statusesJSON in
                    mupdf_bridge_update_statuses(inPath, outPath, statusesJSON, &outError)
                }
            }
        }
        defer {
            if let outError { mupdf_bridge_free(outError) }
        }
        guard success else {
            let msg = outError.flatMap { String(cString: $0) } ?? "Unknown error"
            throw WriterError.processFailed(status: 1, message: msg)
        }

        let updatedData = try Data(contentsOf: outputURL)
        guard !updatedData.isEmpty else { throw WriterError.emptyOutput }
        try updatedData.write(to: documentURL, options: .atomic)
    }
}
