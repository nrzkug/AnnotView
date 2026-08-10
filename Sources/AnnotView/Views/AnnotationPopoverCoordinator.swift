import AppKit
import PDFKit
import SwiftUI

@MainActor
final class AnnotationPopoverCoordinator: NSObject, NSPopoverDelegate {
    private struct ActivePopover: Equatable {
        enum Kind: Equatable {
            case preview(pinned: Bool)
            case editor
        }

        let annotationID: UUID
        let presentationID: UUID
        var kind: Kind

        var policyContext: AnnotationPresentationContext {
            switch kind {
            case .preview(pinned: false): .transientPreview
            case .preview(pinned: true): .pinnedPreview
            case .editor: .editor
            }
        }
    }

    private weak var hostView: AnnotationPDFView?
    private var popover: NSPopover?
    private var activePopover: ActivePopover?
    private var hoverDismissTask: Task<Void, Never>?

    init(hostView: AnnotationPDFView) {
        self.hostView = hostView
    }

    var policyContext: AnnotationPresentationContext {
        activePopover?.policyContext ?? .none
    }

    func handle(
        _ annotation: Annotation,
        on page: PDFPage,
        request: AnnotationPresentationRequest
    ) {
        switch AnnotationPresentationPolicy.action(
            for: annotation,
            request: request,
            context: policyContext
        ) {
        case .ignore:
            return
        case .dismiss:
            dismiss()
        case let .preview(pinned):
            showPreview(annotation, on: page, pinned: pinned)
        case .editor:
            showEditor(annotation, on: page)
        }
    }

    func dismiss(for annotationID: UUID) {
        guard activePopover?.annotationID == annotationID else { return }
        dismiss()
    }

    func reconcile(availableAnnotationIDs: Set<UUID>) {
        guard let annotationID = activePopover?.annotationID,
              !availableAnnotationIDs.contains(annotationID) else { return }
        dismiss()
    }

    func reset() {
        dismiss()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === popover else { return }
        popover = nil
        activePopover = nil
        hoverDismissTask?.cancel()
    }

    private func showPreview(_ annotation: Annotation, on page: PDFPage, pinned: Bool) {
        if var activePopover,
           case let .preview(wasPinned) = activePopover.kind,
           activePopover.annotationID == annotation.id,
           popover?.isShown == true {
            let remainsPinned = wasPinned || pinned
            activePopover.kind = .preview(pinned: remainsPinned)
            self.activePopover = activePopover
            if remainsPinned { hoverDismissTask?.cancel() }
            return
        }

        let presentationID = UUID()
        let height = Self.previewHeight(for: annotation)
        let popover = makePopover(
            size: NSSize(width: 330, height: height),
            rootView: AnnotationPopoverView(
                annotation: annotation,
                height: height,
                onEdit: { [weak self, weak page] in
                    guard let self, let page,
                          self.activePopover?.presentationID == presentationID else { return }
                    self.handle(annotation, on: page, request: .explicitEdit)
                }
            )
        )
        install(
            popover,
            state: ActivePopover(
                annotationID: annotation.id,
                presentationID: presentationID,
                kind: .preview(pinned: pinned)
            ),
            annotation: annotation,
            page: page
        )
        if !pinned { monitorHoverPreview(for: annotation.id) }
    }

    private func showEditor(_ annotation: Annotation, on page: PDFPage) {
        if activePopover?.annotationID == annotation.id,
           activePopover?.kind == .editor,
           popover?.isShown == true {
            return
        }

        let presentationID = UUID()
        let popover = makePopover(
            size: NSSize(width: 360, height: 286),
            rootView: AnnotationEditorView(
                annotation: annotation,
                onSave: { [weak self] contents, color in
                    guard let self, let update = self.hostView?.onUpdateAnnotation else { return false }
                    let saved = await update(annotation, contents, color)
                    if saved { self.dismiss(presentationID: presentationID) }
                    return saved
                },
                onDelete: { [weak self] in
                    guard let self, let delete = self.hostView?.onDeleteAnnotation else { return false }
                    let deleted = await delete(annotation)
                    if deleted { self.dismiss(presentationID: presentationID) }
                    return deleted
                },
                onCancel: { [weak self] in
                    self?.dismiss(presentationID: presentationID)
                }
            )
        )
        install(
            popover,
            state: ActivePopover(
                annotationID: annotation.id,
                presentationID: presentationID,
                kind: .editor
            ),
            annotation: annotation,
            page: page
        )
    }

    private func makePopover<Content: View>(size: NSSize, rootView: Content) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = size
        popover.contentViewController = NSHostingController(rootView: rootView)
        return popover
    }

    private func install(
        _ newPopover: NSPopover,
        state: ActivePopover,
        annotation: Annotation,
        page: PDFPage
    ) {
        guard let hostView else { return }
        hoverDismissTask?.cancel()
        hostView.cancelPendingHoverPresentation()
        dismiss()
        let anchor = hostView.convert(AnnotationOverlayRenderer.anchorBounds(for: annotation), from: page)
        newPopover.show(relativeTo: anchor, of: hostView, preferredEdge: .maxX)
        popover = newPopover
        activePopover = state
    }

    func dismiss() {
        hoverDismissTask?.cancel()
        hostView?.cancelPendingHoverPresentation()
        let closingPopover = popover
        popover = nil
        activePopover = nil
        closingPopover?.close()
    }

    private func dismiss(presentationID: UUID) {
        guard activePopover?.presentationID == presentationID else { return }
        dismiss()
    }

    private func monitorHoverPreview(for annotationID: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = Task { @MainActor [weak self] in
            var consecutiveOutsideChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled,
                      let self,
                      self.activePopover?.annotationID == annotationID,
                      self.activePopover?.kind == .preview(pinned: false) else { return }

                if self.mouseIsInsideHoverRegion(for: annotationID) {
                    consecutiveOutsideChecks = 0
                } else {
                    consecutiveOutsideChecks += 1
                    if consecutiveOutsideChecks >= 5 {
                        self.dismiss()
                        return
                    }
                }
            }
        }
    }

    private func mouseIsInsideHoverRegion(for annotationID: UUID) -> Bool {
        let screenPoint = NSEvent.mouseLocation
        if let popoverWindow = popover?.contentViewController?.view.window,
           popoverWindow.frame.contains(screenPoint) {
            return true
        }
        return hostView?.mouseIsInsideAnnotation(annotationID, at: screenPoint) == true
    }

    private static func previewHeight(for annotation: Annotation) -> CGFloat {
        let text = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitLines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let wrappedLines = max(explicitLines, Int(ceil(Double(text.count) / 38.0)))
        return min(304, max(176, 152 + CGFloat(wrappedLines) * 19))
    }
}
