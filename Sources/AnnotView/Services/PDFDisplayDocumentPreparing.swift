import Foundation

protocol PDFDisplayDocumentPreparing: Sendable {
    func displayData(for documentURL: URL) async throws -> Data
}

