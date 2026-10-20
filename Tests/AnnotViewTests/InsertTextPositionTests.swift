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
        let writer = MuPDFAnnotationWriter()
        for pageIndex in 0..<4 {
            for point in points {
                try await writer.createCaret(
                    in: url, location: PDFPagePoint(pageIndex: pageIndex, point: point),
                    contents: "\(point.y)", author: "Test", color: .red, createdAt: Date()
                )
            }
        }
        let annotations = try await MuPDFAnnotationParser().annotations(in: url)
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
}
