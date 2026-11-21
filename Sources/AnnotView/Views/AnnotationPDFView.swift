import AppKit
import PDFKit

/// PDFKit draws only page content; this subclass paints engine-neutral annotations on top.
final class AnnotationPDFView: PDFView, @preconcurrency PDFPageOverlayViewProvider {
    /// Inset the scrollable document, never the PDF viewport: page content and
    /// the overlay scroller can extend behind the floating window controls.
    var topContentInset: CGFloat = 0 {
        didSet {
            if oldValue != topContentInset { applyReaderContentInsets() }
        }
    }

    override func layout() {
        super.layout()
        applyReaderContentInsets()
    }

    func applyReaderContentInsets() {
        guard let scrollView = documentView?.enclosingScrollView else { return }
        scrollView.automaticallyAdjustsContentInsets = false
        if scrollView.contentInsets.top != topContentInset {
            var insets = scrollView.contentInsets
            insets.top = topContentInset
            scrollView.contentInsets = insets
        }
        scrollView.scrollerStyle = .overlay
        // Keep the overlay track full-height while only the document content
        // is inset beneath the floating toolbar.
        scrollView.scrollerInsets = NSEdgeInsets(top: -topContentInset, left: 0, bottom: 0, right: 0)
    }

    func isWindowDragPoint(_ point: NSPoint) -> Bool {
        guard topContentInset > 0, bounds.contains(point) else { return false }
        let distanceFromTop = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        guard distanceFromTop < topContentInset else { return false }
        // The full-height overlay scroller remains interactive in this band.
        if let scroller = documentView?.enclosingScrollView?.verticalScroller,
           !scroller.isHidden,
           convert(scroller.bounds, from: scroller).contains(point) { return false }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if isWindowDragPoint(localPoint) { return self }
        return super.hitTest(point)
    }

