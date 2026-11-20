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

    @Test
    func cancelingEditWithEmptyCommentDismissesPopover() async throws {
        let dismissed = try await runEditorAction(initialContents: "") { textView in
            textView.cancelOperation(nil)
        }
        #expect(dismissed)
    }

    @Test
    func cancelingEditWithExistingCommentKeepsPopoverOpen() async throws {
        let dismissed = try await runEditorAction(initialContents: "Existing comment") { textView in
            textView.cancelOperation(nil)
        }
        #expect(!dismissed)
    }

    @Test
    func savingEmptyCommentDismissesPopover() async throws {
        let dismissed = try await runEditorAction(initialContents: "Existing comment") { textView in
            textView.string = ""
            textView.didChangeText()
            if let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: textView.window?.windowNumber ?? 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            ) {
                textView.keyDown(with: event)
            }
        }
        #expect(dismissed)
    }

    private func runEditorAction(
        initialContents: String,
        action: @MainActor (NSTextView) -> Void
    ) async throws -> Bool {
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 100, y: 100, width: 120, height: 16),
            contents: initialContents,
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
            height: AnnotationPopoverView.preferredHeight(for: initialContents)
        )

        var didDismiss = false
        let config = AnnotationPreviewConfiguration(
            annotation: annotation,
            startEditing: true,
            onSave: { _ in true },
            onUpdateStatus: { _ in true },
            onHeightChange: { _ in },
            onPin: {},
            onStatusMenuTracking: { _ in },
            onDismiss: {
                didDismiss = true
                popover.close()
            }
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
        let textView = try #require(firstTextView(in: controller.view))
        action(textView)
        try await Task.sleep(for: .milliseconds(100))
        return didDismiss
    }

    private func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView {
            return textView
        }
        for subview in view.subviews {
            if let match = firstTextView(in: subview) {
                return match
            }
        }
        return nil
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
            onStatusMenuTracking: { _ in },
            onDismiss: {}
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
