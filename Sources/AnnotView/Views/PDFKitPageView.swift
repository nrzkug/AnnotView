import PDFKit
import SwiftUI

struct PDFKitPageView: NSViewRepresentable {
    let document: PDFDocument
    let annotations: [Annotation]
    let focusedAnnotation: Annotation?
    let annotationNavigationID: Int
    let searchResults: [PDFSelection]
    let currentSearchResultIndex: Int?
    let searchNavigationID: Int
    let zoomAction: PDFDocumentManager.ZoomAction
    let zoomRequestID: Int
    @Binding var selectedPageIndex: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedPageIndex: $selectedPageIndex)
    }

    func makeNSView(context: Context) -> AnnotationPDFView {
        let view = AnnotationPDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = .windowBackgroundColor
        view.delegate = context.coordinator
        view.pageOverlayViewProvider = view
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: AnnotationPDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = false
            let fittedScale = view.scaleFactorForSizeToFit
            if fittedScale.isFinite, fittedScale > 0 {
                view.scaleFactor = fittedScale
            }
        }
        view.overlayAnnotations = Dictionary(grouping: annotations, by: \.pageIndex)
        view.highlightedSelections = searchResults

        if view.lastSearchNavigationID != searchNavigationID {
            view.lastSearchNavigationID = searchNavigationID
            if let currentSearchResultIndex,
               searchResults.indices.contains(currentSearchResultIndex) {
                view.go(to: searchResults[currentSearchResultIndex])
            }
        }

        if view.lastZoomRequestID != zoomRequestID {
            view.lastZoomRequestID = zoomRequestID
            switch zoomAction {
            case .inwards: view.zoomIn(nil)
            case .outwards: view.zoomOut(nil)
            case .actualSize:
                view.autoScales = false
                view.scaleFactor = 1
            case .fitPage:
                view.autoScales = false
                let fittedScale = view.scaleFactorForSizeToFit
                if fittedScale.isFinite, fittedScale > 0 {
                    view.scaleFactor = fittedScale
                }
            }
        }

        var handledAnnotationNavigation = false
        if let focusedAnnotation,
           view.lastAnnotationNavigationID != annotationNavigationID,
           let targetPage = document.page(at: focusedAnnotation.pageIndex) {
            handledAnnotationNavigation = true
            view.lastAnnotationNavigationID = annotationNavigationID
            view.center(annotation: focusedAnnotation, on: targetPage) {
                view.flashTextRange(for: focusedAnnotation)
                if focusedAnnotation.hasCommentText {
                    view.presentAnnotation(focusedAnnotation, on: targetPage)
                }
            }
        }

        if !handledAnnotationNavigation,
           let currentPage = view.currentPage,
           document.index(for: currentPage) != selectedPageIndex,
           let targetPage = document.page(at: selectedPageIndex) {
            view.go(to: targetPage)
        }
    }

    static func dismantleNSView(_ view: AnnotationPDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        private var selectedPageIndex: Binding<Int>
        private var observer: NSObjectProtocol?

        init(selectedPageIndex: Binding<Int>) {
            self.selectedPageIndex = selectedPageIndex
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self, weak view] _ in
                Task { @MainActor [weak self, weak view] in
                    guard let self, let view, let page = view.currentPage else { return }
                    self.selectedPageIndex.wrappedValue = view.document?.index(for: page) ?? 0
                }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

private extension Annotation {
    var hasCommentText: Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
