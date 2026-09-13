# AppKit bridges for a native macOS shell

Bridge only the platform behavior that SwiftUI does not own reliably. Keep the
bridge small, lifecycle-aware, and independent of product models.

## Make a SwiftPM executable behave like an app

Source: `Gakuyu/Sources/GakuyuApp/App/GakuyuApp.swift` and the app delegate in
`AnnotView/Sources/AnnotView/App/AppDelegate.swift`.

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

This is important for `swift run`: a plain SwiftPM executable can otherwise be
treated as an accessory process with no normal Dock/menu/window activation.
Use document-open or launch-at-login handling only when the product requires
it, and keep that lifecycle logic in the delegate/application model.

## Hosting AppKit content in SwiftUI

Source: `AnnotView/Sources/AnnotView/Views/ReaderContentSplitView.swift`.

The generic shape is:

```swift
struct NativeContainer<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        NSHostingView(rootView: content())
    }

    func updateNSView(
        _ view: NSHostingView<Content>,
        context: Context
    ) {
        view.rootView = content()
    }
}
```

For custom split behavior, keep the `NSView` responsible for frames, divider
dragging, and collapse state while SwiftUI remains responsible for the hosted
content. Prefer `NavigationSplitView` or `HSplitView` when they satisfy the
requirements; a custom bridge is justified by a concrete native behavior.

## Window configuration rule

Window-level appearance, titlebar, activation, and accessory configuration
belongs in one `WindowConfigurator`/`AppDelegate`-style type. Avoid reaching
into `NSApp.windows` from many feature views; doing so makes launch order and
tests nondeterministic.
