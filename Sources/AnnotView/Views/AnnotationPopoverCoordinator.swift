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
    /// A preview that is currently fading out. A new popover may not be shown
    /// until this one has fully closed, otherwise the new show cancels the fade.
    private var fadingPopover: NSPopover?
    private var hoverDismissTask: Task<Void, Never>?
    private var popoverMouseDownMonitor: Any?
    private var positionedAnnotation: Annotation?
    private weak var positionedPage: PDFPage?

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
        // A fading-out popover may report its close after a replacement is
        // already on screen; only clear state that still belongs to it.
        if closedPopover === popover {
            popover = nil
            activePopover = nil
            hoverDismissTask?.cancel()
        }
        // A popover can only be shown once its predecessor has fully closed:
        // showing a second popover on the same positioning view while the first
        // is still closing silently fails (NSPopover race). Flush the queued
        // replacement now that the close is done.
        if closedPopover === fadingPopover {
            fadingPopover = nil
        }
        flushPendingShow()
    }

    private func flushPendingShow() {
        guard let pending = pendingShow else { return }
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
        let height = AnnotationPopoverView.preferredHeight(for: annotation.contents ?? "")
        let size = NSSize(width: AnnotationPopoverView.width, height: height)
        let configuration = makePreviewConfiguration(
            for: annotation,
            presentationID: presentationID
        )

        // Moving the mouse between two annotations should read as one bubble
        // melting into the next: keep the shown popover (NSPopover cannot show
        // two at once) and crossfade its content in place.
        if popover?.isShown == true,
           case .preview = activePopover?.kind,
           let popover,
           let controller = popover.contentViewController
               as? NSHostingController<AnnotationPreviewSwapView> {
            crossfadePreview(
                in: popover,
                controller: controller,
                configuration: configuration,
                state: state,
                annotation: annotation,
                page: page
            )
            return
        }

        install(
            makePopover(
                size: size,
                rootView: AnnotationPreviewSwapView(
                    model: AnnotationPreviewModel(configuration: configuration)
                )
            ),
            state: state,
            annotation: annotation,
            page: page
        )
    }

    private func makePreviewConfiguration(
        for annotation: Annotation,
        presentationID: UUID
    ) -> AnnotationPreviewConfiguration {
        AnnotationPreviewConfiguration(
            annotation: annotation,
            onSave: { [weak self] contents in
                guard let self, let update = self.hostView?.onUpdateAnnotation else { return false }
                return await update(annotation, contents, annotation.color)
            },
            onUpdateStatus: { [weak self] status in
                guard let self, let update = self.hostView?.onUpdateStatus else { return false }
                return await update(annotation, status)
            },
            onHeightChange: { [weak self] height in
                guard let self,
                      self.activePopover?.presentationID == presentationID,
                      let popover = self.popover,
                      popover.isShown else { return }
                let target = NSSize(width: AnnotationPopoverView.width, height: ceil(height))
                guard abs(popover.contentSize.height - target.height) > 0.5 else { return }
                popover.contentSize = target
            },
            onPin: { [weak self] in
                self?.pinCurrentPreview()
            },
            onStatusMenuTracking: { [weak self] isTracking in
                self?.setStatusMenuTracking(isTracking)
            }
        )
    }

    private func setStatusMenuTracking(_ isTracking: Bool) {
        popover?.behavior = isTracking ? .applicationDefined : .semitransient
    }

    /// Clicking inside a hover preview makes it a pinned (click) preview, so
    /// the pointer may leave the annotation while a menu or the card is used.
    private func pinCurrentPreview() {
        guard var active = activePopover,
              case .preview(pinned: false) = active.kind else { return }
        active.kind = .preview(pinned: true)
        activePopover = active
        hoverDismissTask?.cancel()
    }

    private func crossfadePreview(
        in popover: NSPopover,
        controller: NSHostingController<AnnotationPreviewSwapView>,
        configuration: AnnotationPreviewConfiguration,
        state: ActivePopover,
        annotation: Annotation,
        page: PDFPage
    ) {
        guard let hostView else { return }
        // Adopt the new presentation before swapping content so height reports
        // from the incoming card are accepted and the outgoing card's are not.
        activePopover = state
        positionedAnnotation = annotation
        positionedPage = page

        let height = AnnotationPopoverView.preferredHeight(for: annotation.contents ?? "")
        let target = NSSize(width: AnnotationPopoverView.width, height: height)
        if abs(popover.contentSize.height - target.height) > 0.5 {
            popover.contentSize = target
        }
        controller.rootView.model.configuration = configuration

        let anchor = hostView.convert(
            AnnotationOverlayRenderer.anchorBounds(for: annotation),
            from: page
        )
        popover.show(relativeTo: anchor, of: hostView, preferredEdge: .maxX)
        applyOpaqueCardStyle(to: popover)

        if case .preview(pinned: false) = state.kind {
            monitorHoverPreview(for: annotation.id)
        }
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
        guard hostView != nil else { return }
        if popover?.isShown == true {
            // A popover is shown; queue the replacement and let popoverDidClose
            // show it once the close completes.
            pendingShow = PendingShow(
                popover: newPopover,
                state: state,
                annotation: annotation,
                page: page
            )
            // Replacing a presentation should not wait on the outgoing fade.
            closeCurrentPopover(animated: false)
        } else if pendingShow != nil || fadingPopover != nil {
            // The previous preview is still fading: showing now would cancel
            // that fade and make the old card blink out. Queue instead; the
            // fade's close notification flushes the replacement.
            pendingShow = PendingShow(
                popover: newPopover,
                state: state,
                annotation: annotation,
                page: page
            )
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
        applyOpaqueCardStyle(to: newPopover)
        popover = newPopover
        activePopover = state
        positionedAnnotation = annotation
        positionedPage = page
        monitorClicksInsidePopover()
        if case .preview(pinned: false) = state.kind {
            monitorHoverPreview(for: state.annotationID)
        }
    }

    /// Pressing anywhere inside the card pins a hover preview. Without this a
    /// drag that leaves the card edge — selecting text, reaching a scroll
    /// position — counts as "mouse left the hover region" and the preview is
    /// dismissed mid-gesture.
    private func monitorClicksInsidePopover() {
        guard popoverMouseDownMonitor == nil else { return }
        popoverMouseDownMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            guard let self,
                  event.window === self.popover?.contentViewController?.view.window else {
                return event
            }
            self.pinCurrentPreview()
            return event
        }
    }

    /// Keep an open preview attached to its annotation as PDFKit scrolls.
    func reposition() {
        guard let popover, popover.isShown,
              let hostView,
              let annotation = positionedAnnotation,
              let page = positionedPage else { return }
        let anchor = hostView.convert(AnnotationOverlayRenderer.anchorBounds(for: annotation), from: page)
        popover.show(relativeTo: anchor, of: hostView, preferredEdge: .maxX)
    }

    /// The system popover draws a glass background on macOS 26. The card should
    /// read as an opaque sheet like the rest of the reader, so drop the glass
    /// and paint the popover frame (rounded rect + arrow) in the text
    /// background colour instead.
    private func applyOpaqueCardStyle(to popover: NSPopover) {
        guard let frameView = popover.contentViewController?.view.superview else { return }
        for view in frameView.subviews
        where String(describing: type(of: view)).contains("Glass") {
            view.isHidden = true
        }
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func dismiss() {
        // Dismissing from the outside cancels any deferred replacement.
        pendingShow = nil
        closeCurrentPopover()
    }

    private func closeCurrentPopover(animated: Bool = true) {
        hoverDismissTask?.cancel()
        hostView?.cancelPendingHoverPresentation()
        if let monitor = popoverMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            popoverMouseDownMonitor = nil
        }

        let closingPopover = popover
        var closingPreview = false
        if case .preview = activePopover?.kind { closingPreview = true }

        popover = nil
        activePopover = nil
        positionedAnnotation = nil
        positionedPage = nil

        guard let closingPopover else { return }
        guard animated,
              closingPreview,
              closingPopover.isShown,
              let window = closingPopover.contentViewController?.view.window else {
            closingPopover.close()
            return
        }

        // Fade the whole popover window (background, arrow and content) before
        // closing so a hover preview never blinks out between mouse positions.
        closingPopover.animates = false
        fadingPopover = closingPopover
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                closingPopover.close()
                guard let self else { return }
                if self.fadingPopover === closingPopover {
                    self.fadingPopover = nil
                }
                // The delegate notification normally flushes the queue. Give
                // AppKit a beat first: showing the next popover in the same
                // turn as the close can be dropped. The delayed flush also
                // keeps a queued preview from being stranded if no close
                // notification arrives.
                try? await Task.sleep(for: .milliseconds(30))
                self.flushPendingShow()
            }
        }
    }

    private func dismiss(presentationID: UUID) {
        guard activePopover?.presentationID == presentationID else { return }
        dismiss()
    }

    /// Polling cadence for the hover preview's leave detection. Two misses at
    /// 60 ms close the preview in ~120 ms: fast enough to feel immediate, long
    /// enough to survive the short hop from the annotation to the popover.
    private static let hoverDismissCheckInterval: Duration = .milliseconds(60)
    private static let hoverDismissCheckLimit = 2

    private func monitorHoverPreview(for annotationID: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = Task { @MainActor [weak self] in
            var consecutiveOutsideChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.hoverDismissCheckInterval)
                guard !Task.isCancelled,
                      let self,
                      self.activePopover?.annotationID == annotationID,
                      self.activePopover?.kind == .preview(pinned: false) else { return }

                let screenPoint = NSEvent.mouseLocation
                if self.mouseIsInsideHoverRegion(for: annotationID, at: screenPoint) {
                    consecutiveOutsideChecks = 0
                } else if self.hostView?.commentableAnnotationID(at: screenPoint) != nil {
                    // The pointer moved onto another comment: keep this preview
                    // alive until the hover pipeline crossfades to the new one.
                    // Dismissing here would race the 80 ms presentation delay and
                    // replace the crossfade with a close-then-show blink.
                    consecutiveOutsideChecks = 0
                } else {
                    consecutiveOutsideChecks += 1
                    if consecutiveOutsideChecks >= Self.hoverDismissCheckLimit {
                        self.dismiss()
                        return
                    }
                }
            }
        }
    }

    private func mouseIsInsideHoverRegion(for annotationID: UUID, at screenPoint: CGPoint) -> Bool {
        if let popoverWindow = popover?.contentViewController?.view.window,
           popoverWindow.frame.contains(screenPoint) {
            return true
        }
        return hostView?.mouseIsInsideAnnotation(annotationID, at: screenPoint) == true
    }
}
