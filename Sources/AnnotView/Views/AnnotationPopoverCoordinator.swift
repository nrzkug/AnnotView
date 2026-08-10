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
    private var pendingShow: PendingShow?
    private var isClosing = false
    private var hoverDismissTask: Task<Void, Never>?

    private struct PendingShow {
        let popover: NSPopover
        let state: ActivePopover
        let annotation: Annotation
        let page: PDFPage
    }

    init(hostView: AnnotationPDFView) {
        self.hostView = hostView
    }

    var policyContext: AnnotationPresentationContext {
        activePopover?.policyContext ?? .none
    }

    /// The annotation the current presentation (if any) belongs to.
    var presentedAnnotationID: UUID? {
        activePopover?.annotationID
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
        guard let closedPopover = notification.object as? NSPopover else { return }
        isClosing = false
        if closedPopover === popover { popover = nil }
        activePopover = nil
        hoverDismissTask?.cancel()
        // A popover can only be shown once its predecessor has fully closed:
        // showing a second popover on the same positioning view while the first
        // is still closing silently fails (NSPopover race). Flush the queued
        // replacement now that the close is done.
        if let pending = pendingShow {
            pendingShow = nil
            if case .preview(pinned: false) = pending.state.kind,
               hostView?.mouseIsInsideAnnotation(
                   pending.state.annotationID,
                   at: NSEvent.mouseLocation
               ) != true {
                // The mouse left the target while the old popover was closing;
                // don't show a ghost preview. The hover pipeline re-triggers if
                // the user comes back.
                return
            }
            showPopover(pending.popover, state: pending.state, annotation: pending.annotation, page: pending.page)
        }
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
        let state = ActivePopover(
            annotationID: annotation.id,
            presentationID: presentationID,
            kind: .preview(pinned: pinned)
        )
        let height = Self.previewHeight(for: annotation)
        let size = NSSize(width: 330, height: height)
        let rootView = AnnotationPopoverView(
            annotation: annotation,
            height: height,
            onEdit: { [weak self, weak page] in
                guard let self, let page,
                      self.activePopover?.presentationID == presentationID else { return }
                self.handle(annotation, on: page, request: .explicitEdit)
            }
        )
        install(
            makePopover(size: size, rootView: rootView),
            state: state,
            annotation: annotation,
            page: page
        )
    }

    private func showEditor(_ annotation: Annotation, on page: PDFPage) {
        if activePopover?.annotationID == annotation.id,
           activePopover?.kind == .editor,
           popover?.isShown == true {
            return
        }

        let presentationID = UUID()
        let state = ActivePopover(
            annotationID: annotation.id,
            presentationID: presentationID,
            kind: .editor
        )
        let size = NSSize(width: 360, height: 286)
        let rootView = AnnotationEditorView(
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
        install(
            makePopover(size: size, rootView: rootView),
            state: state,
            annotation: annotation,
            page: page
        )
    }

    private func makePopover<Content: View>(size: NSSize, rootView: Content) -> NSPopover {
        let popover = NSPopover()
        // semitransient: clicking inside the PDF window does not auto-close the
        // popover, so a hover preview can be upgraded to the pinned preview in
        // place instead of racing a closing popover (which broke click-to-select
        // and note dragging while a preview was showing).
        popover.behavior = .semitransient
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
        if popover?.isShown == true || pendingShow != nil {
            // A popover is shown or already closing; queue the replacement and
            // let popoverDidClose show it once the close animation completes.
            pendingShow = PendingShow(
                popover: newPopover,
                state: state,
                annotation: annotation,
                page: page
            )
            closeCurrentPopover()
        } else {
            showPopover(newPopover, state: state, annotation: annotation, page: page)
        }
    }

    private func showPopover(
        _ newPopover: NSPopover,
        state: ActivePopover,
        annotation: Annotation,
        page: PDFPage
    ) {
        guard let hostView else { return }
        let anchor = hostView.convert(AnnotationOverlayRenderer.anchorBounds(for: annotation), from: page)
        newPopover.show(relativeTo: anchor, of: hostView, preferredEdge: .maxX)
        popover = newPopover
        activePopover = state
        if case .preview(pinned: false) = state.kind {
            monitorHoverPreview(for: state.annotationID)
        }
    }

    func dismiss() {
        // Dismissing from the outside cancels any deferred replacement.
        pendingShow = nil
        closeCurrentPopover()
    }

    private func closeCurrentPopover() {
        hoverDismissTask?.cancel()
        hostView?.cancelPendingHoverPresentation()
        let closingPopover = popover
        popover = nil
        activePopover = nil
        if closingPopover != nil { isClosing = true }
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
