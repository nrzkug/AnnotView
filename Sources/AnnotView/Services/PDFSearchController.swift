import AppKit
import PDFKit

/// Owns one document's search query, result cursor, and navigation requests.
/// Document loading can reset this state without coupling its other concerns
/// to PDFKit's search-result bookkeeping.
@MainActor
final class PDFSearchController: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [PDFSelection] = []
    @Published private(set) var currentResultIndex: Int?
    @Published private(set) var navigationID = 0

    var resultSummary: String {
        guard let currentResultIndex else {
            return results.isEmpty ? "" : "0 of \(results.count)"
        }
        return "\(currentResultIndex + 1) of \(results.count)"
    }

    func perform(in document: PDFDocument?) -> Int? {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !normalizedQuery.isEmpty else {
            reset()
            return nil
        }

        results = document.findString(normalizedQuery, withOptions: .caseInsensitive)
        results.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        currentResultIndex = results.isEmpty ? nil : 0
        return focusCurrentResult(in: document)
    }

    func selectNext(in document: PDFDocument?) -> Int? {
        guard let document, !results.isEmpty else { return nil }
        currentResultIndex = ((currentResultIndex ?? -1) + 1) % results.count
        return focusCurrentResult(in: document)
    }

    func selectPrevious(in document: PDFDocument?) -> Int? {
        guard let document, !results.isEmpty else { return nil }
        currentResultIndex = ((currentResultIndex ?? 0) - 1 + results.count) % results.count
        return focusCurrentResult(in: document)
    }

    func reset() {
        results = []
        currentResultIndex = nil
        navigationID += 1
    }

    private func focusCurrentResult(in document: PDFDocument) -> Int? {
        guard let currentResultIndex, results.indices.contains(currentResultIndex) else {
            return nil
        }
        navigationID += 1
        return results[currentResultIndex].pages.first.map(document.index(for:))
    }
}
