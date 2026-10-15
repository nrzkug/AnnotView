import AppKit
import PDFKit
import Testing
@testable import AnnotView

struct AnnotationCreationTests {
    @Test func editingColorPreservesAnnotationOpacity() {
        let original = Annotation.Color.yellow
        let edited = original.replacingRGB(red: 0.2, green: 0.4, blue: 0.6)

        #expect(edited.red == 0.2)
        #expect(edited.green == 0.4)
        #expect(edited.blue == 0.6)
        #expect(edited.alpha == original.alpha)
    }

    @Test @MainActor
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

    @Test @MainActor
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

    @Test @MainActor
    func updatesMultipleAnnotationStatusesInOneSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewBatchStatusTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("batch-status.pdf")
        try writeBlankPDF(to: documentURL)
        let writer = MuPDFAnnotationWriter()
        for x in [120.0, 220.0] {
            try await writer.createNote(
                in: documentURL,
                location: PDFPagePoint(pageIndex: 0, point: CGPoint(x: x, y: 300)),
                contents: "Review \(Int(x))",
                author: "Reviewer",
                color: .yellow,
                createdAt: Date()
            )
        }

        let parser = MuPDFAnnotationParser()
        let annotations = try await parser.annotations(in: documentURL)
        #expect(annotations.count == 2)
        let updates = try annotations.map {
            AnnotationStatusUpdate(
                sourceID: try #require($0.statusTargetSourceID),
                status: .completed
            )
        }
        try await MuPDFAnnotationStatusWriter().updateStatuses(
            in: documentURL,
            updates: updates
        )

