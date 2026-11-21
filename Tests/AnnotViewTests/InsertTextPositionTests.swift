import AppKit
import PDFKit
import Testing
@testable import AnnotView

struct InsertTextPositionTests {
    @Test @MainActor
    func savedCaretKeepsPDFPageCoordinates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InsertTextPosition-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("positions.pdf")
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        for rotation in [0, 90, 180, 270] {
            let page = try #require(PDFPage(image: image))
            page.rotation = rotation
            page.setBounds(CGRect(x: 20, y: 30, width: 560, height: 720), for: .cropBox)
            document.insert(page, at: document.pageCount)
        }
        #expect(document.write(to: url))
        let points = [CGPoint(x: 120, y: 680), CGPoint(x: 350, y: 150)]
        let writer = SwiftPDFAnnotationWriter()
        for pageIndex in 0..<4 {
            for point in points {
                try await writer.createCaret(
                    in: url, location: PDFPagePoint(pageIndex: pageIndex, point: point),
                    contents: "\(point.y)", author: "Test", color: .red, createdAt: Date()
                )
            }
        }
        let annotations = try await SwiftPDFAnnotationParser().annotations(in: url)
        let reopened = try #require(PDFDocument(url: url))
        for pageIndex in 0..<4 {
            for point in points {
                let annotation = try #require(annotations.first {
                    $0.pageIndex == pageIndex && $0.contents == "\(point.y)"
                })
                #expect(abs(annotation.bounds.midX - point.x) < 0.01)
                #expect(abs(annotation.bounds.midY - point.y) < 0.01)
                let native = try #require(reopened.page(at: pageIndex)?.annotations.first {
                    $0.contents == "\(point.y)"
                })
                #expect(abs(native.bounds.midX - point.x) < 0.01)
                #expect(abs(native.bounds.midY - point.y) < 0.01)
            }
        }
    }

    @Test @MainActor
    func insertionPointSnapsWordGapsToBaselineAndIgnoresBlankSpace() throws {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        textView.string = "Alpha     beta gamma"
        textView.font = .systemFont(ofSize: 18)
        let document = try #require(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        let page = try #require(document.page(at: 0))
        let alpha = try #require(document.findString("Alpha", withOptions: []).first).bounds(for: page)
        let beta = try #require(document.findString("beta", withOptions: []).first).bounds(for: page)

        let view = AnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.document = document
        view.layoutDocumentView()

        let textClick = CGPoint(x: alpha.midX, y: alpha.midY + 2)
        let gapClick = CGPoint(x: (alpha.maxX + beta.minX) / 2, y: alpha.midY - 2)
        let snappedText = try #require(view.insertionPoint(for: textClick, on: page))
        let snappedGap = try #require(view.insertionPoint(for: gapClick, on: page))

        #expect(abs(snappedText.y - snappedGap.y) < 0.5)
        #expect(abs(snappedGap.x - gapClick.x) < 0.01)

        let blankPoint = CGPoint(x: 420, y: 60)
        #expect(view.insertionPoint(for: blankPoint, on: page) == nil)
    }

    @Test @MainActor
    func insertionPointIgnoresHyphensAndPunctuationOnLine() throws {
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        textView.string = "5-1.5B-Instruct for content injection\nThe results are shown below."
        textView.font = .systemFont(ofSize: 12)
        let document = try #require(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        let page = try #require(document.page(at: 0))
        let content = try #require(document.findString("content", withOptions: []).first).bounds(for: page)
        let hyphen = try #require(document.findString("-", withOptions: []).first).bounds(for: page)
        let pageText = try #require(page.string) as NSString
        let cRange = pageText.range(of: "content")
        let letterBaseline = page.characterBounds(at: cRange.location).minY

        let view = AnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.document = document
        view.layoutDocumentView()

        let click = CGPoint(x: content.midX, y: content.midY)
        let snapped = try #require(view.insertionPoint(for: click, on: page))
        #expect(abs(snapped.y - letterBaseline) < 0.5)
        #expect(abs(snapped.y - hyphen.minY) > 1.5)
    }
}
