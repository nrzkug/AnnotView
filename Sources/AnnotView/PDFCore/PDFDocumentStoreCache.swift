import Darwin
import Foundation

/// Bounded LRU cache of parsed `PDFDocumentStore` instances keyed by canonical file path.
/// Uses POSIX `stat` metadata (size, inode, nanosecond mtime) to detect external file changes.
actor PDFDocumentStoreCache {
    static let shared = PDFDocumentStoreCache()

    private struct FileSignature: Equatable, Sendable {
        let size: Int64
        let inode: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int

        static func current(for url: URL) -> FileSignature? {
            let path = url.resolvingSymlinksInPath().path
            var st = Darwin.stat()
            guard stat(path, &st) == 0 else { return nil }
            return FileSignature(
                size: Int64(st.st_size),
                inode: UInt64(st.st_ino),
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec
            )
        }
    }

    private struct Entry {
        let store: PDFDocumentStore
        let signature: FileSignature
        let password: String
    }

    private let maxEntries = 4
    private var entries: [String: Entry] = [:]
    private var lruKeys: [String] = []

    /// Returns a cached `PDFDocumentStore` if the on-disk file signature matches,
    /// otherwise parses from disk and caches the result.
    func store(for url: URL, password: String = "") throws -> PDFDocumentStore {
        let key = cacheKey(for: url)
        let signature = FileSignature.current(for: url)

        if let signature,
           let cached = entries[key],
           cached.signature == signature,
           cached.password == password {
            touch(key)
            return cached.store
        }

        let parsed = try PDFDocumentStore(url: url, password: password)
        if let updatedSignature = FileSignature.current(for: url) ?? signature {
            insert(Entry(store: parsed, signature: updatedSignature, password: password), for: key)
        } else {
            remove(key)
        }
        return parsed
    }

    /// Updates the cached `PDFDocumentStore` directly from newly written bytes after disk replacement.
    func update(data: Data, for url: URL, password: String = "") {
        let key = cacheKey(for: url)
        guard let signature = FileSignature.current(for: url),
              let parsed = try? PDFDocumentStore(data: data, password: password) else {
            remove(key)
            return
        }
        insert(Entry(store: parsed, signature: signature, password: password), for: key)
    }

    /// Updates the cached `PDFDocumentStore` by appending an incremental suffix onto `baseStore.rawData`.
    func update(appending suffix: Data, to baseStore: PDFDocumentStore, for url: URL, password: String = "") {
        var nextData = Data(capacity: baseStore.rawData.count + suffix.count)
        nextData.append(baseStore.rawData)
        nextData.append(suffix)
        update(data: nextData, for: url, password: password)
    }

    func invalidate(for url: URL) {
        remove(cacheKey(for: url))
    }

    func clear() {
        entries.removeAll()
        lruKeys.removeAll()
    }

    private func cacheKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func touch(_ key: String) {
        lruKeys.removeAll { $0 == key }
        lruKeys.append(key)
    }

    private func insert(_ entry: Entry, for key: String) {
        entries[key] = entry
        touch(key)
        while lruKeys.count > maxEntries {
            let evicted = lruKeys.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    private func remove(_ key: String) {
        entries.removeValue(forKey: key)
        lruKeys.removeAll { $0 == key }
    }
}
