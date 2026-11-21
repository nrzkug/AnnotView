import CoreGraphics
import Foundation

struct AnnotationHistoryOperation {
    enum Mutation {
        case delete(snapshots: [Annotation], sourceIDs: [String])
        case restore(snapshots: [Annotation])
        case update(sourceID: String, value: Annotation, inverse: Annotation)
        case move(sourceID: String, rect: CGRect, inverseRect: CGRect)
    }

    let actionName: String
    let mutation: Mutation

    func remappingSourceIDs(_ map: [String: String]) -> AnnotationHistoryOperation {
        guard !map.isEmpty else { return self }
        func remapAnnotation(_ item: Annotation) -> Annotation {
            var copy = item
            if let id = copy.sourceID, let next = map[id] { copy.sourceID = next }
            if let id = copy.statusTargetSourceID, let next = map[id] { copy.statusTargetSourceID = next }
            if let id = copy.inReplyToSourceID, let next = map[id] { copy.inReplyToSourceID = next }
            return copy
        }
        let nextMutation: Mutation = switch mutation {
        case let .delete(snapshots, sourceIDs):
            .delete(
                snapshots: snapshots.map(remapAnnotation),
                sourceIDs: {
                    var seen = Set<String>()
                    return sourceIDs.map { map[$0] ?? $0 }.filter { seen.insert($0).inserted }
                }()
            )
        case let .restore(snapshots):
            .restore(snapshots: snapshots.map(remapAnnotation))
        case let .update(sourceID, value, inverse):
            .update(
                sourceID: map[sourceID] ?? sourceID,
                value: remapAnnotation(value),
                inverse: remapAnnotation(inverse)
            )
        case let .move(sourceID, rect, inverseRect):
            .move(
                sourceID: map[sourceID] ?? sourceID,
                rect: rect,
                inverseRect: inverseRect
            )
        }
        return AnnotationHistoryOperation(actionName: actionName, mutation: nextMutation)
    }
}

enum AnnotationHistoryError: LocalizedError {
    case documentUnavailable
    case unsupportedSnapshot
    case recreatedAnnotationsMissing
    case updatedAnnotationMissing

    var errorDescription: String? {
        switch self {
        case .documentUnavailable: "The PDF is no longer available."
        case .unsupportedSnapshot: "An annotation type in the history cannot be restored."
        case .recreatedAnnotationsMissing: "The restored annotations could not be found."
        case .updatedAnnotationMissing: "The updated annotation could not be found."
        }
    }
}

/// Bounded undo/redo stack for annotation edits, deletions, creations, and moves.
@MainActor
struct AnnotationHistoryStore {
    let maxEntries: Int
    private var undoStack: [AnnotationHistoryOperation] = []
    private var redoStack: [AnnotationHistoryOperation] = []

    init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoTitle: String { undoStack.last.map { "Undo \($0.actionName)" } ?? "Undo" }
    var redoTitle: String { redoStack.last.map { "Redo \($0.actionName)" } ?? "Redo" }

    mutating func record(_ operation: AnnotationHistoryOperation) {
        if case let .delete(_, sourceIDs) = operation.mutation, sourceIDs.isEmpty { return }
        undoStack.append(operation)
        if undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }
        redoStack.removeAll()
    }

    mutating func popUndo() -> AnnotationHistoryOperation? {
        undoStack.popLast()
    }

    mutating func popRedo() -> AnnotationHistoryOperation? {
        redoStack.popLast()
    }

    mutating func pushUndo(_ operation: AnnotationHistoryOperation) {
        undoStack.append(operation)
        if undoStack.count > maxEntries {
            undoStack.removeFirst(undoStack.count - maxEntries)
        }
    }

    mutating func pushRedo(_ operation: AnnotationHistoryOperation) {
        redoStack.append(operation)
        if redoStack.count > maxEntries {
            redoStack.removeFirst(redoStack.count - maxEntries)
        }
    }

    mutating func remapSourceIDs(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        undoStack = undoStack.map { $0.remappingSourceIDs(map) }
        redoStack = redoStack.map { $0.remappingSourceIDs(map) }
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
