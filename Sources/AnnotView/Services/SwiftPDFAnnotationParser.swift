import CoreGraphics
import Foundation

/// Pure-Swift PDF annotation parser with 100% behavioral parity with `MuPDFAnnotationParser`.
/// Reads `/Annots` directly in PDF user space without intermediate coordinate transforms.
struct SwiftPDFAnnotationParser: AnnotationParsing {
    private struct RawAnnotation {
        let sourceID: String?
        let inReplyToSourceID: String?
        let subtype: String
        let bounds: CGRect
        let quadPoints: [CGPoint]
        let contents: String?
        let author: String?
        let creationDate: Date?
        let modificationDate: Date?
        let color: [CGFloat]
        let opacity: CGFloat
        let stateModel: String?
        let state: String?
    }

    func annotations(in documentURL: URL) async throws -> [Annotation] {
        let store = try PDFDocumentStore(url: documentURL)
        return parseAnnotations(in: store)
    }

    func annotations(in data: Data) throws -> [Annotation] {
        let store = try PDFDocumentStore(data: data)
        return parseAnnotations(in: store)
    }

    func parseAnnotations(in store: PDFDocumentStore) -> [Annotation] {
        store.pages().flatMap { page in
            parsePage(page, store: store)
        }
    }

    private func parsePage(_ page: PDFPageRecord, store: PDFDocumentStore) -> [Annotation] {
        guard let annotsArray = store.resolve(page.pageDict["Annots"])?.arrayValue else {
            return []
        }

        let rawAnnotations: [RawAnnotation] = annotsArray.compactMap { entry in
            extractRawAnnotation(entry, store: store)
        }

        let annotationsByID = Dictionary(
            rawAnnotations.compactMap { annotation in
                annotation.sourceID.map { ($0, annotation) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Carets that are the IRT parent of another annotation (Acrobat
        // replacement edits) are merged into that annotation's presentation;
        // skip the standalone duplicate.
        let parentSourceIDs = Set(rawAnnotations.compactMap(\.inReplyToSourceID))

        return rawAnnotations.compactMap { source -> Annotation? in
            guard let kind = Self.mapKind(source.subtype) else { return nil }
            if source.subtype.caseInsensitiveCompare("Caret") == .orderedSame,
               let sourceID = source.sourceID,
               parentSourceIDs.contains(sourceID) {
                return nil
            }

            let acrobatChangeParent = source.inReplyToSourceID
                .flatMap { annotationsByID[$0] }
                .flatMap { $0.subtype.caseInsensitiveCompare("Caret") == .orderedSame ? $0 : nil }

            if (kind == .highlight || kind == .underline || kind == .strikeout),
               source.quadPoints.isEmpty,
               source.bounds.width < 0.5 || source.bounds.height < 0.5
                   || source.bounds.width > 10_000 || source.bounds.height > 10_000 {
                return nil
            }

            return Annotation(
                sourceID: source.sourceID,
                // Acrobat models replacement edits as a Caret parent plus an IRT
                // StrikeOut child. Present them as one user-facing change comment.
                inReplyToSourceID: acrobatChangeParent == nil ? source.inReplyToSourceID : nil,
                statusTargetSourceID: acrobatChangeParent?.sourceID ?? source.sourceID,
                kind: kind,
                pageIndex: page.pageIndex,
                bounds: source.bounds,
                quadPoints: source.quadPoints,
                contents: source.contents?.nilIfEmpty ?? acrobatChangeParent?.contents?.nilIfEmpty,
                author: source.author?.nilIfEmpty ?? acrobatChangeParent?.author?.nilIfEmpty,
                createdDate: source.creationDate
                    ?? acrobatChangeParent?.creationDate
                    ?? source.modificationDate,
                color: Self.mapColor(source.color, opacity: source.opacity, kind: kind),
                status: Self.mapStatus(
                    model: acrobatChangeParent?.stateModel ?? source.stateModel,
                    state: acrobatChangeParent?.state ?? source.state
                )
            )
        }
    }

    private func extractRawAnnotation(
        _ entry: PDFObject,
        store: PDFDocumentStore
    ) -> RawAnnotation? {
        let sourceID: String?
        if case let .indirectRef(objNum, _) = entry, objNum > 0 {
            sourceID = "\(objNum) 0 R"
        } else {
            sourceID = nil
        }

        guard let dict = store.resolve(entry)?.dictValue else {
            return nil
        }
        guard let subtype = store.resolve(dict["Subtype"])?.nameValue else {
            return nil
        }

        let inReplyToSourceID: String?
        if case let .indirectRef(parentNum, _) = dict["IRT"], parentNum > 0 {
            inReplyToSourceID = "\(parentNum) 0 R"
        } else {
            inReplyToSourceID = nil
        }

        let bounds = normalizedRect(from: store.resolve(dict["Rect"]))
        let quadPoints = extractQuadPoints(from: store.resolve(dict["QuadPoints"]), store: store)

        let contents = store.resolve(dict["Contents"])?.textString
        let author = store.resolve(dict["T"])?.textString

        let creationDate = store.resolve(dict["CreationDate"])?.textString.flatMap(PDFDate.parse)
        let modificationDate = store.resolve(dict["M"])?.textString.flatMap(PDFDate.parse)

        let color: [CGFloat]
        if let colorArray = store.resolve(dict["C"])?.arrayValue {
            color = colorArray.compactMap { store.resolve($0)?.realValue }.map { CGFloat($0) }
        } else {
            color = []
        }

        let opacity: CGFloat
        if let caValue = store.resolve(dict["CA"])?.realValue {
            opacity = CGFloat(caValue)
        } else {
            opacity = 1.0
        }

        let stateModel = nameOrString(store.resolve(dict["StateModel"]))
        let state = nameOrString(store.resolve(dict["State"]))

        return RawAnnotation(
            sourceID: sourceID,
            inReplyToSourceID: inReplyToSourceID,
            subtype: subtype,
            bounds: bounds,
            quadPoints: quadPoints,
            contents: contents,
            author: author,
            creationDate: creationDate,
            modificationDate: modificationDate,
            color: color,
            opacity: opacity,
            stateModel: stateModel,
            state: state
        )
    }

    private func normalizedRect(from object: PDFObject?) -> CGRect {
        guard let array = object?.arrayValue, array.count == 4,
              let x0 = array[0].realValue,
              let y0 = array[1].realValue,
              let x1 = array[2].realValue,
              let y1 = array[3].realValue else {
            return .zero
        }
        let minX = min(x0, x1)
        let minY = min(y0, y1)
        let maxX = max(x0, x1)
        let maxY = max(y0, y1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func extractQuadPoints(
        from object: PDFObject?,
        store: PDFDocumentStore
    ) -> [CGPoint] {
        guard let array = object?.arrayValue, array.count >= 8 else {
            return []
        }
        let numbers = array.compactMap { store.resolve($0)?.realValue }
        let quadCount = numbers.count / 8
        guard quadCount > 0 else { return [] }

        var points: [CGPoint] = []
        points.reserveCapacity(quadCount * 4)
        for q in 0..<quadCount {
            let base = q * 8
            for p in 0..<4 {
                points.append(CGPoint(x: numbers[base + p * 2], y: numbers[base + p * 2 + 1]))
            }
        }
        return points
    }

    private func nameOrString(_ object: PDFObject?) -> String? {
        guard let object else { return nil }
        if let name = object.nameValue {
            return name
        }
        return object.textString
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
                red: 1 - min(1, c + k),
                green: 1 - min(1, m + k),
                blue: 1 - min(1, y + k),
                alpha: alpha
            )
        default:
            return kind == .strikeout ? .red : .yellow
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
