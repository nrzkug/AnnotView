import AppKit
import PDFKit
import Testing
@testable import AnnotView

struct PDFCursorTests {
    @Test @MainActor
    func textAndWordGapsKeepIBeamAcrossToolsAndMarkup() throws {
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
        let textPoint = CGPoint(x: alpha.midX, y: alpha.midY)
        let gapPoint = CGPoint(x: (alpha.maxX + beta.minX) / 2, y: alpha.midY)
        let line = alpha.union(beta)
        view.overlayAnnotations = [0: [Annotation(
            kind: .highlight, pageIndex: 0, bounds: line,
            quadPoints: [CGPoint(x: line.minX, y: line.maxY), CGPoint(x: line.maxX, y: line.maxY),
                         CGPoint(x: line.minX, y: line.minY), CGPoint(x: line.maxX, y: line.minY)],
            color: .yellow
        )]]
        for tool in AnnotationTool.allCases {
            view.annotationTool = tool
            for point in [textPoint, gapPoint] {
                #expect(view.cursor(at: view.convert(point, from: page)) === NSCursor.iBeam)
            }
        }
        let blank = view.convert(CGPoint(x: 400, y: 100), from: page)
        view.annotationTool = .note
        #expect(view.cursor(at: blank) === NSCursor.crosshair)
        view.annotationTool = .highlight
        #expect(view.cursor(at: blank) === NSCursor.arrow)
    }
}
