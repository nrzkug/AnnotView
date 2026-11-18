import AppKit
import SwiftUI
import Testing
@testable import AnnotView

@MainActor
struct AnnotationPopoverTests {
    @Test
    func longCommentsOpenDirectlyAtFullHeightWithoutCollapse() async throws {
        let shortText = "Single-line review note."
        let longText = (1...12)
            .map { "Line \($0): This is a detailed review comment shown in full without folding." }
            .joined(separator: "\n")

        let shortHeight = try await mountedPopoverHeight(for: shortText)
        let longHeight = try await mountedPopoverHeight(for: longText)

        #expect(longHeight > shortHeight + 250)
    }

    private func mountedPopoverHeight(for contents: String) async throws -> CGFloat {
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 100, y: 100, width: 120, height: 16),
            contents: contents,
            author: "Reviewer"
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let anchorView = NSView(frame: NSRect(x: 50, y: 350, width: 20, height: 20))
        window.contentView?.addSubview(anchorView)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        popover.contentSize = NSSize(
            width: AnnotationPopoverView.width,
            height: AnnotationPopoverView.preferredHeight(for: contents)
        )

        let config = AnnotationPreviewConfiguration(
            annotation: annotation,
            startEditing: false,
            onSave: { _ in true },
            onUpdateStatus: { _ in true },
            onHeightChange: { height in
                let target = NSSize(width: AnnotationPopoverView.width, height: ceil(height))
                if abs(popover.contentSize.height - target.height) > 0.5 {
                    popover.contentSize = target
                }
            },
            onPin: {},
            onStatusMenuTracking: { _ in }
        )

        let controller = NSHostingController(
            rootView: AnnotationPreviewSwapView(
                model: AnnotationPreviewModel(configuration: config)
            )
        )
        popover.contentViewController = controller
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        defer { popover.close() }

        try await Task.sleep(for: .milliseconds(100))
        return popover.contentSize.height
    }
}
