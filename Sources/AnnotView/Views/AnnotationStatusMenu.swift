import AppKit
import SwiftUI

/// Shared native status menu with Lucide icons and standard leading state checkmarks.
final class AnnotationStatusMenuTarget: NSObject {
    var onSelect: ((Annotation.Status?) -> Void)?

    @objc func select(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        onSelect?(raw == "all" ? nil : Annotation.Status(rawValue: raw))
    }
}

struct MenuAnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}


@MainActor
enum AnnotationStatusMenu {
    static func make(
        selection: Annotation.Status?,
        includeAll: Bool,
        target: AnnotationStatusMenuTarget
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if includeAll {
            menu.addItem(item(
                title: "All Statuses",
                icon: nil,
                tint: .secondaryLabelColor,
                checked: selection == nil,
                represented: "all",
                target: target
            ))
            menu.addItem(.separator())
        }

        for status in Annotation.Status.selectableCases {
            let statusItem = item(
                title: status.displayName,
                icon: status.iconName,
                tint: status.nsTint,
                checked: selection == status,
                represented: status.rawValue,
                target: target
            )
            statusItem.toolTip = status.help
            menu.addItem(statusItem)
        }
        return menu
    }

    private static func item(
        title: String,
        icon: String?,
        tint: NSColor,
        checked: Bool,
        represented: String,
        target: AnnotationStatusMenuTarget
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(AnnotationStatusMenuTarget.select(_:)),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = represented
        item.state = checked ? .on : .off
        if let icon, let image = tintedIcon(icon, tint: tint) {
            item.image = image
        }
        return item
    }

    private static func tintedIcon(_ name: String, tint: NSColor) -> NSImage? {
        guard let base = Bundle.module.image(forResource: name) else { return nil }
        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        tint.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