        let updated = try await parser.annotations(in: documentURL)
        #expect(updated.count == 2)
        #expect(updated.allSatisfy { $0.status == .completed })
    }

    @Test @MainActor
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

    @Test @MainActor
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

    @Test @MainActor
    func testAnnotateTableInUserPDF() async throws {
        let pdfPath = "/Users/liguang/Downloads/基于生成式大模型的卷烟市场趋势洞察与决策项目的研究方向.pdf"
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TableTest-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: pdfPath), to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let manager = PDFDocumentManager()
        await manager.open(url: tempURL)
        
        guard let doc = manager.document, doc.page(at: 0) != nil else {
            Issue.record("Failed to get page 0")
            return
        }
        
        // Find text inside table
        let targetText = "市场洞察"
        let matches = doc.findString(targetText, withOptions: [])
        #expect(!matches.isEmpty)
        guard let selection = matches.first else { return }
        
        // Build markup selection as AnnotationPDFView does
        var quadsByPage: [Int: [PDFMarkupQuad]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0.01, bounds.height > 0.01 else { continue }
                let pageIndex = doc.index(for: page)
                quadsByPage[pageIndex, default: []].append(
                    PDFMarkupQuad(
                        topLeft: CGPoint(x: bounds.minX, y: bounds.maxY),
                        topRight: CGPoint(x: bounds.maxX, y: bounds.maxY),
                        bottomLeft: CGPoint(x: bounds.minX, y: bounds.minY),
                        bottomRight: CGPoint(x: bounds.maxX, y: bounds.minY)
                    )
                )
            }
        }
        let pages = quadsByPage.keys.sorted().map {
            PDFMarkupPageSelection(pageIndex: $0, quads: quadsByPage[$0] ?? [])
        }
        let markupSelection = PDFMarkupSelection(pages: pages, selectedText: selection.string ?? "")
        
        let annotation = await manager.createMarkup(kind: .highlight, selection: markupSelection)
        let created = try #require(annotation)
        #expect(created.kind == .highlight)
        #expect(created.pageIndex == 0)
        #expect(manager.annotations.contains { $0.id == created.id })
    }

    @Test @MainActor
    func testAnnotationPDFViewInteraction() async throws {
        let pdfPath = "/Users/liguang/Downloads/基于生成式大模型的卷烟市场趋势洞察与决策项目的研究方向.pdf"
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: pdfPath)))
        let view = AnnotationPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = doc
        view.annotationTool = .highlight
        
        var receivedKind: Annotation.Kind?
        var receivedSelection: PDFMarkupSelection?
        view.onCreateMarkupRequest = { kind, sel in
            receivedKind = kind
            receivedSelection = sel
        }
        
        // Find text in table
        let matches = doc.findString("智能问答", withOptions: [])
        let selection = try #require(matches.first)
        view.setCurrentSelection(selection, animate: false)
        
        #expect(view.currentSelection != nil)
        let markup = view.markupSelection()
        #expect(markup != nil)
        
        let upEvent = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )
        view.mouseUp(with: upEvent)
        #expect(receivedKind == .highlight)
        #expect(receivedSelection?.selectedText == "智能问答")
        #expect(view.currentSelection == nil)
    }

    @Test @MainActor
    func testSwitchToolToHighlightAnnotatesSelection() async throws {
        let pdfPath = "/Users/liguang/Downloads/基于生成式大模型的卷烟市场趋势洞察与决策项目的研究方向.pdf"
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: pdfPath)))
        let view = AnnotationPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = doc
        view.annotationTool = .selection
        
        var receivedKind: Annotation.Kind?
        var receivedSelection: PDFMarkupSelection?
        view.onCreateMarkupRequest = { kind, sel in
            receivedKind = kind
            receivedSelection = sel
        }
        
        // Find text inside table
        let matches = doc.findString("市场洞察", withOptions: [])
        let selection = try #require(matches.first)
        view.setCurrentSelection(selection, animate: false)
        #expect(view.currentSelection != nil)
        
        // User switches tool to highlight (e.g. clicks highlight in toolbar)
        view.annotationTool = .highlight
        
        #expect(receivedKind == .highlight)
        #expect(receivedSelection?.selectedText.contains("市场洞察") == true)
        #expect(view.currentSelection == nil)
    }

    @Test @MainActor
    func testShortcutActionsAnnotateTableSelection() async throws {
        let pdfPath = "/Users/liguang/Downloads/基于生成式大模型的卷烟市场趋势洞察与决策项目的研究方向.pdf"
        guard FileManager.default.fileExists(atPath: pdfPath) else { return }
        
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: pdfPath)))
        let view = AnnotationPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000))
        view.document = doc
        view.annotationTool = .selection
        
        var receivedKind: Annotation.Kind?
        var receivedSelection: PDFMarkupSelection?
        view.onCreateMarkupRequest = { kind, sel in
            receivedKind = kind
            receivedSelection = sel
        }
        
        // 1. Highlight shortcut (Ctrl+Cmd+H) with text selected
        let match1 = try #require(doc.findString("市场洞察", withOptions: []).first)
        view.setCurrentSelection(match1, animate: false)
        view.highlightSelection(nil)
        #expect(receivedKind == .highlight)
        #expect(receivedSelection?.selectedText.contains("市场洞察") == true)
        #expect(view.currentSelection == nil)
        
        // 2. Underline shortcut (Ctrl+Cmd+U) with text selected
        let match2 = try #require(doc.findString("智能问答", withOptions: []).first)
        view.setCurrentSelection(match2, animate: false)
        view.underlineSelection(nil)
        #expect(receivedKind == .underline)
        #expect(receivedSelection?.selectedText.contains("智能问答") == true)
        #expect(view.currentSelection == nil)
        
        // 3. Strikethrough shortcut (Ctrl+Cmd+S) with text selected
        let match3 = try #require(doc.findString("文档创作", withOptions: []).first)
        view.setCurrentSelection(match3, animate: false)
        view.strikeoutSelection(nil)
        #expect(receivedKind == .strikeout)
        #expect(receivedSelection?.selectedText.contains("文档创作") == true)
        #expect(view.currentSelection == nil)
        
        // 4. Highlight shortcut with NO selection toggles tool
        view.annotationTool = .selection
        view.highlightSelection(nil)
        #expect(view.annotationTool == .highlight)
    }

    @Test @MainActor
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
}
