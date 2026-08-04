import AppKit
import PDFKit
import SwiftUI

/// PDFKit draws only page content; this subclass paints engine-neutral annotations on top.
final class AnnotationPDFView: PDFView, @preconcurrency PDFPageOverlayViewProvider, NSPopoverDelegate {
    var lastAnnotationNavigationID = 0
    var lastSearchNavigationID = 0
    var lastZoomRequestID = 0
    private var annotationPopover: NSPopover?
    private var presentedAnnotationID: UUID?
    private var annotationPopoverIsPinned = false
    private var hoverDismissTask: Task<Void, Never>?
    private var hoverPresentationTask: Task<Void, Never>?
    private var transientHighlightTask: Task<Void, Never>?
    private var hoveredAnnotationID: UUID? {
        didSet {
            for overlay in pageOverlayViews.allObjects {
                overlay.hoveredAnnotationID = hoveredAnnotationID
            }
        }
    }
    private var transientAnnotationID: UUID? {
        didSet {
            for overlay in pageOverlayViews.allObjects {
                overlay.transientAnnotationID = transientAnnotationID
            }
        }
    }
    private var mouseTrackingArea: NSTrackingArea?
    private let pageOverlayViews = NSHashTable<AnnotationPageOverlayView>.weakObjects()

    var overlayAnnotations: [Int: [Annotation]] = [:] {
        didSet {
            for overlay in pageOverlayViews.allObjects {
                overlay.annotations = overlayAnnotations[overlay.pageIndex] ?? []
            }
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document else { return nil }
        let pageIndex = document.index(for: page)
        let overlay = AnnotationPageOverlayView(
            pdfView: self,
            page: page,
            pageIndex: pageIndex,
            annotations: overlayAnnotations[pageIndex] ?? [],
            hoveredAnnotationID: hoveredAnnotationID,
            transientAnnotationID: transientAnnotationID
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

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let target = annotationTarget(at: viewPoint)
        target == nil ? NSCursor.arrow.set() : NSCursor.pointingHand.set()
        guard target?.annotation.id != hoveredAnnotationID else { return }

        if let hoveredAnnotationID { dismissHoverPreview(for: hoveredAnnotationID) }
        hoverPresentationTask?.cancel()
        hoveredAnnotationID = target?.annotation.id
        guard let target, target.annotation.hasCommentText else { return }

        hoverPresentationTask = Task { @MainActor [weak self, weak page = target.page] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled,
                  self?.hoveredAnnotationID == target.annotation.id,
                  let self, let page else { return }
            self.presentAnnotation(target.annotation, on: page, pinned: false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let hoveredAnnotationID { dismissHoverPreview(for: hoveredAnnotationID) }
        hoveredAnnotationID = nil
        hoverPresentationTask?.cancel()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let target = annotationTarget(at: viewPoint), target.annotation.hasCommentText {
            hoverPresentationTask?.cancel()
            presentAnnotation(target.annotation, on: target.page, pinned: true)
            return
        }
        super.mouseDown(with: event)
    }

    func presentAnnotation(_ annotation: Annotation, on page: PDFPage, pinned: Bool = true) {
        hoverDismissTask?.cancel()
        if presentedAnnotationID == annotation.id, annotationPopover?.isShown == true {
            annotationPopoverIsPinned = annotationPopoverIsPinned || pinned
            return
        }
        annotationPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let popoverHeight = Self.popoverHeight(for: annotation)
        popover.contentSize = NSSize(width: 330, height: popoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: AnnotationPopoverView(annotation: annotation, height: popoverHeight)
        )
        let anchor = convert(AnnotationOverlayRenderer.anchorBounds(for: annotation), from: page)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxX)
        annotationPopover = popover
        presentedAnnotationID = annotation.id
        annotationPopoverIsPinned = pinned
    }

    func flashTextRange(for annotation: Annotation) {
        guard annotation.kind == .highlight
                || annotation.kind == .underline
                || annotation.kind == .strikeout,
              !AnnotationOverlayRenderer.quadrilaterals(from: annotation).isEmpty else { return }

        transientHighlightTask?.cancel()
        transientAnnotationID = annotation.id
        transientHighlightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_800))
            guard !Task.isCancelled, self?.transientAnnotationID == annotation.id else { return }
            self?.transientAnnotationID = nil
        }
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

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === annotationPopover else { return }
        annotationPopover = nil
        presentedAnnotationID = nil
        annotationPopoverIsPinned = false
    }

