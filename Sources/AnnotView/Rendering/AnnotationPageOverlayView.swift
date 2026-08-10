import AppKit
import PDFKit

/// One overlay per visible PDF page. Mapping three basis points through
/// PDFView produces the affine page-to-overlay transform, including CropBox,
/// rotation, zoom, continuous-page layout and a non-zero PDF page origin.
final class AnnotationPageOverlayView: NSView {
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
    var selectedAnnotationID: UUID? {
        didSet {
            if oldValue != selectedAnnotationID { needsDisplay = true }
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
        transientAnnotationID: UUID?,
        selectedAnnotationID: UUID?
    ) {
        self.pdfView = pdfView
        self.page = page
        self.pageIndex = pageIndex
        self.annotations = annotations
        self.hoveredAnnotationID = hoveredAnnotationID
        self.transientAnnotationID = transientAnnotationID
        self.selectedAnnotationID = selectedAnnotationID
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
        if let selected = annotations.last(where: { $0.id == selectedAnnotationID }) {
            AnnotationOverlayRenderer.drawSelection(for: selected, context: context)
        }
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