    var annotationTool: AnnotationTool = .selection {
        didSet {
            guard oldValue != annotationTool else { return }
            window?.invalidateCursorRects(for: self)
            if let kind = annotationTool.markupKind {
                createMarkupFromActiveSelection(kind: kind)
            }
        }
    }
    var onCreateMarkupRequest: (@MainActor (Annotation.Kind, PDFMarkupSelection) -> Void)?
    var onCreateNoteRequest: (@MainActor (PDFPagePoint) -> Void)?
    var onCreateInsertTextRequest: (@MainActor (PDFPagePoint) -> Void)?
    var onUpdateAnnotation: (@MainActor (Annotation, String) async -> Bool)?
    var onUpdateStatus: (@MainActor (Annotation, Annotation.Status) async -> Bool)?
    var onMoveAnnotationRequest: (@MainActor (Annotation, CGRect) -> Void)?
    var onDeleteAnnotation: (@MainActor (Annotation) async -> Bool)?
    var onSelectAnnotationRequest: (@MainActor (UUID) -> Void)?
    var onDeselectAnnotationRequest: (@MainActor () -> Void)?
    var lastAnnotationNavigationID = 0
    var lastSearchNavigationID = 0
    var lastSearchResultsRevision = 0
    var lastZoomRequestID = 0
    private var suppressesMarkupOnMouseUp = false
    private var contextMenuAnnotation: Annotation?
    private var contextMenuPagePoint: PDFPagePoint?
    private var mouseTrackingArea: NSTrackingArea?
    private weak var observedClipView: NSClipView?
    private var scrollObserver: NSObjectProtocol?
    private var dragState: (annotation: Annotation, page: PDFPage, startViewPoint: CGPoint, startBounds: CGRect, didMove: Bool)?
    private var pendingMarkupClick: (annotation: Annotation, page: PDFPage, startViewPoint: CGPoint)?
    private var didReceiveMouseUpForMarkupClick = false
    /// Click/drag discrimination in view-space points. Measuring in page
    /// coordinates would shrink the threshold as the document zooms out and
    /// swallow ordinary clicks as annotation moves.
    private static let annotationDragThreshold: CGFloat = 4
    private let pageOverlayViews = NSHashTable<AnnotationPageOverlayView>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disableDocumentAnalysis()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        disableDocumentAnalysis()
    }

    override var document: PDFDocument? {
        didSet {
            disableDocumentAnalysis()
        }
    }

    func disableDocumentAnalysis() {
        if responds(to: Selector(("setDocumentAnalysisEnabled:"))) {
            setValue(false, forKey: "documentAnalysisEnabled")
        }
        if responds(to: Selector(("setFormDetectionEnabled:"))) {
            setValue(false, forKey: "formDetectionEnabled")
        }
        if responds(to: Selector(("setEnableDataDetectors:"))) {
            setValue(false, forKey: "enableDataDetectors")
        }
    }

    var selectedAnnotationID: UUID? {
        didSet {
            guard oldValue != selectedAnnotationID else { return }
            for overlay in pageOverlayViews.allObjects {
                overlay.selectedAnnotationID = selectedAnnotationID
            }
        }
    }
    private lazy var popoverCoordinator = AnnotationPopoverCoordinator(hostView: self)
    private lazy var interactionController = AnnotationInteractionController(
        onHoveredAnnotationChanged: { [weak self] annotationID in
            guard let self else { return }
            for overlay in self.pageOverlayViews.allObjects {
                overlay.hoveredAnnotationID = annotationID
            }
        },
        onTransientAnnotationChanged: { [weak self] annotationID in
            guard let self else { return }
            for overlay in self.pageOverlayViews.allObjects {
                overlay.transientAnnotationID = annotationID
            }
        }
    )

    var overlayAnnotations: [Int: [Annotation]] = [:] {
        didSet {
            guard oldValue != overlayAnnotations else { return }
            for overlay in pageOverlayViews.allObjects {
                let next = overlayAnnotations[overlay.pageIndex] ?? []
                if overlay.annotations != next {
                    overlay.annotations = next
                }
            }
            reconcileAnnotationInteraction()
        }
    }

    func resetAnnotationInteraction() {
        dragState = nil
        pendingMarkupClick = nil
        interactionController.reset()
        popoverCoordinator.reset()
    }

    func stopObservingDocumentScrolling() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        observedClipView = nil
    }

    func observeDocumentScrolling() {
        guard let clipView = documentView?.enclosingScrollView?.contentView,
              observedClipView !== clipView else { return }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        observedClipView = clipView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            // PDFKit updates the clip view before this notification.  Re-showing
            // an already-visible popover updates its anchor without recreating
            // the preview or losing its pinned/editor state.
            Task { @MainActor [weak self] in
                self?.popoverCoordinator.reposition()
            }
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document, let pageIndex = document.validPageIndex(for: page) else { return nil }
        let overlay = AnnotationPageOverlayView(
            pdfView: self,
            page: page,
            pageIndex: pageIndex,
            annotations: overlayAnnotations[pageIndex] ?? [],
            hoveredAnnotationID: interactionController.hoveredAnnotationID,
            transientAnnotationID: interactionController.transientAnnotationID,
            selectedAnnotationID: selectedAnnotationID
        )
        pageOverlayViews.add(overlay)
        return overlay
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTrackingArea { removeTrackingArea(mouseTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(viewPoint) else { return }
        cursor(at: viewPoint).set()
    }

    func cursor(at viewPoint: CGPoint) -> NSCursor {
        let page = page(for: viewPoint, nearest: false)
        let pagePoint = page.map { convert(viewPoint, to: $0) }
        return cursor(
            at: viewPoint,
            page: page,
            pagePoint: pagePoint,
            precomputedTarget: nil,
            hasPrecomputedTarget: false
        )
    }

    private func cursor(
        at viewPoint: CGPoint,
        page: PDFPage?,
        pagePoint: CGPoint?,
        precomputedTarget: (annotation: Annotation, page: PDFPage)?,
        hasPrecomputedTarget: Bool
    ) -> NSCursor {
        if isWindowDragPoint(viewPoint) { return .arrow }
        // Text remains a text target even when it carries a highlight, link,
        // or other annotation. Do not let annotation hit testing win here.
        if let page, let pagePoint, isOverText(on: page, at: pagePoint) { return .iBeam }
        let target = hasPrecomputedTarget
            ? precomputedTarget
            : page.flatMap { p in pagePoint.flatMap { annotationTarget(on: p, at: $0) } }
        if target != nil { return .pointingHand }
        if annotationTool == .note { return .crosshair }
        return .arrow
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard visibleRect.contains(viewPoint) else { return }
        let page = page(for: viewPoint, nearest: false)
        let pagePoint = page.map { convert(viewPoint, to: $0) }
        let target = page.flatMap { p in pagePoint.flatMap { annotationTarget(on: p, at: $0) } }
        interactionController.updateHover(
            annotation: target?.annotation,
            page: target?.page,
            presentationContext: popoverCoordinator.policyContext,
            presentedAnnotationID: popoverCoordinator.presentedAnnotationID,
            present: { [weak self] annotation, page in
                self?.handleAnnotationPresentation(annotation, on: page, request: .hover)
            }
        )
        // PDFKit has tracking areas of its own. Reapply our policy on every
        // move, including moves between glyphs within the same tracking area.
        cursor(
            at: viewPoint,
            page: page,
            pagePoint: pagePoint,
            precomputedTarget: target,
            hasPrecomputedTarget: true
        ).set()
    }

    override func mouseExited(with event: NSEvent) {
        interactionController.clearHover()
        // The destination view owns the cursor now. Setting an arrow here can
        // overwrite the split divider's resize cursor after AppKit sets it.
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        suppressesMarkupOnMouseUp = false
        if isWindowDragPoint(viewPoint), let window {
            suppressesMarkupOnMouseUp = true
            interactionController.clearHover()
            window.performDrag(with: event)
            return
        }
        if let target = annotationTarget(at: viewPoint) {
            interactionController.cancelPendingHoverPresentation()
            if target.annotation.kind == .highlight
                || target.annotation.kind == .underline
                || target.annotation.kind == .strikeout {
                // Text markup sits directly over selectable text: let PDFKit
                // track drag-selection, and upgrade a plain click to pin/edit.
                pendingMarkupClick = (
                    annotation: target.annotation,
                    page: target.page,
                    startViewPoint: viewPoint
                )
                didReceiveMouseUpForMarkupClick = false
                clearSelection()
                super.mouseDown(with: event)
                if let pending = pendingMarkupClick,
                   !didReceiveMouseUpForMarkupClick,
                   NSApp.currentEvent?.type == .leftMouseUp {
                    pendingMarkupClick = nil
                    finalizeMarkupClickOrSelection(pending)
                }
                return
            }
            suppressesMarkupOnMouseUp = true
            onSelectAnnotationRequest?(target.annotation.id)
            if target.annotation.kind == .note {
                // Notes stay movable: pin the preview on press, and only if
                // the gesture crosses the drag threshold does mouseDragged
                // dismiss it and move the note instead.
                dragState = (
                    annotation: target.annotation,
                    page: target.page,
                    startViewPoint: viewPoint,
                    startBounds: target.annotation.bounds,
                    didMove: false
                )
            }
            // Carets and notes pin the preview on press. The hover preview is
            // semitransient, so it is still open here and gets upgraded in place
            // rather than racing a closing popover.
            handleAnnotationPresentation(target.annotation, on: target.page, request: .documentClick)
            return
        }
        if annotationTool == .note || annotationTool == .insertText,
           let page = page(for: viewPoint, nearest: false),
           let document,
           let pageIndex = document.validPageIndex(for: page) {
            suppressesMarkupOnMouseUp = true
            popoverCoordinator.dismiss()
            onDeselectAnnotationRequest?()
            let rawPoint = convert(viewPoint, to: page)
            if annotationTool == .note {
                onCreateNoteRequest?(PDFPagePoint(pageIndex: pageIndex, point: rawPoint))
            } else if let point = insertionPoint(for: rawPoint, on: page) {
                onCreateInsertTextRequest?(PDFPagePoint(pageIndex: pageIndex, point: point))
            }
            return
        }
        popoverCoordinator.dismiss()
        onDeselectAnnotationRequest?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let pending = pendingMarkupClick {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if hypot(
                viewPoint.x - pending.startViewPoint.x,
                viewPoint.y - pending.startViewPoint.y
            ) >= Self.annotationDragThreshold {
                popoverCoordinator.dismiss()
            }
            super.mouseDragged(with: event)
            return
        }
        guard var drag = dragState else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if !drag.didMove {
            guard hypot(
                viewPoint.x - drag.startViewPoint.x,
                viewPoint.y - drag.startViewPoint.y
            ) >= Self.annotationDragThreshold else { return }
            drag.didMove = true
            dragState = drag
            // Dragging has begun: drop the pinned preview and move the annotation.
            popoverCoordinator.dismiss()
        }
        updateDrag(to: viewPoint)
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pendingMarkupClick {
            didReceiveMouseUpForMarkupClick = true
            pendingMarkupClick = nil
            super.mouseUp(with: event)
            finalizeMarkupClickOrSelection(pending)
            return
        }
        if let drag = dragState {
            dragState = nil
            // The preview was already pinned on mouseDown; mouseUp only
            // commits a real drag as a move.
            if drag.didMove, let onMoveAnnotationRequest {
                onMoveAnnotationRequest(drag.annotation, drag.annotation.bounds)
            }
            return
        }
        super.mouseUp(with: event)
        guard !suppressesMarkupOnMouseUp,
              let kind = annotationTool.markupKind else { return }
        createMarkupFromActiveSelection(kind: kind)
    }

    private func finalizeMarkupClickOrSelection(
        _ pending: (annotation: Annotation, page: PDFPage, startViewPoint: CGPoint)
    ) {
        if let selected = currentSelection?.string, !selected.isEmpty {
            popoverCoordinator.dismiss()
            onDeselectAnnotationRequest?()
            if let kind = annotationTool.markupKind {
                createMarkupFromActiveSelection(kind: kind)
            }
        } else {
            onSelectAnnotationRequest?(pending.annotation.id)
            handleAnnotationPresentation(pending.annotation, on: pending.page, request: .documentClick)
        }
    }

    private func updateDrag(to viewPoint: CGPoint) {
        guard let drag = dragState else { return }
        let pagePoint = convert(viewPoint, to: drag.page)
        let startPagePoint = convert(drag.startViewPoint, to: drag.page)
        let offset = CGPoint(
            x: pagePoint.x - startPagePoint.x,
            y: pagePoint.y - startPagePoint.y
        )
        var updated = drag.annotation
        updated.bounds = drag.startBounds.offsetBy(dx: offset.x, dy: offset.y)
        var pageAnnotations = overlayAnnotations[updated.pageIndex] ?? []
        if let index = pageAnnotations.firstIndex(where: { $0.id == updated.id }) {
            pageAnnotations[index] = updated
            overlayAnnotations[updated.pageIndex] = pageAnnotations
        }
        dragState = (annotation: updated, page: drag.page, startViewPoint: drag.startViewPoint, startBounds: drag.startBounds, didMove: drag.didMove)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let viewPoint = convert(event.locationInWindow, from: nil)
        contextMenuAnnotation = annotationTarget(at: viewPoint)?.annotation
        if contextMenuAnnotation != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addMenuItem("Edit Annotation…", action: #selector(editAnnotationFromMenu(_:)), to: menu)
            addMenuItem("Delete Annotation", action: #selector(deleteAnnotationFromMenu(_:)), to: menu)
            return menu
        }
        contextMenuPagePoint = pagePoint(at: viewPoint)
        if markupSelection() != nil {
            // Text is selected: offer markup over the selection.
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addMenuItem("Add Highlight", action: #selector(addHighlightFromMenu(_:)), to: menu)
            addMenuItem("Add Underline", action: #selector(addUnderlineFromMenu(_:)), to: menu)
            addMenuItem("Add Strikethrough", action: #selector(addStrikeoutFromMenu(_:)), to: menu)
        } else if let contextMenuPagePoint {
            // No selection: offer point-based annotations at the click location.
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addMenuItem("Add Sticky Note", action: #selector(addNoteFromMenu(_:)), to: menu)
            if let page = document?.page(at: contextMenuPagePoint.pageIndex),
               insertionPoint(for: contextMenuPagePoint.point, on: page) != nil {
                addMenuItem("Add Insert Text", action: #selector(addInsertTextFromMenu(_:)), to: menu)
            }
        }
        return menu
    }

    private func pagePoint(at viewPoint: CGPoint) -> PDFPagePoint? {
        guard let page = page(for: viewPoint, nearest: false),
              let document,
              let pageIndex = document.validPageIndex(for: page) else { return nil }
        return PDFPagePoint(
            pageIndex: pageIndex,
            point: convert(viewPoint, to: page)
        )
    }

    @objc private func addNoteFromMenu(_ sender: Any?) {
        guard let location = contextMenuPagePoint else { return }
        onCreateNoteRequest?(location)
    }

    @objc private func addInsertTextFromMenu(_ sender: Any?) {
        guard let location = contextMenuPagePoint,
              let page = document?.page(at: location.pageIndex),
              let point = insertionPoint(for: location.point, on: page) else { return }
        onCreateInsertTextRequest?(
            PDFPagePoint(
                pageIndex: location.pageIndex,
                point: point
            )
        )
    }

    func markupSelection() -> PDFMarkupSelection? {
        guard let document, let selection = currentSelection else { return nil }
        var quadsByPage: [Int: [PDFMarkupQuad]] = [:]

        let lines = selection.selectionsByLine()
        for line in lines {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.01, bounds.height > 0.01,
                      let pageIndex = document.validPageIndex(for: page) else { continue }
                quadsByPage[pageIndex, default: []].append(
                    PDFMarkupQuad(
                        topLeft: CGPoint(x: bounds.minX, y: bounds.maxY),
                        topRight: CGPoint(x: bounds.maxX, y: bounds.maxY),
                        bottomLeft: CGPoint(x: bounds.minX, y: bounds.minY),
                        bottomRight: CGPoint(x: bounds.maxX, y: bounds.minY)
                    )
                )
            }
        }

        if quadsByPage.isEmpty {
            for page in selection.pages {
                let bounds = selection.bounds(for: page)
                guard bounds.width > 0.01, bounds.height > 0.01,
                      let pageIndex = document.validPageIndex(for: page) else { continue }
                quadsByPage[pageIndex, default: []].append(
                    PDFMarkupQuad(
                        topLeft: CGPoint(x: bounds.minX, y: bounds.maxY),
                        topRight: CGPoint(x: bounds.maxX, y: bounds.maxY),
                        bottomLeft: CGPoint(x: bounds.minX, y: bounds.minY),
                        bottomRight: CGPoint(x: bounds.maxX, y: bounds.minY)
                    )
                )
            }
        }

        let pages = quadsByPage.keys.sorted().map {
            PDFMarkupPageSelection(pageIndex: $0, quads: quadsByPage[$0] ?? [])
        }
        guard !pages.isEmpty else { return nil }
        return PDFMarkupSelection(pages: pages, selectedText: selection.string ?? "")
    }

    @objc private func addHighlightFromMenu(_ sender: Any?) {
        highlightSelection(sender)
    }

    @objc private func addUnderlineFromMenu(_ sender: Any?) {
        underlineSelection(sender)
    }

    @objc private func addStrikeoutFromMenu(_ sender: Any?) {
        strikeoutSelection(sender)
    }

    @objc private func editAnnotationFromMenu(_ sender: Any?) {
        guard let annotation = contextMenuAnnotation,
              let page = document?.page(at: annotation.pageIndex) else { return }
        handleAnnotationPresentation(annotation, on: page, request: .explicitEdit)
    }

    @objc private func deleteAnnotationFromMenu(_ sender: Any?) {
        guard let annotation = contextMenuAnnotation else { return }
        Task { @MainActor [weak self] in
            if await self?.onDeleteAnnotation?(annotation) == true {
                self?.popoverCoordinator.dismiss(for: annotation.id)
            }
        }
    }

    func handleAnnotationPresentation(
        _ annotation: Annotation,
        on page: PDFPage,
        request: AnnotationPresentationRequest
    ) {
        popoverCoordinator.handle(annotation, on: page, request: request)
    }

    func flashTextRange(for annotation: Annotation) {
        interactionController.flash(annotation)
        pulseFocusHalo(for: annotation)
    }

    private func pulseFocusHalo(for annotation: Annotation) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let page = document?.page(at: annotation.pageIndex),
              let documentView else { return }

        documentView.wantsLayer = true
        let viewRect = convert(annotation.bounds, from: page)
        var targetRect = documentView.convert(viewRect, from: self).insetBy(dx: -6, dy: -6)
        if targetRect.width < 24 {
            targetRect = targetRect.insetBy(dx: -(24 - targetRect.width) / 2, dy: 0)
        }
        if targetRect.height < 24 {
            targetRect = targetRect.insetBy(dx: 0, dy: -(24 - targetRect.height) / 2)
        }

        let halo = CAShapeLayer()
        halo.bounds = CGRect(origin: .zero, size: targetRect.size)
        halo.position = CGPoint(x: targetRect.midX, y: targetRect.midY)
        halo.path = CGPath(roundedRect: halo.bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
        halo.fillColor = NSColor.clear.cgColor
        halo.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        halo.lineWidth = 2.5
        halo.opacity = 0

        documentView.layer?.addSublayer(halo)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.08

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.9
        opacity.toValue = 0.0

        let lineWidth = CABasicAnimation(keyPath: "lineWidth")
        lineWidth.fromValue = 2.5
        lineWidth.toValue = 1.0

        let group = CAAnimationGroup()
        group.animations = [scale, opacity, lineWidth]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak halo] in
            halo?.removeFromSuperlayer()
        }
        halo.add(group, forKey: "focusPulse")
        CATransaction.commit()
    }

    func center(
        annotation: Annotation,
        on page: PDFPage,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        go(to: page)
        layoutDocumentView()
        layoutSubtreeIfNeeded()
        guard let documentView else { return }

        let pageCenter = CGPoint(
            x: annotation.bounds.midX,
            y: annotation.bounds.midY
        )
        let pointInPDFView = convert(pageCenter, from: page)
        let pointInDocument = documentView.convert(pointInPDFView, from: self)
        let visibleSize = documentView.visibleRect.size
        let maximumX = max(0, documentView.bounds.width - visibleSize.width)
        let maximumY = max(0, documentView.bounds.height - visibleSize.height)
        let targetOrigin = CGPoint(
            x: min(max(0, pointInDocument.x - visibleSize.width / 2), maximumX),
            y: min(max(0, pointInDocument.y - visibleSize.height / 2), maximumY)
        )
        documentView.scroll(targetOrigin)
        if let scrollView = documentView.enclosingScrollView {
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        completion()
    }

    func cancelPendingHoverPresentation() {
        interactionController.cancelPendingHoverPresentation()
    }

    func mouseIsInsideAnnotation(_ annotationID: UUID, at screenPoint: CGPoint) -> Bool {
        guard let window else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        return annotationTarget(at: viewPoint)?.annotation.id == annotationID
    }

    /// ID of the comment-bearing annotation under a screen point, if any.
    /// Hovering such an annotation will present (or crossfade to) its preview.
    func commentableAnnotationID(at screenPoint: CGPoint) -> UUID? {
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        guard let target = annotationTarget(at: viewPoint),
              target.annotation.hasCommentText else { return nil }
        return target.annotation.id
    }

    /// Acrobat's Insert Text caret snaps to the baseline of the line under the
    /// cursor: the exact click height within the line is ignored, and descenders
    /// must not pull the marker down. Character boxes share one baseline, so the
    /// line baseline is the highest character bottom found along the line.
    func insertionPoint(for pagePoint: CGPoint, on page: PDFPage) -> CGPoint? {
        if let anchorIndex = resolvedCharacterIndex(for: pagePoint, on: page) {
            let anchor = page.characterBounds(at: anchorIndex)
            let baseline = visualBaseline(anchoredAt: anchorIndex, anchor: anchor, on: page)
            return CGPoint(x: pagePoint.x, y: baseline)
        }
        guard let lineSelection = page.selectionForLine(at: pagePoint) else { return nil }
        let lineBounds = lineSelection.bounds(for: page)
        guard lineBounds.width > 0, lineBounds.height > 0,
              lineBounds.insetBy(dx: -4, dy: -4).contains(pagePoint) else {
            return nil
        }

        let probeY = lineBounds.midY
        let clampedX = min(max(pagePoint.x, lineBounds.minX), lineBounds.maxX)
        let maxRadius = max(24, lineBounds.width)
        var distance: CGFloat = 0
        while distance <= maxRadius {
            let candidates = distance == 0 ? [clampedX] : [clampedX - distance, clampedX + distance]
            for x in candidates {
                let probePoint = CGPoint(x: min(max(x, lineBounds.minX), lineBounds.maxX), y: probeY)
                let index = page.characterIndex(at: probePoint)
                guard index != NSNotFound else { continue }
                let anchor = page.characterBounds(at: index)
                guard anchor.width > 0, anchor.height > 0 else { continue }
                let baseline = visualBaseline(anchoredAt: index, anchor: anchor, on: page)
                return CGPoint(x: pagePoint.x, y: baseline)
            }
            distance += 6
        }
        return CGPoint(x: pagePoint.x, y: lineBounds.minY)
    }

    private func resolvedCharacterIndex(for pagePoint: CGPoint, on page: PDFPage) -> Int? {
        let index = page.characterIndex(at: pagePoint)
        guard index != NSNotFound else { return nil }
        let bounds = page.characterBounds(at: index)
        guard bounds.width > 0, bounds.height > 0,
              bounds.insetBy(dx: -4, dy: -4).contains(pagePoint) else {
            return nil
        }
        return index
    }

    private func visualBaseline(anchoredAt characterIndex: Int, anchor: CGRect, on page: PDFPage) -> CGFloat {
        let text = page.string ?? ""
        let span = 80
        let firstIndex = max(0, characterIndex - span)
        let lastIndex = min(max(0, text.count - 1), characterIndex + span)
        var samples: [(minY: CGFloat, height: CGFloat)] = []
        var maxHeight: CGFloat = 0

        for index in firstIndex...lastIndex {
            let bounds = page.characterBounds(at: index)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            // Keep only characters on the same visual line as the anchor.
            let verticalOverlap = min(anchor.maxY, bounds.maxY) - max(anchor.minY, bounds.minY)
            guard verticalOverlap > 0 else { continue }
            samples.append((bounds.minY, bounds.height))
            maxHeight = max(maxHeight, bounds.height)
        }

        let fullBodyMinYs = samples
            .filter { $0.height >= maxHeight * 0.55 }
            .map(\.minY)
            .sorted()
        guard !fullBodyMinYs.isEmpty else { return anchor.minY }
        let index = min(fullBodyMinYs.count - 1, (fullBodyMinYs.count * 3) / 4)
        return fullBodyMinYs[index]
    }

    private func isOverText(on page: PDFPage, at pagePoint: CGPoint) -> Bool {
        let characterIndex = page.characterIndex(at: pagePoint)
        if characterIndex != NSNotFound && page.characterBounds(at: characterIndex).insetBy(dx: -0.5, dy: -0.5).contains(pagePoint) {
            return true
        }
        if let wordSelection = page.selectionForWord(at: pagePoint),
           wordSelection.bounds(for: page).insetBy(dx: -1, dy: -1).contains(pagePoint) {
            return true
        }
        if let lineSelection = page.selectionForLine(at: pagePoint),
           lineSelection.bounds(for: page).insetBy(dx: -1, dy: -1).contains(pagePoint) {
            return true
        }
        return false
    }

    func liveAnnotation(id: UUID, fallback: Annotation) -> Annotation {
        overlayAnnotations.values.joined().first(where: { $0.id == id }) ?? fallback
    }

    private func annotationTarget(at viewPoint: CGPoint) -> (annotation: Annotation, page: PDFPage)? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        return annotationTarget(on: page, at: pagePoint)
    }

    private func annotationTarget(
        on page: PDFPage,
        at pagePoint: CGPoint
    ) -> (annotation: Annotation, page: PDFPage)? {
        guard let document,
              let pageIndex = document.validPageIndex(for: page) else { return nil }
        guard let annotation = overlayAnnotations[pageIndex]?.last(where: {
            AnnotationOverlayRenderer.contains(pagePoint, in: $0)
        }) else { return nil }
        return (annotation, page)
    }

    private func reconcileAnnotationInteraction() {
        let availableIDs = Set(overlayAnnotations.values.joined().map(\.id))
        interactionController.reconcile(availableAnnotationIDs: availableIDs)
        popoverCoordinator.reconcile(availableAnnotationIDs: availableIDs)
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @discardableResult
    func createMarkupFromActiveSelection(kind: Annotation.Kind) -> Bool {
        guard let selection = markupSelection() else { return false }
        onCreateMarkupRequest?(kind, selection)
        clearSelection()
        return true
    }

    // Selection commands never arm a persistent tool. Choosing a tool remains
    // a separate menu/toolbar action, even when there is no selected text.
    @objc func applyHighlightToSelection(_ sender: Any?) {
        createMarkupFromActiveSelection(kind: .highlight)
    }

    @objc func applyUnderlineToSelection(_ sender: Any?) {
        createMarkupFromActiveSelection(kind: .underline)
    }

    @objc func applyStrikethroughToSelection(_ sender: Any?) {
        createMarkupFromActiveSelection(kind: .strikeout)
    }

    @objc func highlightSelection(_ sender: Any?) {
        if !createMarkupFromActiveSelection(kind: .highlight) {
            annotationTool = .highlight
            NotificationCenter.default.post(
                name: .annotViewToolDidChange,
                object: self,
                userInfo: ["tool": AnnotationTool.highlight]
            )
        }
    }

    @objc func underlineSelection(_ sender: Any?) {
        if !createMarkupFromActiveSelection(kind: .underline) {
            annotationTool = .underline
            NotificationCenter.default.post(
                name: .annotViewToolDidChange,
                object: self,
                userInfo: ["tool": AnnotationTool.underline]
            )
        }
    }

    @objc func strikeoutSelection(_ sender: Any?) {
        if !createMarkupFromActiveSelection(kind: .strikeout) {
            annotationTool = .strikeout
            NotificationCenter.default.post(
                name: .annotViewToolDidChange,
                object: self,
                userInfo: ["tool": AnnotationTool.strikeout]
            )
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(applyHighlightToSelection(_:)),
             #selector(applyUnderlineToSelection(_:)),
             #selector(applyStrikethroughToSelection(_:)):
            return markupSelection() != nil
        case #selector(highlightSelection(_:)),
             #selector(underlineSelection(_:)),
             #selector(strikeoutSelection(_:)):
            return document != nil
        default:
            return true
        }
    }

}
