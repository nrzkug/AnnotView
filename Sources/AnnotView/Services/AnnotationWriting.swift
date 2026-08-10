import CoreGraphics
import Foundation

enum AnnotationTool: String, CaseIterable, Sendable {
    case selection
    case highlight
    case underline
    case strikeout
    case note
    case insertText

    var markupKind: Annotation.Kind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeout: .strikeout
        case .selection, .note, .insertText: nil
        }
    }
}

struct PDFMarkupQuad: Equatable, Sendable {
    /// Acrobat's QuadPoints order: top-left, top-right, bottom-left, bottom-right.
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint

    var points: [CGPoint] {
        [topLeft, topRight, bottomLeft, bottomRight]
    }
}

struct PDFMarkupPageSelection: Equatable, Sendable {
    let pageIndex: Int
    let quads: [PDFMarkupQuad]
}

struct PDFMarkupSelection: Equatable, Sendable {
    let pages: [PDFMarkupPageSelection]
    let selectedText: String

    var isEmpty: Bool {
        pages.allSatisfy(\.quads.isEmpty)
    }
}

struct PDFPagePoint: Equatable, Sendable {
    let pageIndex: Int
    let point: CGPoint
}

enum AnnotationMutation: Sendable {
    case createMarkup(
        kind: Annotation.Kind,
        selection: PDFMarkupSelection,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    )
    case createNote(
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    )
    case createCaret(
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    )
    case update(
        sourceID: String,
        contents: String,
        author: String,
        color: Annotation.Color,
        modifiedAt: Date
    )
    case move(sourceID: String, rect: CGRect, modifiedAt: Date)
    case delete(sourceID: String)
}

protocol AnnotationWriting: Sendable {
    /// Applies every mutation to one in-memory document and replaces the PDF only
    /// after the complete batch succeeds.
    func perform(_ mutations: [AnnotationMutation], in documentURL: URL) async throws
}

extension AnnotationWriting {
    func createMarkup(
        in documentURL: URL,
        kind: Annotation.Kind,
        selection: PDFMarkupSelection,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    ) async throws {
        try await perform(
            [.createMarkup(
                kind: kind,
                selection: selection,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt
            )],
            in: documentURL
        )
    }

    func createNote(
        in documentURL: URL,
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    ) async throws {
        try await perform(
            [.createNote(
                location: location,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt
            )],
            in: documentURL
        )
    }

    func createCaret(
        in documentURL: URL,
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date
    ) async throws {
        try await perform(
            [.createCaret(
                location: location,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt
            )],
            in: documentURL
        )
    }

    func update(
        in documentURL: URL,
        sourceID: String,
        contents: String,
        author: String,
        color: Annotation.Color,
        modifiedAt: Date
    ) async throws {
        try await perform(
            [.update(
                sourceID: sourceID,
                contents: contents,
                author: author,
                color: color,
                modifiedAt: modifiedAt
            )],
            in: documentURL
        )
    }

    func move(
        in documentURL: URL,
        sourceID: String,
        rect: CGRect,
        modifiedAt: Date
    ) async throws {
        try await perform(
            [.move(sourceID: sourceID, rect: rect, modifiedAt: modifiedAt)],
            in: documentURL
        )
    }

    func delete(
        in documentURL: URL,
        sourceID: String
    ) async throws {
        try await perform([.delete(sourceID: sourceID)], in: documentURL)
    }
}