    func dismissHoverPreview(for annotationID: UUID) {
        hoverDismissTask?.cancel()
        hoverDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  let self,
                  self.presentedAnnotationID == annotationID,
                  !self.annotationPopoverIsPinned else { return }
            self.annotationPopover?.close()
            self.annotationPopover = nil
            self.presentedAnnotationID = nil
        }
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

    private static func popoverHeight(for annotation: Annotation) -> CGFloat {
        let text = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let explicitLines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let wrappedLines = max(explicitLines, Int(ceil(Double(text.count) / 38.0)))
        return min(260, max(132, 108 + CGFloat(wrappedLines) * 19))
    }
}

/// One overlay per visible PDF page. Mapping three basis points through
/// PDFView produces the affine page-to-overlay transform, including CropBox,
/// rotation, zoom, continuous-page layout and a non-zero PDF page origin.
private final class AnnotationPageOverlayView: NSView {
    weak var pdfView: AnnotationPDFView?
    weak var page: PDFPage?
    let pageIndex: Int
    var hoveredAnnotationID: UUID? {
        didSet {
            if oldValue != hoveredAnnotationID { needsDisplay = true }
        }
    }
    var transientAnnotationID: UUID? {
        didSet {
            if oldValue != transientAnnotationID { needsDisplay = true }
        }
    }
    var annotations: [Annotation] {
        didSet { needsDisplay = true }
    }

    init(
        pdfView: AnnotationPDFView,
        page: PDFPage,
        pageIndex: Int,
        annotations: [Annotation],
        hoveredAnnotationID: UUID?,
        transientAnnotationID: UUID?
    ) {
        self.pdfView = pdfView
        self.page = page
        self.pageIndex = pageIndex
        self.annotations = annotations
        self.hoveredAnnotationID = hoveredAnnotationID
        self.transientAnnotationID = transientAnnotationID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let transform = pageToOverlayTransform() else { return }
        context.saveGState()
        context.concatenate(transform)
        AnnotationOverlayRenderer.draw(annotations, context: context)
        let emphasizedID = hoveredAnnotationID ?? transientAnnotationID
        if let emphasized = annotations.last(where: { $0.id == emphasizedID }) {
            AnnotationOverlayRenderer.drawHover(for: emphasized, context: context)
        }
        context.restoreGState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Drawing only. PDFView handles annotation interaction so PDFKit never opens
        // its native annotation editor underneath this custom overlay.
        nil
    }

    private func pageToOverlayTransform() -> CGAffineTransform? {
        guard let pdfView, let page else { return nil }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let origin = localPoint(for: pageBounds.origin, pdfView: pdfView, page: page)
        let xBasis = localPoint(
            for: CGPoint(x: pageBounds.minX + 1, y: pageBounds.minY),
            pdfView: pdfView,
            page: page
        )
        let yBasis = localPoint(
            for: CGPoint(x: pageBounds.minX, y: pageBounds.minY + 1),
            pdfView: pdfView,
            page: page
        )
        return PageOverlayGeometry.affineTransform(
            pageBounds: pageBounds,
            localOrigin: origin,
            localXBasis: xBasis,
            localYBasis: yBasis
        )
    }

    private func localPoint(
        for pagePoint: CGPoint,
        pdfView: PDFView,
        page: PDFPage
    ) -> CGPoint {
        convert(pdfView.convert(pagePoint, from: page), from: pdfView)
    }
}

private struct AnnotationPopoverView: View {
    let annotation: Annotation
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: annotation.popupSymbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.author?.nilIfEmpty ?? "Unknown author")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Text(annotation.popupKindName)
                        if let date = annotation.createdDate {
                            Text("·")
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                        }
                        Text("·")
                        Label(annotation.status.displayName, systemImage: annotation.status.symbolName)
                            .foregroundStyle(annotation.status.tint)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            ScrollView {
                Text(annotation.contents?.nilIfEmpty ?? "No comment text")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(14)
        .frame(width: 330, height: height, alignment: .topLeading)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Annotation {
    var hasCommentText: Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var popupKindName: String {
        switch kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikeout"
        case .note: "Note"
        case .ink: "Ink"
        }
    }

    var popupSymbolName: String {
        switch kind {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "note.text"
        case .ink: "scribble"
        }
    }
}
