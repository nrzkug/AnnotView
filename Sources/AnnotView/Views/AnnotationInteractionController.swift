import PDFKit

@MainActor
final class AnnotationInteractionController {
    private let onHoveredAnnotationChanged: @MainActor (UUID?) -> Void
    private let onTransientAnnotationChanged: @MainActor (UUID?) -> Void
    private var hoverPresentationTask: Task<Void, Never>?
    private var transientHighlightTask: Task<Void, Never>?

    private(set) var hoveredAnnotationID: UUID? {
        didSet {
            guard oldValue != hoveredAnnotationID else { return }
            onHoveredAnnotationChanged(hoveredAnnotationID)
        }
    }
    private(set) var transientAnnotationID: UUID? {
        didSet {
            guard oldValue != transientAnnotationID else { return }
            onTransientAnnotationChanged(transientAnnotationID)
        }
    }

    init(
        onHoveredAnnotationChanged: @escaping @MainActor (UUID?) -> Void,
        onTransientAnnotationChanged: @escaping @MainActor (UUID?) -> Void
    ) {
        self.onHoveredAnnotationChanged = onHoveredAnnotationChanged
        self.onTransientAnnotationChanged = onTransientAnnotationChanged
    }

    func updateHover(
        annotation: Annotation?,
        page: PDFPage?,
        presentationContext: AnnotationPresentationContext,
        present: @escaping @MainActor (Annotation, PDFPage) -> Void
    ) {
        guard annotation?.id != hoveredAnnotationID else { return }
        hoverPresentationTask?.cancel()
        hoveredAnnotationID = annotation?.id
        guard let annotation, let page,
              AnnotationPresentationPolicy.action(
                  for: annotation,
                  request: .hover,
                  context: presentationContext
              ) != .ignore else { return }

        hoverPresentationTask = Task { @MainActor [weak self, weak page] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled,
                  self?.hoveredAnnotationID == annotation.id,
                  let page else { return }
            present(annotation, page)
        }
    }

    func clearHover() {
        hoveredAnnotationID = nil
        hoverPresentationTask?.cancel()
    }

    func cancelPendingHoverPresentation() {
        hoverPresentationTask?.cancel()
    }

    func flash(_ annotation: Annotation) {
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

    func reconcile(availableAnnotationIDs: Set<UUID>) {
        if let hoveredAnnotationID, !availableAnnotationIDs.contains(hoveredAnnotationID) {
            clearHover()
        }
        if let transientAnnotationID, !availableAnnotationIDs.contains(transientAnnotationID) {
            transientHighlightTask?.cancel()
            self.transientAnnotationID = nil
        }
    }

    func reset() {
        hoverPresentationTask?.cancel()
        transientHighlightTask?.cancel()
        hoveredAnnotationID = nil
        transientAnnotationID = nil
    }
}
