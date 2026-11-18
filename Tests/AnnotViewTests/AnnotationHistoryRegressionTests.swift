import AppKit
import PDFKit
import Testing
@testable import AnnotView

@MainActor
struct AnnotationHistoryRegressionTests {
    private func makeDoc(pages: Int) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("p.pdf")
        let document = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill(); image.unlockFocus()
            document.insert(PDFPage(image: image)!, at: i)
        }
        #expect(document.write(to: url))
        return (directory, url)
    }

    @Test func contentsRoundTripSpecialCharacters() async throws {
        let (dir, url) = try makeDoc(pages: 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = PDFDocumentManager()
        await manager.open(url: url)
        let note = try #require(await manager.createNote(at: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 100, y: 100))))
        let text = "a/b \\ c\td \u{1F600} é \"q\" \\\" end"
        #expect(await manager.updateAnnotation(note, contents: text))
        #expect(manager.annotations.first?.contents == text)
    }

    @Test func undoingMultiPageDeleteKeepsStatusAndHistoryOnTheRightAnnotation() async throws {
        let (dir, url) = try makeDoc(pages: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = PDFDocumentManager()
        await manager.open(url: url)
        let a = try #require(await manager.createNote(at: PDFPagePoint(pageIndex: 0, point: CGPoint(x: 100, y: 100))))
        #expect(await manager.updateAnnotation(a, contents: "A-page0"))
        let b = try #require(await manager.createNote(at: PDFPagePoint(pageIndex: 1, point: CGPoint(x: 100, y: 100))))
        #expect(await manager.updateAnnotation(b, contents: "B-page1"))
        let liveB = try #require(manager.annotations.first { $0.contents == "B-page1" })
        #expect(await manager.updateStatus(of: liveB, to: .accepted))
        let a2 = try #require(manager.annotations.first { $0.contents == "A-page0" })
        let b2 = try #require(manager.annotations.first { $0.contents == "B-page1" })
        // Delete in reverse document order (page 1 first)
        #expect(await manager.deleteAnnotations([b2, a2]))
        await manager.undoAnnotationChange()
        let rB = manager.annotations.first { $0.contents == "B-page1" }
        let rA = manager.annotations.first { $0.contents == "A-page0" }
        #expect(rB?.status == .accepted)
        #expect(rA?.status == Annotation.Status.none)
        // Status changes are not in undo history, so this undoes B's edit; it must not touch A.
        await manager.undoAnnotationChange()
        #expect(manager.annotations.first { $0.pageIndex == 1 }?.contents == nil)
        #expect(manager.annotations.first { $0.pageIndex == 0 }?.contents == "A-page0")
    }
}
