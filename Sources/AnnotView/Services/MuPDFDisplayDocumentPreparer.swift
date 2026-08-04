import Foundation

actor MuPDFDisplayDocumentPreparer: PDFDisplayDocumentPreparing {
    enum PreparationError: LocalizedError {
        case executableNotFound
        case scriptNotFound
        case processFailed(status: Int32, message: String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                "MuPDF's mutool executable was not found."
            case .scriptNotFound:
                "The bundled MuPDF display-preparation script is missing."
            case .processFailed(let status, let message):
                "MuPDF could not prepare the PDF for display (status \(status)): \(message)"
            case .emptyOutput:
                "MuPDF did not produce a display copy."
            }
        }
    }

    private let tool: MuPDFTool
    private let scriptURL: URL?

    init(executableURL: URL? = nil, scriptURL: URL? = nil) {
        tool = MuPDFTool(executableURL: executableURL)
        self.scriptURL = scriptURL
    }

    func displayData(for documentURL: URL) async throws -> Data {
        let script = try scriptURL ?? Self.findScript()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotView-Display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("display.pdf")
        do {
            _ = try await tool.run(
                script: script,
                arguments: [documentURL.path, outputURL.path]
            )
        } catch MuPDFTool.ToolError.executableNotFound {
            throw PreparationError.executableNotFound
        } catch MuPDFTool.ToolError.processFailed(let status, let message) {
            throw PreparationError.processFailed(status: status, message: message)
        }

        let data = try Data(contentsOf: outputURL)
        guard !data.isEmpty else { throw PreparationError.emptyOutput }
        return data
    }

    private static func findScript() throws -> URL {
        let url = MuPDFTool.bundledScript(named: "strip_annotations")
        guard let url else { throw PreparationError.scriptNotFound }
        return url
    }
}
