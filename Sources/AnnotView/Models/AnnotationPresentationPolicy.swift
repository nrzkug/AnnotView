import Foundation

enum AnnotationPresentationRequest: Sendable {
    case hover
    case documentClick
    case sidebarNavigation
    case explicitEdit
}

enum AnnotationPresentationContext: Equatable, Sendable {
    case none
    case transientPreview
    case pinnedPreview
    case editor
}

enum AnnotationPresentationAction: Equatable, Sendable {
    case ignore
    case dismiss
    case preview(pinned: Bool)
    case editor
}

enum AnnotationPresentationPolicy {
    static func action(
        for annotation: Annotation,
        request: AnnotationPresentationRequest,
        context: AnnotationPresentationContext = .none
    ) -> AnnotationPresentationAction {
        switch request {
        case .hover:
            guard context != .pinnedPreview, context != .editor else { return .ignore }
            return annotation.hasCommentText ? .preview(pinned: false) : .ignore
        case .documentClick:
            return annotation.hasCommentText ? .preview(pinned: true) : .editor
        case .sidebarNavigation:
            return annotation.hasCommentText ? .preview(pinned: true) : .dismiss
        case .explicitEdit:
            return .editor
        }
    }
}
