import Foundation

@MainActor
final class UserDefaultsRecentDocumentStore: RecentDocumentStoring {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let key: String
    private let maximumCount: Int

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        key: String = "recentDocumentPaths",
        maximumCount: Int = 10
    ) {
        precondition(maximumCount > 0)
        self.defaults = defaults
        self.fileManager = fileManager
        self.key = key
        self.maximumCount = maximumCount
    }

    func load() -> [URL] {
        let paths = defaults.stringArray(forKey: key) ?? []
        return paths
            .filter(fileManager.fileExists(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    func record(_ url: URL) -> [URL] {
        let standardized = url.standardizedFileURL
        var documents = load()
        documents.removeAll { $0.standardizedFileURL == standardized }
        documents.insert(standardized, at: 0)
        documents = Array(documents.prefix(maximumCount))
        defaults.set(documents.map(\.path), forKey: key)
        return documents
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
