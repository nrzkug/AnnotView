import AppKit
import PDFKit

/// PDFKit draws only page content; this subclass paints engine-neutral annotations on top.
final class AnnotationPDFView: PDFView, @preconcurrency PDFPageOverlayViewProvider {
    var annotationTool: AnnotationTool = .selection {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var onCreateMarkupRequest: (@MainActor (Annotation.Kind, PDFMarkupSelection) -> Void)?
    var onCreateNoteRequest: (@MainActor (PDFPagePoint) -> Void)?
    var onCreateInsertTextRequest: (@MainActor (PDFPagePoint) -> Void)?
    var onUpdateAnnotation: (@MainActor (Annotation, String, Annotation.Color) async -> Bool)?
    var onMoveAnnotationRequest: (@MainActor (Annotation, CGRect) -> Void)?
    var onDeleteAnnotation: (@MainActor (Annotation) async -> Bool)?
    var onSelectAnnotationRequest: (@MainActor (UUID) -> Void)?
    var onDeselectAnnotationRequest: (@MainActor () -> Void)?
    var lastAnnotationNavigationID = 0
    var lastSearchNavigationID = 0
    var lastZoomRequestID = 0
    private var suppressesMarkupOnMouseUp = false
    private var contextMenuAnnotation: Annotation?
    private var contextMenuPagePoint: PDFPagePoint?
    private var mouseTrackingArea: NSTrackingArea?
    private var dragState: (annotation: Annotation, page: PDFPage, startViewPoint: CGPoint, startBounds: CGRect)?
    private let pageOverlayViews = NSHashTable<AnnotationPageOverlayView>.weakObjects()

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
            for overlay in pageOverlayViews.allObjects {
                overlay.annotations = overlayAnnotations[overlay.pageIndex] ?? []
            }
            reconcileAnnotationInteraction()
        }
    }

    func resetAnnotationInteraction() {
        interactionController.reset()
        popoverCoordinator.reset()
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document else { return nil }
        let pageIndex = document.index(for: page)
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        mouseTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if annotationTool == .note {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let target = annotationTarget(at: viewPoint)
        if target != nil {
            NSCursor.pointingHand.set()
        } else if annotationTool == .note {
            NSCursor.crosshair.set()
        } else if annotationTool == .insertText {
            NSCursor.iBeam.set()
        } else if isOverText(at: viewPoint) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
        interactionController.updateHover(
            annotation: target?.annotation,
            page: target?.page,
            presentationContext: popoverCoordinator.policyContext,
            present: { [weak self] annotation, page in
                self?.handleAnnotationPresentation(annotation, on: page, request: .hover)
            }
        )
    }

    override func mouseExited(with event: NSEvent) {
        interactionController.clearHover()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        suppressesMarkupOnMouseUp = false
        if let target = annotationTarget(at: viewPoint) {
            suppressesMarkupOnMouseUp = true
            onSelectAnnotationRequest?(target.annotation.id)
            interactionController.cancelPendingHoverPresentation()
            if target.annotation.kind == .note || target.annotation.kind == .caret {
                // Position-based annotations: wait for mouseUp to tell a click
                // from a drag, then pin the preview or move the annotation.
                dragState = (
                    annotation: target.annotation,
                    page: target.page,
                    startViewPoint: viewPoint,
                    startBounds: target.annotation.bounds
                )
                return
            }
            // Markup kinds pin the preview on press. The hover preview is
            // semitransient, so it is still open here and gets upgraded in
            // place rather than racing a closing popover.
            handleAnnotationPresentation(target.annotation, on: target.page, request: .documentClick)
            return
        }
        if annotationTool == .note || annotationTool == .insertText,
           let page = page(for: viewPoint, nearest: false),
           let document {
            suppressesMarkupOnMouseUp = true
            onDeselectAnnotationRequest?()
            let rawPoint = convert(viewPoint, to: page)
            let point = annotationTool == .insertText
                ? insertionPoint(for: rawPoint, on: page)
                : rawPoint
            let location = PDFPagePoint(
                pageIndex: document.index(for: page),
                point: point
            )
            if annotationTool == .note {
                onCreateNoteRequest?(location)
            } else {
                onCreateInsertTextRequest?(location)
            }
            return
        }
        onDeselectAnnotationRequest?()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if dragState != nil {
            // Dragging has begun: drop the pinned preview and move the note.
            popoverCoordinator.dismiss()
            updateDrag(to: convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = dragState {
            dragState = nil
            let viewPoint = convert(event.locationInWindow, from: nil)
            let pagePoint = convert(viewPoint, to: drag.page)
            let startPagePoint = convert(drag.startViewPoint, to: drag.page)
            let moved = hypot(pagePoint.x - startPagePoint.x, pagePoint.y - startPagePoint.y)
            if moved < 3 {
                // A click: pin the (still-open, semitransient) hover preview.
                handleAnnotationPresentation(drag.annotation, on: drag.page, request: .documentClick)
            } else if let onMoveAnnotationRequest {
                popoverCoordinator.dismiss()
                onMoveAnnotationRequest(drag.annotation, drag.annotation.bounds)
            }
            return
        }
        super.mouseUp(with: event)
        guard !suppressesMarkupOnMouseUp,
              let kind = annotationTool.markupKind,
              let selection = markupSelection() else { return }
        onCreateMarkupRequest?(kind, selection)
        clearSelection()
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
        dragState = (annotation: updated, page: drag.page, startViewPoint: drag.startViewPoint, startBounds: drag.startBounds)
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
        } else if contextMenuPagePoint != nil {
            // No selection: offer point-based annotations at the click location.
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addMenuItem("Add Sticky Note", action: #selector(addNoteFromMenu(_:)), to: menu)
            addMenuItem("Add Insert Text", action: #selector(addInsertTextFromMenu(_:)), to: menu)
        }
        return menu
    }

    private func pagePoint(at viewPoint: CGPoint) -> PDFPagePoint? {
        guard let page = page(for: viewPoint, nearest: false), let document else { return nil }
        return PDFPagePoint(
            pageIndex: document.index(for: page),
            point: convert(viewPoint, to: page)
        )
    }

    @objc private func addNoteFromMenu(_ sender: Any?) {
        guard let location = contextMenuPagePoint else { return }
        onCreateNoteRequest?(location)
    }

    @objc private func addInsertTextFromMenu(_ sender: Any?) {
        guard let location = contextMenuPagePoint else { return }
        if let page = document?.page(at: location.pageIndex) {
            onCreateInsertTextRequest?(
                PDFPagePoint(
                    pageIndex: location.pageIndex,
                    point: insertionPoint(for: location.point, on: page)
                )
            )
        } else {
            onCreateInsertTextRequest?(location)
        }
    }

    func markupSelection() -> PDFMarkupSelection? {
        guard let document, let selection = currentSelection else { return nil }
        var quadsByPage: [Int: [PDFMarkupQuad]] = [:]

        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.01, bounds.height > 0.01 else { continue }
                let pageIndex = document.index(for: page)
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
        createMarkupFromMenu(kind: .highlight)
    }

    @objc private func addUnderlineFromMenu(_ sender: Any?) {
        createMarkupFromMenu(kind: .underline)
    }

    @objc private func addStrikeoutFromMenu(_ sender: Any?) {
        createMarkupFromMenu(kind: .strikeout)
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

    /// Acrobat's Insert Text caret snaps to the baseline of the line under the
    /// cursor: the exact click height within the line is ignored, and descenders
    /// must not pull the marker down. Character boxes share one baseline, so the
    /// line baseline is the highest character bottom found along the line.
    private func insertionPoint(for pagePoint: CGPoint, on page: PDFPage) -> CGPoint {
        let characterIndex = page.characterIndex(at: pagePoint)
        guard characterIndex != NSNotFound else { return pagePoint }
        let anchor = page.characterBounds(at: characterIndex)
        guard anchor.width > 0, anchor.height > 0 else { return pagePoint }

        let text = page.string ?? ""
        var baseline = anchor.minY
        let span = 80
        let firstIndex = max(0, characterIndex - span)
        let lastIndex = min(max(0, text.count - 1), characterIndex + span)
        for index in firstIndex...lastIndex {
            let bounds = page.characterBounds(at: index)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            // Keep only characters on the same visual line as the anchor.
            let verticalOverlap = min(anchor.maxY, bounds.maxY) - max(anchor.minY, bounds.minY)
            guard verticalOverlap > 0 else { continue }
            baseline = max(baseline, bounds.minY)
        }
        return CGPoint(x: pagePoint.x, y: baseline)
    }

    private func isOverText(at viewPoint: CGPoint) -> Bool {
        guard let page = page(for: viewPoint, nearest: false) else { return false }
        let pagePoint = convert(viewPoint, to: page)
        let characterIndex = page.characterIndex(at: pagePoint)
        guard characterIndex != NSNotFound else { return false }
        return page.characterBounds(at: characterIndex).insetBy(dx: -0.5, dy: -0.5).contains(pagePoint)
    }

    private func annotationTarget(at viewPoint: CGPoint) -> (annotation: Annotation, page: PDFPage)? {
        guard let page = page(for: viewPoint, nearest: false), let document else { return nil }
        let pageIndex = document.index(for: page)
        let pagePoint = convert(viewPoint, to: page)
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

    private func createMarkupFromMenu(kind: Annotation.Kind) {
        guard let selection = markupSelection() else { return }
        onCreateMarkupRequest?(kind, selection)
        clearSelection()
    }

}
