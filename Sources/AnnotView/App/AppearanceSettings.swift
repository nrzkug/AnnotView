import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: key) }
    }

    @Published var defaultAuthorName: String {
        didSet { defaults.set(defaultAuthorName, forKey: authorKey) }
    }

    private let defaults: UserDefaults
    private let key: String
    private let authorKey: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "appearance",
        authorKey: String = "defaultAuthorName"
    ) {
        self.defaults = defaults
        self.key = key
        self.authorKey = authorKey
        appearance = AppAppearance(rawValue: defaults.string(forKey: key) ?? "") ?? .system
        defaultAuthorName = defaults.string(forKey: authorKey) ?? ""
    }
}
