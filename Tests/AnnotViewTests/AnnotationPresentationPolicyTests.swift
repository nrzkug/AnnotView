import CoreGraphics
import Testing
@testable import AnnotView

struct AnnotationPresentationPolicyTests {
    @Test func routesContentAnnotationsByInteractionSource() {
        let annotation = makeAnnotation(contents: "A comment")

        #expect(action(for: annotation, request: .hover) == .preview(pinned: false))
        #expect(action(for: annotation, request: .documentClick) == .preview(pinned: true))
        #expect(action(for: annotation, request: .sidebarNavigation) == .preview(pinned: true))
        #expect(action(for: annotation, request: .explicitEdit) == .editor)
    }

    @Test func routesEmptyAnnotationsWithoutImplicitEditors() {
        let annotation = makeAnnotation(contents: "  \n ")

        #expect(action(for: annotation, request: .hover) == .ignore)
        #expect(action(for: annotation, request: .documentClick) == .editor)
        #expect(action(for: annotation, request: .sidebarNavigation) == .dismiss)
        #expect(action(for: annotation, request: .explicitEdit) == .editor)
    }

    @Test func hoverCannotReplacePinnedOrEditableContent() {
        let annotation = makeAnnotation(contents: "A comment")

        #expect(action(for: annotation, request: .hover, context: .pinnedPreview) == .ignore)
        #expect(action(for: annotation, request: .hover, context: .editor) == .ignore)
        #expect(
            action(for: annotation, request: .hover, context: .transientPreview)
                == .preview(pinned: false)
        )
    }

    private func action(
        for annotation: Annotation,
        request: AnnotationPresentationRequest,
        context: AnnotationPresentationContext = .none
    ) -> AnnotationPresentationAction {
        AnnotationPresentationPolicy.action(
            for: annotation,
            request: request,
            context: context
        )
    }

    private func makeAnnotation(contents: String?) -> Annotation {
        Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 10, width: 40, height: 12),
            contents: contents
        )
    }
}
