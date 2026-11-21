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

    @Test
    func dismissingPopoverWithModifiedDraftAutoSaves() async throws {
        var savedValues: [String] = []
        let coordinator = AnnotationPopoverCoordinator(hostView: AnnotationPDFView(frame: .zero))
        let result = try await runCoordinatorPopover(
            initialContents: "",
            coordinator: coordinator,
            onSave: { value in
                savedValues.append(value)
                return true
            },
            action: { textView, popover, _ in
                textView.string = "  Auto saved note  "
                textView.didChangeText()
                popover.close()
            }
        )
        #expect(result == nil)
        #expect(savedValues == ["Auto saved note"])
    }

    @Test
    func cancelingModifiedDraftDoesNotAutoSave() async throws {
        var savedValues: [String] = []
        let coordinator = AnnotationPopoverCoordinator(hostView: AnnotationPDFView(frame: .zero))
        let pendingAfterCancel = try await runCoordinatorPopover(
            initialContents: "Initial",
            coordinator: coordinator,
            onSave: { value in
                savedValues.append(value)
                return true
            },
            action: { textView, popover, model in
                textView.string = "Unsaved edit"
                textView.didChangeText()
                textView.cancelOperation(nil)
                #expect(model.pendingEdit == nil)
                popover.close()
            }
        )
        #expect(pendingAfterCancel == nil)
        #expect(savedValues.isEmpty)
    }

    @Test
    func dismissingUnmodifiedEditorDoesNotAutoSave() async throws {
        var savedValues: [String] = []
        let coordinator = AnnotationPopoverCoordinator(hostView: AnnotationPDFView(frame: .zero))
        let pending = try await runCoordinatorPopover(
            initialContents: "",
            coordinator: coordinator,
            onSave: { value in
                savedValues.append(value)
                return true
            },
            action: { _, popover, model in
                #expect(model.pendingEdit == nil)
                popover.close()
            }
        )
        #expect(pending == nil)
        #expect(savedValues.isEmpty)
    }

    private func runCoordinatorPopover(
        initialContents: String,
        coordinator: AnnotationPopoverCoordinator,
        onSave: @escaping @MainActor (String) async -> Bool,
        action: @MainActor (NSTextView, NSPopover, AnnotationPreviewModel) -> Void
    ) async throws -> String? {
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
        popover.delegate = coordinator
        popover.contentSize = NSSize(
            width: AnnotationPopoverView.width,
            height: AnnotationPopoverView.preferredHeight(for: initialContents)
        )

        let config = AnnotationPreviewConfiguration(
            annotation: annotation,
            startEditing: true,
            onSave: onSave,
            onUpdateStatus: { _ in true },
            onHeightChange: { _ in },
            onPin: {},
            onStatusMenuTracking: { _ in },
            onDismiss: { popover.close() }
        )
        let model = AnnotationPreviewModel(configuration: config)
        let controller = NSHostingController(
            rootView: AnnotationPreviewSwapView(model: model)
        )
        popover.contentViewController = controller
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
        defer { popover.close() }

        try await Task.sleep(for: .milliseconds(100))
        let textView = try #require(firstTextView(in: controller.view))
        action(textView, popover, model)
        try await Task.sleep(for: .milliseconds(120))
        return model.pendingEdit?.contents
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
