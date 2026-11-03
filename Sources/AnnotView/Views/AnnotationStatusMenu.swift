import AppKit
import SwiftUI

/// Shared native status menu: Lucide icon, title, and the check at the trailing
/// edge instead of the system's leading state check. No counts.
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
    private static let tabLocation: CGFloat = 126

    static func make(
        selection: Annotation.Status?,
        includeAll: Bool,
        target: AnnotationStatusMenuTarget
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if includeAll {
            menu.addItem(item(
                title: "All statuses",
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
        item.attributedTitle = attributedTitle(title, checked: checked)
        if let icon, let image = tintedIcon(icon, tint: tint) {
            item.image = image
        }
        return item
    }

    private static func attributedTitle(_ title: String, checked: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation)]

        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        guard checked else { return result }
        result.append(NSAttributedString(
            string: "\t✓",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
                .paragraphStyle: paragraph,
            ]
        ))
        return result
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
