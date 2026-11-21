import CoreGraphics
import Foundation

/// Pure-Swift PDF annotation writer using append-only PDF incremental updates.
/// Maintains 100% behavioral parity with `MuPDFAnnotationWriter`.
actor SwiftPDFAnnotationWriter: AnnotationWriting {
    private let storeCache: PDFDocumentStoreCache

    init(storeCache: PDFDocumentStoreCache = .shared) {
        self.storeCache = storeCache
    }

    enum WriterError: LocalizedError {
        case unsupportedKind
        case emptySelection
        case pageIndexOutOfRange(Int)
        case annotationNotFound(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedKind:
                "This annotation type cannot be written."
            case .emptySelection:
                "Select some text before adding text markup."
            case .pageIndexOutOfRange(let pageIndex):
                "Page index \(pageIndex) is out of range."
            case .annotationNotFound(let sourceID):
                "Annotation object \(sourceID) was not found."
            }
        }
    }

    func perform(_ mutations: [AnnotationMutation], in documentURL: URL) async throws {
        guard !mutations.isEmpty else { return }

        let store = try await storeCache.store(for: documentURL)
        let writer = PDFIncrementalWriter(store: store)
        let pages = store.pages()

        for mutation in mutations {
            try apply(mutation, pages: pages, writer: writer)
        }

        let suffix = try writer.saveIncrementally(to: documentURL)
        if !suffix.isEmpty {
            await storeCache.update(appending: suffix, to: store, for: documentURL)
        }
    }

    // MARK: - Mutation Application

    private func apply(
        _ mutation: AnnotationMutation,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        switch mutation {
        case let .createMarkup(kind, selection, contents, author, color, createdAt):
            try applyCreateMarkup(
                kind: kind,
                selection: selection,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt,
                pages: pages,
                writer: writer
            )
        case let .createNote(location, contents, author, color, createdAt):
            try applyCreateNote(
                location: location,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt,
                pages: pages,
                writer: writer
            )
        case let .createCaret(location, contents, author, color, createdAt):
            try applyCreateCaret(
                location: location,
                contents: contents,
                author: author,
                color: color,
                createdAt: createdAt,
                pages: pages,
                writer: writer
            )
        case let .update(sourceID, contents, author, color, modifiedAt):
            try applyUpdate(
                sourceID: sourceID,
                contents: contents,
                author: author,
                color: color,
                modifiedAt: modifiedAt,
                pages: pages,
                writer: writer
            )
        case let .move(sourceID, rect, modifiedAt):
            try applyMove(
                sourceID: sourceID,
                rect: rect,
                modifiedAt: modifiedAt,
                pages: pages,
                writer: writer
            )
        case let .delete(sourceID):
            try applyDelete(sourceID: sourceID, pages: pages, writer: writer)
        }
    }

    private func applyCreateMarkup(
        kind: Annotation.Kind,
        selection: PDFMarkupSelection,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard !selection.isEmpty else {
            throw WriterError.emptySelection
        }
        let subtype: String
        let subject: String
        switch kind {
        case .highlight:
            subtype = "Highlight"
            subject = "Highlight"
        case .underline:
            subtype = "Underline"
            subject = "Underline"
        case .strikeout:
            subtype = "StrikeOut"
            subject = "Strikethrough"
        case .note, .ink, .caret:
            throw WriterError.unsupportedKind
        }

        let nonEmptyPages = selection.pages.filter { !$0.quads.isEmpty }
        let baseName = UUID().uuidString.uppercased()
        let dateStr = PDFDate.format(createdAt)
        let opacity = color.alpha > 0 ? Double(color.alpha) : 1.0
        let apColor = PDFAppearanceGenerator.Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: opacity
        )
        let normAuthor = normalized(author)
        let normContents = normalized(contents)

        for pageSelection in nonEmptyPages {
            guard pageSelection.pageIndex >= 0, pageSelection.pageIndex < pages.count else {
                throw WriterError.pageIndexOutOfRange(pageSelection.pageIndex)
            }
            let page = pages[pageSelection.pageIndex]
            let rect = PDFAppearanceGenerator.boundingRect(for: pageSelection.quads)
            let quadPoints: [PDFObject] = pageSelection.quads.flatMap { quad in
                quad.points.flatMap { [.real(Double($0.x)), .real(Double($0.y))] }
            }

            let nm = nonEmptyPages.count > 1
                ? "\(baseName)-\(pageSelection.pageIndex)"
                : baseName

            var annotDict: [String: PDFObject] = [
                "Type": .name("Annot"),
                "Subtype": .name(subtype),
                "Rect": rectArray(rect),
                "QuadPoints": .array(quadPoints),
                "P": .indirectRef(objNum: page.pageObjNum, genNum: page.pageGenNum),
                "F": .int(4),
                "Subj": .string(PDFTextString.encode(subject)),
                "NM": .string(PDFTextString.encode(nm)),
                "T": .string(PDFTextString.encode(normAuthor)),
                "Contents": .string(PDFTextString.encode(normContents)),
                "C": colorArray(color),
                "CA": .real(opacity),
                "CreationDate": .string(PDFTextString.encode(dateStr)),
                "M": .string(PDFTextString.encode(dateStr)),
            ]

            if let apStream = PDFAppearanceGenerator.markupStream(
                subtype: subtype,
                quads: pageSelection.quads,
                rect: rect,
                color: apColor
            ) {
                let apRef = writer.allocateObject(apStream)
                annotDict["AP"] = .dict(["N": .indirectRef(objNum: apRef.objNum, genNum: apRef.genNum)])
            }

            let annotRef = writer.allocateObject(.dict(annotDict))
            writer.appendAnnot(annotRef, to: page)
        }
    }

    private func applyCreateNote(
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard location.pageIndex >= 0, location.pageIndex < pages.count else {
            throw WriterError.pageIndexOutOfRange(location.pageIndex)
        }
        let page = pages[location.pageIndex]
        let rect = CGRect(
            x: location.point.x - 10,
            y: location.point.y - 10,
            width: 20,
            height: 20
        )
        let dateStr = PDFDate.format(createdAt)
        let opacity = color.alpha > 0 ? Double(color.alpha) : 1.0
        let apColor = PDFAppearanceGenerator.Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: opacity
        )
        let apRef = writer.allocateObject(PDFAppearanceGenerator.noteStream(color: apColor))

        let annotDict: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name("Text"),
            "Rect": rectArray(rect),
            "P": .indirectRef(objNum: page.pageObjNum, genNum: page.pageGenNum),
            "F": .int(28),
            "Name": .name("Comment"),
            "Subj": .string(PDFTextString.encode("Sticky Note")),
            "Open": .bool(false),
            "NM": .string(PDFTextString.encode(UUID().uuidString.uppercased())),
            "T": .string(PDFTextString.encode(normalized(author))),
            "Contents": .string(PDFTextString.encode(normalized(contents))),
            "C": colorArray(color),
            "CA": .real(opacity),
            "CreationDate": .string(PDFTextString.encode(dateStr)),
            "M": .string(PDFTextString.encode(dateStr)),
            "AP": .dict(["N": .indirectRef(objNum: apRef.objNum, genNum: apRef.genNum)]),
        ]

        let annotRef = writer.allocateObject(.dict(annotDict))
        writer.appendAnnot(annotRef, to: page)
    }

    private func applyCreateCaret(
        location: PDFPagePoint,
        contents: String,
        author: String,
        color: Annotation.Color,
        createdAt: Date,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard location.pageIndex >= 0, location.pageIndex < pages.count else {
            throw WriterError.pageIndexOutOfRange(location.pageIndex)
        }
        let page = pages[location.pageIndex]
        let rect = CGRect(
            x: location.point.x - 4.4235,
            y: location.point.y - 3.6045,
            width: 8.847,
            height: 7.209
        )
        let dateStr = PDFDate.format(createdAt)
        let opacity = color.alpha > 0 ? Double(color.alpha) : 1.0
        let apColor = PDFAppearanceGenerator.Color(
            red: Double(color.red),
            green: Double(color.green),
            blue: Double(color.blue),
            opacity: opacity
        )
        let apRef = writer.allocateObject(PDFAppearanceGenerator.caretStream(color: apColor))

        let annotDict: [String: PDFObject] = [
            "Type": .name("Annot"),
            "Subtype": .name("Caret"),
            "Rect": rectArray(rect),
            "P": .indirectRef(objNum: page.pageObjNum, genNum: page.pageGenNum),
            "F": .int(4),
            "Subj": .string(PDFTextString.encode("InsertedText")),
            "NM": .string(PDFTextString.encode(UUID().uuidString.uppercased())),
            "T": .string(PDFTextString.encode(normalized(author))),
            "Contents": .string(PDFTextString.encode(normalized(contents))),
            "C": colorArray(color),
            "CA": .real(opacity),
            "CreationDate": .string(PDFTextString.encode(dateStr)),
            "M": .string(PDFTextString.encode(dateStr)),
            "AP": .dict(["N": .indirectRef(objNum: apRef.objNum, genNum: apRef.genNum)]),
        ]

        let annotRef = writer.allocateObject(.dict(annotDict))
        writer.appendAnnot(annotRef, to: page)
    }

    private func applyUpdate(
        sourceID: String,
        contents: String,
        author: String,
        color: Annotation.Color?,
        modifiedAt: Date,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard let found = findAnnotation(sourceID: sourceID, pages: pages, writer: writer) else {
            throw WriterError.annotationNotFound(sourceID)
        }

        var dict = found.dict
        dict["Contents"] = .string(PDFTextString.encode(normalized(contents)))
        dict["T"] = .string(PDFTextString.encode(normalized(author)))
        dict["M"] = .string(PDFTextString.encode(PDFDate.format(modifiedAt)))

        if let color {
            let existingOpacity = writer.resolve(dict["CA"])?.realValue ?? 1.0
            let opacity = color.alpha > 0 ? Double(color.alpha) : (existingOpacity > 0 ? existingOpacity : 1.0)
            let apMatchesExisting = dict["AP"] != nil && appearanceColorMatches(
                in: dict,
                color: color,
                opacity: opacity,
                writer: writer
            )
            dict["C"] = colorArray(color)
            dict["CA"] = .real(opacity)

            if !apMatchesExisting {
                let apColor = PDFAppearanceGenerator.Color(
                    red: Double(color.red),
                    green: Double(color.green),
                    blue: Double(color.blue),
                    opacity: opacity
                )
                if let apStream = regeneratedAppearance(for: dict, color: apColor, writer: writer) {
                    let apRef = writer.allocateObject(apStream)
                    dict["AP"] = .dict(["N": .indirectRef(objNum: apRef.objNum, genNum: apRef.genNum)])
                }
            }
        }

        writer.setObject(.dict(dict), number: found.objNum, generation: found.genNum)
    }

    private func applyMove(
        sourceID: String,
        rect: CGRect,
        modifiedAt: Date,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard let found = findAnnotation(sourceID: sourceID, pages: pages, writer: writer) else {
            throw WriterError.annotationNotFound(sourceID)
        }

        var dict = found.dict
        dict["Rect"] = rectArray(rect)
        dict["M"] = .string(PDFTextString.encode(PDFDate.format(modifiedAt)))
        writer.setObject(.dict(dict), number: found.objNum, generation: found.genNum)
    }

    private func applyDelete(
        sourceID: String,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) throws {
        guard let found = findAnnotation(sourceID: sourceID, pages: pages, writer: writer) else {
            throw WriterError.annotationNotFound(sourceID)
        }
        writer.removeAnnot(objNum: found.objNum, from: found.page)
    }

    // MARK: - Lookup & Appearance Helpers

    private struct FoundAnnotation {
        let page: PDFPageRecord
        let objNum: Int
        let genNum: Int
        let dict: [String: PDFObject]
    }

    private func findAnnotation(
        sourceID: String,
        pages: [PDFPageRecord],
        writer: PDFIncrementalWriter
    ) -> FoundAnnotation? {
        guard let targetObjNum = Self.parseObjectNumber(from: sourceID) else {
            return nil
        }
        for page in pages {
            for entry in writer.pageAnnots(for: page) {
                if case let .indirectRef(objNum, genNum) = entry, objNum == targetObjNum {
                    if let dict = writer.currentObject(number: objNum, generation: genNum)?.dictValue {
                        return FoundAnnotation(page: page, objNum: objNum, genNum: genNum, dict: dict)
                    }
                }
            }
        }
        return nil
    }

    private func appearanceColorMatches(
        in dict: [String: PDFObject],
        color: Annotation.Color,
        opacity: Double,
        writer: PDFIncrementalWriter
    ) -> Bool {
        guard let apDict = writer.resolve(dict["AP"])?.dictValue,
              apDict["N"] != nil,
              let colorComponents = writer.resolve(dict["C"])?.arrayValue,
              colorComponents.count == 3,
              let r = writer.resolve(colorComponents[0])?.realValue,
              let g = writer.resolve(colorComponents[1])?.realValue,
              let b = writer.resolve(colorComponents[2])?.realValue else {
            return false
        }
        let existingOpacity = writer.resolve(dict["CA"])?.realValue ?? 1.0
        let tolerance = 1e-4
        return abs(r - Double(color.red)) < tolerance
            && abs(g - Double(color.green)) < tolerance
            && abs(b - Double(color.blue)) < tolerance
            && abs(existingOpacity - opacity) < tolerance
    }

    private func regeneratedAppearance(
        for dict: [String: PDFObject],
        color: PDFAppearanceGenerator.Color,
        writer: PDFIncrementalWriter
    ) -> PDFObject? {
        guard let subtype = writer.resolve(dict["Subtype"])?.nameValue else {
            return nil
        }
        switch subtype {
        case "Highlight", "Underline", "StrikeOut":
            let quads = extractQuads(from: writer.resolve(dict["QuadPoints"]), writer: writer)
            guard !quads.isEmpty else { return nil }
            let rect = writer.resolve(dict["Rect"])?.cgRectValue
                ?? PDFAppearanceGenerator.boundingRect(for: quads)
            return PDFAppearanceGenerator.markupStream(
                subtype: subtype,
                quads: quads,
                rect: rect,
                color: color
            )
        case "Text":
            return PDFAppearanceGenerator.noteStream(color: color)
        case "Caret":
            return PDFAppearanceGenerator.caretStream(color: color)
        default:
            return nil
        }
    }

    private func extractQuads(
        from object: PDFObject?,
        writer: PDFIncrementalWriter
    ) -> [PDFMarkupQuad] {
        guard let array = object?.arrayValue, array.count >= 8 else {
            return []
        }
        let nums = array.compactMap { writer.resolve($0)?.realValue }
        let count = nums.count / 8
        var quads: [PDFMarkupQuad] = []
        quads.reserveCapacity(count)
        for i in 0..<count {
            let b = i * 8
            quads.append(
                PDFMarkupQuad(
                    topLeft: CGPoint(x: nums[b], y: nums[b + 1]),
                    topRight: CGPoint(x: nums[b + 2], y: nums[b + 3]),
                    bottomLeft: CGPoint(x: nums[b + 4], y: nums[b + 5]),
                    bottomRight: CGPoint(x: nums[b + 6], y: nums[b + 7])
                )
            )
        }
        return quads
    }

    static func parseObjectNumber(from sourceID: String) -> Int? {
        let trimmed = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstToken = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        guard let num = Int(firstToken), num > 0 else { return nil }
        return num
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rectArray(_ rect: CGRect) -> PDFObject {
        .array([
            .real(Double(rect.minX)),
            .real(Double(rect.minY)),
            .real(Double(rect.maxX)),
            .real(Double(rect.maxY)),
        ])
    }

    private func colorArray(_ color: Annotation.Color) -> PDFObject {
        .array([
            .real(Double(color.red)),
            .real(Double(color.green)),
            .real(Double(color.blue)),
        ])
    }
}
