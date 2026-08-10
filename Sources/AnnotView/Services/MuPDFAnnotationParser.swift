import CoreGraphics
import Foundation

struct MuPDFAnnotationParser: AnnotationParsing {
    enum ParserError: LocalizedError {
        case executableNotFound
        case scriptNotFound
        case processFailed(status: Int32, message: String)
        case malformedTransform(pageIndex: Int)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                "MuPDF's mutool executable was not found. Install MuPDF with Homebrew or bundle mutool with the app."
            case .scriptNotFound:
                "The bundled MuPDF annotation script is missing."
            case .processFailed(let status, let message):
                "MuPDF annotation parsing failed (status \(status)): \(message)"
            case .malformedTransform(let pageIndex):
                "MuPDF returned an invalid coordinate transform for page \(pageIndex + 1)."
            }
        }
    }

    private struct Payload: Decodable {
        let version: Int
        let pages: [PagePayload]
    }

    private struct PagePayload: Decodable {
        let pageIndex: Int
        let pageTransform: [CGFloat]
        let annotations: [AnnotationPayload]
    }

    private struct AnnotationPayload: Decodable {
        let sourceID: String?
        let inReplyToSourceID: String?
        let type: String
        let bounds: [CGFloat]
        let quadPoints: [[CGFloat]]
        let contents: String?
        let author: String?
        let subject: String?
        let creationDate: String?
        let modificationDate: String?
        let color: [CGFloat]
        let opacity: CGFloat
        let stateModel: String?
        let state: String?
    }

    private let tool: MuPDFTool
    private let scriptURL: URL?

    init(executableURL: URL? = nil, scriptURL: URL? = nil) {
        tool = MuPDFTool(executableURL: executableURL)
        self.scriptURL = scriptURL
    }

    func annotations(in documentURL: URL) async throws -> [Annotation] {
        let script = try scriptURL ?? Self.findScript()
        let data: Data
        do {
            data = try await tool.run(
                script: script,
                arguments: [documentURL.path],
                capturesOutput: true
            )
        } catch MuPDFTool.ToolError.executableNotFound {
            throw ParserError.executableNotFound
        } catch MuPDFTool.ToolError.processFailed(let status, let message) {
            throw ParserError.processFailed(status: status, message: message)
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [Annotation] {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1 else { return [] }
        return try payload.pages.flatMap(Self.mapPage)
    }

    private static func findScript() throws -> URL {
        let url = MuPDFTool.bundledScript(named: "annotations")
        guard let url else {
            throw ParserError.scriptNotFound
        }
        return url
    }

    private static func mapPage(_ page: PagePayload) throws -> [Annotation] {
        guard page.pageTransform.count == 6 else {
            throw ParserError.malformedTransform(pageIndex: page.pageIndex)
        }
        let values = page.pageTransform
        let transform = CGAffineTransform(
            a: values[0], b: values[1], c: values[2],
            d: values[3], tx: values[4], ty: values[5]
        )

        let annotationsByID = Dictionary(
            uniqueKeysWithValues: page.annotations.compactMap { annotation in
                annotation.sourceID.map { ($0, annotation) }
            }
        )
        // Carets that are the IRT parent of another annotation (Acrobat
        // replacement edits) are already merged into that annotation's
        // presentation below; skip the standalone duplicate.
        let parentSourceIDs = Set(page.annotations.compactMap(\.inReplyToSourceID))

        return page.annotations.compactMap { source -> Annotation? in
            guard let kind = mapKind(source.type) else { return nil }
            if source.type.caseInsensitiveCompare("Caret") == .orderedSame,
               let sourceID = source.sourceID,
               parentSourceIDs.contains(sourceID) {
                return nil
            }
            let acrobatChangeParent = source.inReplyToSourceID
                .flatMap { annotationsByID[$0] }
                .flatMap { $0.type.caseInsensitiveCompare("Caret") == .orderedSame ? $0 : nil }
            let points = source.quadPoints.flatMap { quad -> [CGPoint] in
                guard quad.count >= 2 else { return [] }
                return stride(from: 0, to: quad.count - 1, by: 2).map { index in
                    return CGPoint(x: quad[index], y: quad[index + 1]).applying(transform)
                }
            }
            return Annotation(
                sourceID: source.sourceID,
                // Acrobat models replacement edits as a Caret parent plus an IRT
                // StrikeOut child. Present them as one user-facing change comment.
                inReplyToSourceID: acrobatChangeParent == nil ? source.inReplyToSourceID : nil,
                statusTargetSourceID: acrobatChangeParent?.sourceID ?? source.sourceID,
                kind: kind,
                pageIndex: page.pageIndex,
                bounds: transformedBounds(source.bounds, using: transform),
                quadPoints: points,
                contents: source.contents?.nilIfEmpty ?? acrobatChangeParent?.contents?.nilIfEmpty,
                author: source.author?.nilIfEmpty ?? acrobatChangeParent?.author?.nilIfEmpty,
                createdDate: parseDate(source.creationDate)
                    ?? parseDate(acrobatChangeParent?.creationDate)
                    ?? parseDate(source.modificationDate),
                color: mapColor(source.color, opacity: source.opacity, kind: kind),
                status: mapStatus(
                    model: acrobatChangeParent?.stateModel ?? source.stateModel,
                    state: acrobatChangeParent?.state ?? source.state
                )
            )
        }
    }

    private static func mapStatus(model: String?, state: String?) -> Annotation.Status {
        let value = state?.lowercased()
        return switch (model?.lowercased(), value) {
        case ("marked", "marked"): .marked
        case ("marked", "unmarked"): .unmarked
        case (_, "accepted"): .accepted
        case (_, "rejected"): .rejected
        case (_, "cancelled"): .cancelled
        case (_, "completed"): .completed
        default: .none
        }
    }

    private static func mapKind(_ value: String) -> Annotation.Kind? {
        switch value.lowercased() {
        case "highlight": .highlight
        case "underline": .underline
        case "strikeout": .strikeout
        case "text": .note
        case "ink": .ink
        case "caret": .caret
        default: nil
        }
    }

    private static func transformedBounds(_ values: [CGFloat], using transform: CGAffineTransform) -> CGRect {
        guard values.count == 4 else { return .zero }
        let corners = [
            CGPoint(x: values[0], y: values[1]), CGPoint(x: values[2], y: values[1]),
            CGPoint(x: values[0], y: values[3]), CGPoint(x: values[2], y: values[3])
        ].map { $0.applying(transform) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }

    private static func mapColor(
        _ components: [CGFloat],
        opacity: CGFloat,
        kind: Annotation.Kind
    ) -> Annotation.Color {
        let alpha = max(0, min(1, opacity))
        switch components.count {
        case 1:
            return .init(red: components[0], green: components[0], blue: components[0], alpha: alpha)
        case 3:
            return .init(red: components[0], green: components[1], blue: components[2], alpha: alpha)
        case 4:
            let c = components[0], m = components[1], y = components[2], k = components[3]
            return .init(
                red: 1 - min(1, c + k), green: 1 - min(1, m + k),
                blue: 1 - min(1, y + k), alpha: alpha
            )
        default:
            return kind == .strikeout ? .red : .yellow
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
