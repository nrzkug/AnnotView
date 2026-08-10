import AppKit
import PDFKit
import Testing
@testable import AnnotView

private let mutoolIsAvailable = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/mutool")
    || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/mutool")

struct AnnotationCreationTests {
    @Test func editingColorPreservesAnnotationOpacity() {
        let original = Annotation.Color.yellow
        let edited = original.replacingRGB(red: 0.2, green: 0.4, blue: 0.6)

        #expect(edited.red == 0.2)
        #expect(edited.green == 0.4)
        #expect(edited.blue == 0.6)
        #expect(edited.alpha == original.alpha)
    }

    @Test(.enabled(if: mutoolIsAvailable, "Requires the mutool executable")) @MainActor
    func writesAndReopensAcrobatCompatibleHighlight() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewCreationTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("highlight.pdf")
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: documentURL))

        let quad = PDFMarkupQuad(
            topLeft: CGPoint(x: 72, y: 700),
            topRight: CGPoint(x: 260, y: 700),
            bottomLeft: CGPoint(x: 72, y: 682),
            bottomRight: CGPoint(x: 260, y: 682)
        )
        let selection = PDFMarkupSelection(
            pages: [PDFMarkupPageSelection(pageIndex: 0, quads: [quad])],
            selectedText: "Selected text"
        )
        let createdAt = try #require(
            ISO8601DateFormatter().date(from: "2026-08-09T15:20:00Z")
        )

        let writer = MuPDFAnnotationWriter()
        try await writer.createMarkup(
            in: documentURL,
            kind: .highlight,
            selection: selection,
            contents: "Review comment",
            author: "Reviewer",
            color: .yellow,
            createdAt: createdAt
        )

        let annotation = try #require(
            try await MuPDFAnnotationParser().annotations(in: documentURL).first
        )
        #expect(annotation.sourceID != nil)
        #expect(annotation.kind == .highlight)
        #expect(annotation.pageIndex == 0)
        #expect(annotation.quadPoints == quad.points)
        #expect(annotation.contents == "Review comment")
        #expect(annotation.author == "Reviewer")
        #expect(annotation.createdDate == createdAt)
        #expect(abs(annotation.color.red - 1) < 0.0001)
        #expect(abs(annotation.color.green - 0.819608) < 0.0001)
        #expect(abs(annotation.color.blue) < 0.0001)
        #expect(abs(annotation.color.alpha - Annotation.Color.yellow.alpha) < 0.0001)

        let sourceID = try #require(annotation.sourceID)
        try await writer.update(
            in: documentURL,
            sourceID: sourceID,
            contents: "Updated review comment",
            author: "Second Reviewer",
            color: .green,
            modifiedAt: createdAt.addingTimeInterval(60)
        )
        let updated = try #require(
            try await MuPDFAnnotationParser().annotations(in: documentURL).first
        )
        #expect(updated.sourceID == sourceID)
        #expect(updated.contents == "Updated review comment")
        #expect(updated.author == "Second Reviewer")
        #expect(abs(updated.color.green - Annotation.Color.green.green) < 0.0001)

        try await writer.delete(in: documentURL, sourceID: sourceID)
        #expect(try await MuPDFAnnotationParser().annotations(in: documentURL).isEmpty)
    }

    @Test(.enabled(if: mutoolIsAvailable, "Requires the mutool executable")) @MainActor
    func createsStickyNoteAndTextMarkupKinds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewKindsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("kinds.pdf")
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: documentURL))

        let writer = MuPDFAnnotationWriter()
        let quad = PDFMarkupQuad(
            topLeft: CGPoint(x: 72, y: 700), topRight: CGPoint(x: 260, y: 700),
            bottomLeft: CGPoint(x: 72, y: 682), bottomRight: CGPoint(x: 260, y: 682)
        )
        let selection = PDFMarkupSelection(
            pages: [.init(pageIndex: 0, quads: [quad])],
            selectedText: "Selected text"
        )
        try await writer.perform(
            [
                .createMarkup(
                    kind: .underline, selection: selection, contents: "Underline",
                    author: "Reviewer", color: .green, createdAt: Date()
                ),
                .createMarkup(
                    kind: .strikeout, selection: selection, contents: "Strikeout",
                    author: "Reviewer", color: .red, createdAt: Date()
                ),
                .createNote(
                    location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 320, y: 650)),
                    contents: "Sticky note", author: "Reviewer", color: .yellow,
                    createdAt: Date()
                ),
                .createCaret(
                    location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 380, y: 600)),
                    contents: "Inserted sentence here", author: "Reviewer", color: .red,
                    createdAt: Date()
                )
            ],
            in: documentURL
        )

        let annotations = try await MuPDFAnnotationParser().annotations(in: documentURL)
        #expect(annotations.count == 4)
        #expect(annotations.contains { $0.kind == .underline && $0.contents == "Underline" })
        #expect(annotations.contains { $0.kind == .strikeout && $0.contents == "Strikeout" })
        #expect(annotations.contains { $0.kind == .note && $0.contents == "Sticky note" })
        let caret = try #require(annotations.first { $0.kind == .caret })
        #expect(caret.contents == "Inserted sentence here")
        #expect(caret.author == "Reviewer")
        #expect(caret.bounds.width > 0 && caret.bounds.height > 0)
    }

    @Test(.enabled(if: mutoolIsAvailable, "Requires the mutool executable")) @MainActor
    func rejectsAnEntireBatchWhenOneMutationFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewAtomicBatchTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("atomic.pdf")
        try writeBlankPDF(to: documentURL)
        let writer = MuPDFAnnotationWriter()
        var didFail = false
        do {
            try await writer.perform(
                [
                    .createNote(
                        location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 100, y: 100)),
                        contents: "Must be rolled back", author: "Reviewer", color: .yellow,
                        createdAt: Date()
                    ),
                    .delete(sourceID: "99999 0 R")
                ],
                in: documentURL
            )
        } catch {
            didFail = true
        }

        #expect(didFail)
        #expect(try await MuPDFAnnotationParser().annotations(in: documentURL).isEmpty)
    }

    @Test(.enabled(if: mutoolIsAvailable, "Requires the mutool executable")) @MainActor
    func supportsMultiStepAnnotationUndoAndRedo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewHistoryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("history.pdf")
        try writeBlankPDF(to: documentURL)
        let manager = PDFDocumentManager()
        await manager.open(url: documentURL)

        let created = await manager.createNote(
            at: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 120, y: 160))
        )
        _ = try #require(created)
        #expect(manager.annotations.count == 1)
        #expect(manager.canUndoAnnotationChange)

        await manager.undoAnnotationChange()
        #expect(manager.annotations.isEmpty)
        #expect(manager.canRedoAnnotationChange)

        await manager.redoAnnotationChange()
        let recreated = try #require(manager.annotations.first)
        #expect(recreated.contents?.isEmpty != false)

        let saved = await manager.updateAnnotation(
            recreated,
            contents: "Edited comment",
            color: .green
        )
        #expect(saved)
        #expect(manager.annotations.first?.contents == "Edited comment")

        await manager.undoAnnotationChange()
        #expect(manager.annotations.first?.contents?.isEmpty != false)
        await manager.redoAnnotationChange()
        #expect(manager.annotations.first?.contents == "Edited comment")

        let edited = try #require(manager.annotations.first)
        #expect(await manager.deleteAnnotation(edited))
        #expect(manager.annotations.isEmpty)
        await manager.undoAnnotationChange()
        #expect(manager.annotations.count == 1)
        await manager.redoAnnotationChange()
        #expect(manager.annotations.isEmpty)
    }

    @MainActor
    private func writeBlankPDF(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: url))
    }
}

    @Test(.enabled(if: mutoolIsAvailable, "Requires the mutool executable")) @MainActor
    func movesAnnotationsToNewRects() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewMoveTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("move.pdf")
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        #expect(document.write(to: documentURL))

        let writer = MuPDFAnnotationWriter()
        let parser = MuPDFAnnotationParser()

        try await writer.createNote(
            in: documentURL,
            location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 300, y: 500)),
            contents: "note", author: "Reviewer", color: .yellow, createdAt: Date()
        )
        try await writer.createCaret(
            in: documentURL,
            location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 200, y: 600)),
            contents: "caret", author: "Reviewer", color: .red, createdAt: Date()
        )
        let note = try #require(
            (try await parser.annotations(in: documentURL)).first { $0.kind == .note }
        )
        let caret = try #require(
            (try await parser.annotations(in: documentURL)).first { $0.kind == .caret }
        )

        // Move both, keeping each annotation's own size (like a drag). The
        // caret must keep Acrobat's compact 8.85x7.2 geometry.
        try await writer.move(
            in: documentURL,
            sourceID: try #require(note.sourceID),
            rect: CGRect(x: 500, y: 300, width: 20, height: 20),
            modifiedAt: Date()
        )
        try await writer.move(
            in: documentURL,
            sourceID: try #require(caret.sourceID),
            rect: CGRect(x: 450, y: 250, width: 8.847, height: 7.209),
            modifiedAt: Date()
        )

        let movedNote = try #require(
            (try await parser.annotations(in: documentURL)).first { $0.kind == .note }
        )
        let movedCaret = try #require(
            (try await parser.annotations(in: documentURL)).first { $0.kind == .caret }
        )
        #expect(abs(movedNote.bounds.minX - 500) < 0.1)
        #expect(abs(movedNote.bounds.minY - 300) < 0.1)
        #expect(abs(movedNote.bounds.width - 20) < 0.1)
        #expect(abs(movedNote.bounds.height - 20) < 0.1)
        #expect(abs(movedCaret.bounds.width - 8.85) < 0.1)
        #expect(abs(movedCaret.bounds.height - 7.21) < 0.1)
        #expect(abs(movedCaret.bounds.midX - 454.4) < 0.1)
    }
