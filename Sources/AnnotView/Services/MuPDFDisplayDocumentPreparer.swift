import Foundation

actor MuPDFDisplayDocumentPreparer: PDFDisplayDocumentPreparing {
    func displayData(for documentURL: URL) async throws -> Data {
        try MuPDFBridge.withTemporaryOutput(named: "display.pdf") { outputURL in
            try MuPDFBridge.stripAnnotations(from: documentURL, to: outputURL)
            let data = try Data(contentsOf: outputURL)
            guard !data.isEmpty else {
                throw MuPDFBridge.Failure.emptyOutput(action: "prepare the PDF for display")
            }
            return data
        }
    }
}
