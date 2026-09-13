# Reusable macOS app shell

These patterns are the reusable outer shell extracted from the two apps. Keep
feature views, models, and services behind `ContentView` or another root
composition boundary.

## SwiftPM entry point and scenes

Sources: `Gakuyu/Sources/GakuyuApp/App/GakuyuApp.swift` and
`AnnotView/Sources/AnnotView/App/AppDelegate.swift`.

```swift
import SwiftUI

@main
struct ExampleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appearanceSettings = AppearanceSettings()

    var body: some Scene {
        Window("Example", id: "main") {
            ContentView()
                .preferredColorScheme(appearanceSettings.appearance.colorScheme)
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands()
        }

        Settings {
            SettingsView()
                .preferredColorScheme(appearanceSettings.appearance.colorScheme)
        }
    }
}
```

The `Window`/`WindowGroup` choice is a product decision: use a single
identifier when the app owns one primary window, and use `WindowGroup` when
multiple document instances are intentional. Do not copy a feature's concrete
settings or model container into this shell; inject those dependencies from
the root only when the app needs them.

## Menu commands

Sources: `AnnotView/Sources/AnnotView/App/ReaderCommands.swift` and
`Gakuyu/Sources/GakuyuApp/App/GakuyuApp.swift`.

```swift
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Show Sidebar") {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NotificationCenter.default.post(name: .checkForUpdates, object: nil)
            }
        }
    }
}
```

Use `CommandGroup` to extend or replace the system menu at its semantic
location. Keep command intent separate from view layout; a root model, focused
value, or notification can connect the action to the current scene.

## Appearance preference

Source: `AnnotView/Sources/AnnotView/App/AppearanceSettings.swift`.

```swift
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

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

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "appearance") {
        self.defaults = defaults
        self.key = key
        appearance = AppAppearance(rawValue: defaults.string(forKey: key) ?? "") ?? .system
    }
}
```

Inject `UserDefaults` in tests. Keep preference keys stable and migrate them
deliberately when renaming or changing their meaning.
