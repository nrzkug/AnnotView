import Foundation

/// Persists the ordered list of documents shown in the reader's recent-files UI.
///
/// Keeping storage behind this boundary prevents the document session from
/// depending directly on `UserDefaults` and makes retention policy testable.
@MainActor
protocol RecentDocumentStoring {
    func load() -> [URL]
    func record(_ url: URL) -> [URL]
    func clear()
}
