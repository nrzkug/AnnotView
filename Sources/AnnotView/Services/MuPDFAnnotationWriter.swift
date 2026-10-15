import Foundation

actor MuPDFAnnotationWriter: AnnotationWriting {
    enum WriterError: LocalizedError {
        case unsupportedKind
        case emptySelection

        var errorDescription: String? {
            switch self {
            case .unsupportedKind:
                "This annotation type cannot be written."
            case .emptySelection:
                "Select some text before adding text markup."
            }
        }
    }

    private struct Payload: Encodable {
        let version = 2
        let operations: [OperationPayload]
    }

    private struct OperationPayload: Encodable {
        let operation: String
        var sourceID: String?
        var subtype: String?
        var name: String?
        var author: String?
        var contents: String?
        var timestamp: String?
        var color: [Double]?
        var opacity: Double?
        var pages: [PagePayload]?
        var location: LocationPayload?
        var rect: [Double]?
    }

    private struct PagePayload: Encodable {
        let pageIndex: Int
        let quads: [[Double]]
    }

    private struct LocationPayload: Encodable {
        let pageIndex: Int
        let point: [Double]
    }

    func perform(_ mutations: [AnnotationMutation], in documentURL: URL) async throws {
        guard !mutations.isEmpty else { return }
        let operations = try mutations.map(operationPayload)
        try await write(Payload(operations: operations), to: documentURL)
    }

    private func write(_ payload: Payload, to documentURL: URL) async throws {
        let payloadJSON = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try MuPDFBridge.withTemporaryOutput(named: "annotated.pdf") { outputURL in
            try MuPDFBridge.writeAnnotations(
                from: documentURL, to: outputURL, operationsJSON: payloadJSON
            )
            try MuPDFBridge.replaceAtomically(documentURL, with: outputURL, action: "save annotations")
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func operationPayload(for mutation: AnnotationMutation) throws -> OperationPayload {
        switch mutation {
        case let .createMarkup(kind, selection, contents, author, color, createdAt):
            guard !selection.isEmpty else { throw WriterError.emptySelection }
            let subtype = switch kind {
            case .highlight: "Highlight"
            case .underline: "Underline"
            case .strikeout: "StrikeOut"
            case .note, .ink, .caret: throw WriterError.unsupportedKind
            }
            let pages = selection.pages.compactMap { page -> PagePayload? in
                let quads = page.quads.map { quad in
                    quad.points.flatMap { [Double($0.x), Double($0.y)] }
                }
                return quads.isEmpty ? nil : PagePayload(pageIndex: page.pageIndex, quads: quads)
            }
            return OperationPayload(
                operation: "createMarkup",
                subtype: subtype,
                name: UUID().uuidString.uppercased(),
                author: normalized(author),
                contents: normalized(contents),
                timestamp: timestamp(createdAt),
                color: color.components,
                opacity: Double(color.alpha),
                pages: pages
            )
        case let .createNote(location, contents, author, color, createdAt):
            return OperationPayload(
                operation: "createNote",
                name: UUID().uuidString.uppercased(),
                author: normalized(author),
                contents: normalized(contents),
                timestamp: timestamp(createdAt),
                color: color.components,
                opacity: Double(color.alpha),
                location: LocationPayload(
                    pageIndex: location.pageIndex,
                    point: [Double(location.point.x), Double(location.point.y)]
                )
            )
        case let .createCaret(location, contents, author, color, createdAt):
            return OperationPayload(
                operation: "createCaret",
                name: UUID().uuidString.uppercased(),
                author: normalized(author),
                contents: normalized(contents),
                timestamp: timestamp(createdAt),
                color: color.components,
                opacity: Double(color.alpha),
                location: LocationPayload(
                    pageIndex: location.pageIndex,
                    point: [Double(location.point.x), Double(location.point.y)]
                )
            )
        case let .update(sourceID, contents, author, color, modifiedAt):
            return OperationPayload(
                operation: "update",
                sourceID: sourceID,
                author: normalized(author),
                contents: normalized(contents),
                timestamp: timestamp(modifiedAt),
                color: color.components,
                opacity: Double(color.alpha)
            )
        case let .delete(sourceID):
            return OperationPayload(operation: "delete", sourceID: sourceID)
        case let .move(sourceID, rect, modifiedAt):
            return OperationPayload(
                operation: "move",
                sourceID: sourceID,
                timestamp: timestamp(modifiedAt),
                rect: [Double(rect.minX), Double(rect.minY), Double(rect.maxX), Double(rect.maxY)]
            )
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension Annotation.Color {
    var components: [Double] {
        [Double(red), Double(green), Double(blue)]
    }
}
