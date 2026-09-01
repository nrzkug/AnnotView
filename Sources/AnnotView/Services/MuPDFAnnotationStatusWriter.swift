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

    private let tool: MuPDFTool
    private let scriptURL: URL?

    init(executableURL: URL? = nil, scriptURL: URL? = nil) {
        tool = MuPDFTool(executableURL: executableURL)
        self.scriptURL = scriptURL
    }

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
        let script = try scriptURL ?? Self.findScript()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotView-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("updated.pdf")
        let payloadURL = temporaryDirectory.appendingPathComponent("statuses.json")
        let payload = StatusPayload(updates: updates.map {
            StatusPayload.Update(
                sourceID: $0.sourceID,
                stateModel: $0.status.stateModel,
                state: $0.status.pdfStateName
            )
        })
        try JSONEncoder().encode(payload).write(to: payloadURL, options: .atomic)
        do {
            _ = try await tool.run(
                script: script,
                arguments: [documentURL.path, outputURL.path, payloadURL.path]
            )
        } catch MuPDFTool.ToolError.executableNotFound {
            throw WriterError.executableNotFound
        } catch MuPDFTool.ToolError.processFailed(let status, let message) {
            throw WriterError.processFailed(status: status, message: message)
        }

        let updatedData = try Data(contentsOf: outputURL)
        guard !updatedData.isEmpty else { throw WriterError.emptyOutput }
        try updatedData.write(to: documentURL, options: .atomic)
    }

    private static func findScript() throws -> URL {
        let url = MuPDFTool.bundledScript(named: "update_annotation_status")
        guard let url else { throw WriterError.scriptNotFound }
        return url
    }
}
