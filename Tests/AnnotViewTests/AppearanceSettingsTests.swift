import Foundation
import Testing
@testable import AnnotView

@Suite(.serialized)
struct AppearanceSettingsTests {
    @Test @MainActor
    func restoresValidAppearanceAndPersistsChanges() throws {
        let suiteName = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppAppearance.dark.rawValue, forKey: "testAppearance")

        let settings = AppearanceSettings(defaults: defaults, key: "testAppearance")
        #expect(settings.appearance == .dark)

        settings.appearance = .light
        #expect(defaults.string(forKey: "testAppearance") == AppAppearance.light.rawValue)
    }

    @Test @MainActor
    func fallsBackToSystemForUnknownStoredValue() throws {
        let suiteName = "AppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: "testAppearance")

        let settings = AppearanceSettings(defaults: defaults, key: "testAppearance")
        #expect(settings.appearance == .system)
        #expect(settings.appearance.colorScheme == nil)
    }
}
