import Foundation
import Testing
@testable import AnnotView

@Suite(.serialized)
struct UserDefaultsRecentDocumentStoreTests {
    @Test @MainActor
    func recordsMostRecentFirstWithoutDuplicatesAndAppliesLimit() throws {
        let fixture = try Fixture(maximumCount: 2)
        defer { fixture.cleanUp() }

        let first = try fixture.makeFile(named: "first.pdf")
        let second = try fixture.makeFile(named: "second.pdf")
        let third = try fixture.makeFile(named: "third.pdf")

        #expect(fixture.store.record(first) == [first])
        #expect(fixture.store.record(second) == [second, first])
        #expect(fixture.store.record(first) == [first, second])
        #expect(fixture.store.record(third) == [third, first])
        #expect(fixture.store.load() == [third, first])
    }

    @Test @MainActor
    func excludesMissingFilesAndClearsPersistence() throws {
        let fixture = try Fixture(maximumCount: 3)
        defer { fixture.cleanUp() }

        let existing = try fixture.makeFile(named: "existing.pdf")
        let missing = fixture.directory.appendingPathComponent("missing.pdf")
        fixture.defaults.set([missing.path, existing.path], forKey: fixture.key)

        #expect(fixture.store.load() == [existing])
        fixture.store.clear()
        #expect(fixture.store.load().isEmpty)
        #expect(fixture.defaults.object(forKey: fixture.key) == nil)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let suiteName: String
        let key = "testRecentDocumentPaths"
        let defaults: UserDefaults
        let store: UserDefaultsRecentDocumentStore

        init(maximumCount: Int) throws {
            suiteName = "UserDefaultsRecentDocumentStoreTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(suiteName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            store = UserDefaultsRecentDocumentStore(
                defaults: defaults,
                key: key,
                maximumCount: maximumCount
            )
        }

        func makeFile(named name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
