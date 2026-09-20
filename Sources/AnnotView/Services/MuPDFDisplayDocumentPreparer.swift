import CMuPDF
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

    init(executableURL: URL? = nil, scriptURL: URL? = nil) {}

    func displayData(for documentURL: URL) async throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotView-Display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("display.pdf")
        var outError: UnsafeMutablePointer<CChar>?
        let success = documentURL.path.withCString { inPath in
            outputURL.path.withCString { outPath in
                mupdf_bridge_strip_annotations(inPath, outPath, &outError)
            }
        }
        defer {
            if let outError { mupdf_bridge_free(outError) }
        }
        guard success else {
            let msg = outError.flatMap { String(cString: $0) } ?? "Unknown error"
            throw PreparationError.processFailed(status: 1, message: msg)
        }

        let data = try Data(contentsOf: outputURL)
        guard !data.isEmpty else { throw PreparationError.emptyOutput }
        return data
    }
}
