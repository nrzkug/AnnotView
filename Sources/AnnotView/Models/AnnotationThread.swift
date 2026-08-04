import Foundation

struct AnnotationThread: Identifiable {
    var id: UUID { root.id }
    let root: Annotation
    let replies: [Annotation]
}

enum AnnotationThreading {
    static func group(_ annotations: [Annotation]) -> [AnnotationThread] {
        let knownIDs = Set(annotations.compactMap(\.sourceID))
        let repliesByParent = Dictionary(grouping: annotations.compactMap { annotation in
            annotation.inReplyToSourceID.map { ($0, annotation) }
        }, by: \.0)

        return annotations
            .filter { annotation in
                guard let parent = annotation.inReplyToSourceID else { return true }
                return !knownIDs.contains(parent)
            }
            .map { root in
                AnnotationThread(
                    root: root,
                    replies: root.sourceID.flatMap { id in
                        repliesByParent[id]?.map(\.1)
                    } ?? []
                )
            }
    }
}
