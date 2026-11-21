import AppKit
import PDFKit

/// Owns one document's search query, result cursor, and navigation requests.
/// Document loading can reset this state without coupling its other concerns
/// to PDFKit's search-result bookkeeping.
@MainActor
final class PDFSearchController: ObservableObject {
    @Published var query = "" {
        didSet {
            if oldValue != query {
                hasCompletedSearch = false
            }
        }
    }
    @Published private(set) var results: [PDFSelection] = []
    @Published private(set) var currentResultIndex: Int?
    @Published private(set) var navigationID = 0
    @Published private(set) var isSearching = false
    @Published private(set) var hasCompletedSearch = false
    @Published private(set) var resultsRevision = 0

    private weak var activeDocument: PDFDocument?
    private var activeProxy: SearchDelegateProxy?
    private var pendingMatches: [PDFSelection] = []
    private var searchToken = 0
    private var onFirstMatchPage: (@MainActor (Int) -> Void)?

    var resultSummary: String {
        if let currentResultIndex {
            return "\(currentResultIndex + 1) of \(results.count)"
        }
        if results.isEmpty {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return (hasCompletedSearch && !isSearching && !trimmed.isEmpty) ? "No results" : ""
        }
        return "0 of \(results.count)"
    }

    func perform(in document: PDFDocument?) -> Int? {
        cancelActiveSearch()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !normalizedQuery.isEmpty else {
            reset()
            return nil
        }

        let found = document.findString(normalizedQuery, withOptions: .caseInsensitive)
        found.forEach { $0.color = NSColor.systemYellow.withAlphaComponent(0.45) }
        results = found
        currentResultIndex = found.isEmpty ? nil : 0
        isSearching = false
        hasCompletedSearch = true
        resultsRevision += 1
        return focusCurrentResult(in: document)
    }

    func performAsync(
        in document: PDFDocument?,
        onFirstMatchPage: @escaping @MainActor (Int) -> Void = { _ in }
    ) {
        cancelActiveSearch()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let document, !normalizedQuery.isEmpty else {
            reset()
            return
        }

        searchToken += 1
        let token = searchToken
        results = []
        currentResultIndex = nil
        isSearching = true
        hasCompletedSearch = false
        resultsRevision += 1
        self.onFirstMatchPage = onFirstMatchPage

        let proxy = SearchDelegateProxy(token: token, controller: self)
        activeDocument = document
        activeProxy = proxy
        document.delegate = proxy
        document.beginFindString(normalizedQuery, withOptions: .caseInsensitive)
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
        cancelActiveSearch()
        results = []
        currentResultIndex = nil
        isSearching = false
        hasCompletedSearch = false
        resultsRevision += 1
        navigationID += 1
    }

    private func cancelActiveSearch() {
        searchToken += 1
        if let activeDocument {
            if activeDocument.isFinding {
                activeDocument.cancelFindString()
            }
            if activeDocument.delegate === activeProxy {
                activeDocument.delegate = nil
            }
        }
        activeDocument = nil
        activeProxy = nil
        pendingMatches.removeAll()
        onFirstMatchPage = nil
    }

    fileprivate func handleMatch(_ selection: PDFSelection, token: Int) {
        guard token == searchToken, let activeDocument else { return }
        selection.color = NSColor.systemYellow.withAlphaComponent(0.45)

        if results.isEmpty && pendingMatches.isEmpty {
            results = [selection]
            currentResultIndex = 0
            resultsRevision += 1
            if let pageIndex = focusCurrentResult(in: activeDocument),
               let onFirstMatchPage {
                onFirstMatchPage(pageIndex)
            }
        } else {
            pendingMatches.append(selection)
            if pendingMatches.count >= 25 {
                flushPendingMatches()
            }
        }
    }

    fileprivate func handlePageEnd(token: Int) {
        guard token == searchToken else { return }
        flushPendingMatches()
    }

    fileprivate func handleSearchEnd(token: Int) {
        guard token == searchToken else { return }
        flushPendingMatches()
        isSearching = false
        hasCompletedSearch = true
        if let activeDocument, activeDocument.delegate === activeProxy {
            activeDocument.delegate = nil
        }
        activeDocument = nil
        activeProxy = nil
        onFirstMatchPage = nil
    }

    private func flushPendingMatches() {
        guard !pendingMatches.isEmpty else { return }
        results.append(contentsOf: pendingMatches)
        pendingMatches.removeAll(keepingCapacity: true)
        resultsRevision += 1
    }

    private func focusCurrentResult(in document: PDFDocument) -> Int? {
        guard let currentResultIndex, results.indices.contains(currentResultIndex) else {
            return nil
        }
        navigationID += 1
        return results[currentResultIndex].pages.first.flatMap(document.validPageIndex(for:))
    }
}

private struct UncheckedSelectionBox: @unchecked Sendable {
    let selection: PDFSelection
}

private final class SearchDelegateProxy: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    let token: Int
    weak var controller: PDFSearchController?

    init(token: Int, controller: PDFSearchController) {
        self.token = token
        self.controller = controller
    }

    func didMatchString(_ instance: PDFSelection) {
        let box = UncheckedSelectionBox(selection: instance)
        let token = self.token
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller?.handleMatch(box.selection, token: token)
            }
        } else {
            Task { @MainActor [weak controller] in
                controller?.handleMatch(box.selection, token: token)
            }
        }
    }

    @objc func documentDidEndPageFind(_ notification: Notification) {
        let token = self.token
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller?.handlePageEnd(token: token)
            }
        } else {
            Task { @MainActor [weak controller] in
                controller?.handlePageEnd(token: token)
            }
        }
    }

    @objc func documentDidEndDocumentFind(_ notification: Notification) {
        let token = self.token
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller?.handleSearchEnd(token: token)
            }
        } else {
            Task { @MainActor [weak controller] in
                controller?.handleSearchEnd(token: token)
            }
        }
    }
}
