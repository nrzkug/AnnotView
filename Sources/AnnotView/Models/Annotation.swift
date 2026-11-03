import CoreGraphics
import Foundation

/// Engine-neutral annotation data. Coordinates are normalized to PDF page space.
struct Annotation: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case highlight
        case underline
        case strikeout
        case note
        case ink
        case caret
    }

    /// Acrobat-compatible values stored as `/StateModel` and `/State`.
    enum Status: String, CaseIterable, Sendable {
        case none
        case accepted
        case rejected
        case cancelled
        case completed
        case marked
        case unmarked

        /// Acrobat's commonly exposed review workflow. Marked/Unmarked belong
        /// to a separate PDF state model and remain parser-only compatibility.
        static let selectableCases: [Status] = [
            .none, .accepted, .rejected, .cancelled, .completed
        ]

        var stateModel: String {
            switch self {
            case .marked, .unmarked: "Marked"
            default: "Review"
            }
        }

        var pdfStateName: String {
            switch self {
            case .none: "None"
            case .accepted: "Accepted"
            case .rejected: "Rejected"
            case .cancelled: "Cancelled"
            case .completed: "Completed"
            case .marked: "Marked"
            case .unmarked: "Unmarked"
            }
        }

        var displayName: String {
            switch self {
            case .none: "Pending"
            case .accepted: "Accepted"
            case .rejected: "Rejected"
            case .cancelled: "Cancelled"
            case .completed: "Completed"
            case .marked: "Marked"
            case .unmarked: "Unmarked"
            }
        }

        var help: String {
            switch self {
            case .none: "No review decision has been recorded."
            case .accepted: "The suggestion is accepted; the change may still need to be made."
            case .rejected: "The suggestion will not be used."
            case .cancelled: "The suggestion has been withdrawn."
            case .completed: "Work on this suggestion is complete."
            case .marked: "The annotation is marked."
            case .unmarked: "The annotation is unmarked."
            }
        }

        var symbolName: String {
            switch self {
            case .none: "circle"
            case .accepted: "checkmark.circle"
            case .rejected: "xmark.circle"
            case .cancelled: "slash.circle"
            case .completed: "checkmark.circle.fill"
            case .marked: "flag.fill"
            case .unmarked: "flag"
            }
        }

        /// Lucide asset names, matching the toolbar icon catalog.
        var iconName: String {
            switch self {
            case .none: "circle"
            case .accepted: "circle-check"
            case .rejected: "circle-x"
            case .cancelled: "circle-slash"
            case .completed: "circle-check-big"
            case .marked, .unmarked: "flag"
            }
        }
    }

    struct Color: Hashable, Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat
        var alpha: CGFloat

        static let yellow = Color(red: 1, green: 0.819608, blue: 0, alpha: 0.35)
        static let green = Color(red: 0.243, green: 0.725, blue: 0.353, alpha: 1)
        static let red = Color(red: 0.9, green: 0.15, blue: 0.12, alpha: 0.9)

        func replacingRGB(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
            Color(red: red, green: green, blue: blue, alpha: alpha)
        }
    }

    var id: UUID
    /// Stable PDF object identifier supplied by the annotation engine.
    var sourceID: String?
    /// Source identifier of the parent annotation for Acrobat reply comments.
    var inReplyToSourceID: String?
    /// PDF object that owns Acrobat's state fields. Replacement edits use their Caret parent.
    var statusTargetSourceID: String?
    var kind: Kind
    var pageIndex: Int
    var bounds: CGRect
    var quadPoints: [CGPoint]
    var contents: String?
    /// Text covered by the annotation's quad points, extracted for display.
    var markedText: String?
    var author: String?
    var createdDate: Date?
    var color: Color
    var status: Status

    init(
        id: UUID = UUID(),
        sourceID: String? = nil,
        inReplyToSourceID: String? = nil,
        statusTargetSourceID: String? = nil,
        kind: Kind,
        pageIndex: Int,
        bounds: CGRect,
        quadPoints: [CGPoint] = [],
        contents: String? = nil,
        markedText: String? = nil,
        author: String? = nil,
        createdDate: Date? = nil,
        color: Color = .yellow,
        status: Status = .none
    ) {
        self.id = id
        self.sourceID = sourceID
        self.inReplyToSourceID = inReplyToSourceID
        self.statusTargetSourceID = statusTargetSourceID ?? sourceID
        self.kind = kind
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.quadPoints = quadPoints
        self.contents = contents
        self.markedText = markedText
        self.author = author
        self.createdDate = createdDate
        self.color = color
        self.status = status
    }
}

extension Annotation {
    var hasCommentText: Bool {
        contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

extension Annotation.Kind {
    var displayName: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikethrough"
        case .note: "Note"
        case .ink: "Ink"
        case .caret: "Insertion"
        }
    }

    /// Lucide asset names, matching the toolbar icon catalog.
    var iconName: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "message-square-text"
        case .ink: "pencil"
        case .caret: "text-cursor-input"
        }
    }
}
