import AppKit
import PDFKit
import Testing
@testable import AnnotView

struct ReaderChromeLayoutTests {
    @Test @MainActor
    func chromeInsetsDocumentWithoutShorteningPDFViewport() throws {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let document = PDFDocument()
        document.insert(try #require(PDFPage(image: image)), at: 0)
        document.insert(try #require(PDFPage(image: image)), at: 1)

        let view = AnnotationPDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.displayMode = .singlePageContinuous
        view.document = document
        view.scaleFactor = 1
        view.topContentInset = 52
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()

        let scroll = try #require(view.documentView?.enclosingScrollView)
        let viewport = view.convert(scroll.bounds, from: scroll)
        #expect(abs(viewport.maxY - view.bounds.maxY) < 1)
        #expect(abs(viewport.height - view.bounds.height) < 1)
        #expect(scroll.contentInsets.top == 52)
        #expect(scroll.scrollerInsets.top == -52)
        if let scroller = scroll.verticalScroller {
            let track = view.convert(scroller.bounds, from: scroller)
            #expect(abs(track.maxY - view.bounds.maxY) < 1)
        }

        let dragPoint = NSPoint(x: view.bounds.midX, y: view.isFlipped ? 20 : view.bounds.maxY - 20)
        #expect(view.isWindowDragPoint(dragPoint))
        #expect(view.hitTest(dragPoint) === view)
        #expect(!view.isWindowDragPoint(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))

        // Fullscreen/chrome changes must update the document inset without
        // introducing a second reserved band above the scroll view.
        view.topContentInset = 0
        view.layoutSubtreeIfNeeded()
        #expect(scroll.contentInsets.top == 0)
        #expect(!view.isWindowDragPoint(dragPoint))
        #expect(abs(view.convert(scroll.bounds, from: scroll).height - view.bounds.height) < 1)
    }
}
