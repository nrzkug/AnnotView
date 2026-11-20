import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AnnotView

private let acceptancePDFPath = ProcessInfo.processInfo.environment["ANNOTVIEW_TEST_PDF"]
private let acceptanceTestsAreEnabled = acceptancePDFPath != nil

struct AnnotationOverlayRendererTests {
    @Test func groupsAcrobatQuadPointsInSetsOfFour() {
        let points = (0..<8).map { CGPoint(x: $0, y: $0) }
        let annotation = Annotation(
            kind: .strikeout,
            pageIndex: 0,
            bounds: .zero,
            quadPoints: points
        )

        let quads = AnnotationOverlayRenderer.quadrilaterals(from: annotation)

        #expect(quads.count == 2)
        #expect(quads[0] == Array(points[0..<4]))
        #expect(quads[1] == Array(points[4..<8]))
    }

    @Test func fallsBackToBoundsWithoutQuadPoints() {
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: bounds
        )

        let quads = AnnotationOverlayRenderer.quadrilaterals(from: annotation)

        #expect(quads == [[
            CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 60),
            CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20)
        ]])
    }

    @Test func neverUsesBoundsForStrikeoutPlacement() {
        let annotation = Annotation(
            kind: .strikeout,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 30, height: 40)
        )

        #expect(AnnotationOverlayRenderer.quadrilaterals(from: annotation).isEmpty)
    }

    @Test func buildsANonIntersectingAcrobatZOrderPath() {
        let quad = [
            CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30),
            CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20)
        ]
        let path = AnnotationOverlayRenderer.path(for: quad)

        #expect(path.boundingBox == CGRect(x: 10, y: 20, width: 40, height: 10))
        #expect(path.contains(CGPoint(x: 30, y: 25)))
    }

    @Test func matchesAcrobatStrikeoutAppearancePlacement() throws {
        let quad = [
            CGPoint(x: 324.757, y: 301.503), CGPoint(x: 328.466, y: 301.503),
            CGPoint(x: 324.757, y: 290.594), CGPoint(x: 328.466, y: 290.594)
        ]
        let line = try #require(
            AnnotationOverlayRenderer.textMarkupLine(for: quad, kind: .strikeout)
        )

        #expect(abs(line.start.y - 295.269) < 0.001)
        #expect(line.start.x == quad[2].x)
        #expect(line.end.x == quad[3].x)
    }

    @Test func exposesOnlyAcrobatReviewStatesInMenus() {
        #expect(Annotation.Status.selectableCases == [
            .none, .accepted, .rejected, .cancelled, .completed
        ])
    }

    @Test func markupCommentHitTestingUsesQuadPoints() {
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 500, y: 500, width: 1, height: 1),
            quadPoints: [
                CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 30),
                CGPoint(x: 10, y: 20), CGPoint(x: 50, y: 20)
            ],
            contents: "Comment"
        )

        #expect(AnnotationOverlayRenderer.contains(CGPoint(x: 30, y: 25), in: annotation))
        #expect(!AnnotationOverlayRenderer.contains(CGPoint(x: 300, y: 300), in: annotation))
    }

    @Test func noteIconUsesACompactStableSize() {
        let annotation = Annotation(
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 24, height: 24)
        )

        let icon = AnnotationOverlayRenderer.noteIconRect(for: annotation)
        #expect(icon.size == CGSize(width: 12, height: 12))
        #expect(icon.midX == annotation.bounds.midX)
        #expect(icon.midY == annotation.bounds.midY)
    }

    @Test func mapsRotatedNonZeroCropBoxIntoPageOverlay() {
        let transform = PageOverlayGeometry.affineTransform(
            pageBounds: CGRect(x: 10, y: 20, width: 200, height: 300),
            localOrigin: CGPoint(x: 300, y: 50),
            localXBasis: CGPoint(x: 300, y: 52),
            localYBasis: CGPoint(x: 298, y: 50)
        )

        #expect(CGPoint(x: 10, y: 20).applying(transform) == CGPoint(x: 300, y: 50))
        #expect(CGPoint(x: 210, y: 320).applying(transform) == CGPoint(x: -300, y: 450))
    }

    @Test func caretAnnotationDrawsVisibleInk() {
        let annotation = Annotation(
            kind: .caret,
            pageIndex: 0,
            bounds: CGRect(x: 20, y: 20, width: 9, height: 7),
            contents: "insert here",
            color: .init(red: 0.75, green: 0.22, blue: 0.77, alpha: 1)
        )

        let size = CGSize(width: 64, height: 64)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        AnnotationOverlayRenderer.draw([annotation], context: context)
        let image = try! #require(context.makeImage())
        let data = try! #require(image.dataProvider?.data as Data?)
        let bytesPerRow = image.bytesPerRow

        var colored = 0
        for row in 0..<Int(size.height) {
            for column in 0..<Int(size.width) {
                let index = row * bytesPerRow + column * 4
                if data[index + 3] > 0 && (data[index] > 8 || data[index + 1] > 8 || data[index + 2] > 8) {
                    colored += 1
                }
            }
        }
        #expect(colored >= 5)
        #expect(AnnotationOverlayRenderer.contains(CGPoint(x: 22, y: 22), in: annotation))

        // The glyph is an upward-pointing triangle of fixed size: the apex sits
        // above the baseline, so the pixel at the apex is inked while the pixel
        // directly above it (inside the rect) stays empty.
        func isInked(_ column: Int, _ row: Int) -> Bool {
            let index = row * bytesPerRow + column * 4
            return data[index + 3] > 0 && (data[index] > 8 || data[index + 1] > 8 || data[index + 2] > 8)
        }
        let marker = AnnotationOverlayRenderer.caretMarkerRect(for: annotation)
        let apexColumn = Int(marker.midX)
        let apexRow = Int(size.height - marker.maxY)
        #expect(isInked(apexColumn, apexRow))
        #expect(!isInked(apexColumn, apexRow - 1))
    }
}

struct PDFDocumentManagerTests {
    @Test @MainActor
    func multiSelectionNavigatesAndUpdatesStatusesAsOneBatch() async throws {
        let first = Annotation(
            sourceID: "101 0 R",
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 30, height: 12)
        )
        let second = Annotation(
            sourceID: "102 0 R",
            kind: .note,
            pageIndex: 1,
            bounds: CGRect(x: 40, y: 50, width: 12, height: 12)
        )
        let updater = RecordingAnnotationStatusUpdater()
        let manager = PDFDocumentManager(
            annotationParser: FixedAnnotationParser(annotations: [first, second]),
            annotationStatusUpdater: updater,
            displayDocumentPreparer: EmptyDisplayDocumentPreparer(),
            documentBuilder: EmptyDocumentBuilder()
        )
        await manager.open(url: URL(fileURLWithPath: "/tmp/multi-select.pdf"))

        manager.selectAnnotations([first.id, second.id])
        #expect(manager.selectedAnnotationIDs == [first.id, second.id])
        #expect(manager.selectedAnnotationID == first.id)

        await manager.updateStatus(of: manager.annotations, to: .completed)

        #expect(manager.annotations.allSatisfy { $0.status == .completed })
        let updates = await updater.recordedUpdates()
        #expect(updates.count == 2)
        #expect(Set(updates.map(\.sourceID)) == ["101 0 R", "102 0 R"])
        #expect(updates.allSatisfy { $0.status == .completed })
    }

    @Test @MainActor
    func repeatedAnnotationNavigationCreatesFreshFeedbackRequests() {
        let manager = PDFDocumentManager()
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 2,
            bounds: CGRect(x: 10, y: 20, width: 30, height: 12),
            quadPoints: [
                CGPoint(x: 10, y: 32), CGPoint(x: 40, y: 32),
                CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20)
            ]
        )

        manager.goTo(annotation: annotation)
        #expect(manager.annotationNavigationID == 1)
        #expect(manager.focusedAnnotation?.id == annotation.id)
        #expect(manager.selectedAnnotationID == annotation.id)
        // The PDF view updates the selected page after completing the single
        // annotation-centered navigation. The manager must not request a
        // separate page jump first.
        #expect(manager.selectedPageIndex == 0)

        manager.goTo(annotation: annotation)
        #expect(manager.annotationNavigationID == 2)
    }

    @Test @MainActor
    func editRequestCollapsesMultiSelectionAndOpensTheEditor() {
        let manager = PDFDocumentManager()
        let first = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 30, height: 12)
        )
        let second = Annotation(
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 50, y: 60, width: 12, height: 12)
        )
        manager.goTo(annotation: first)
        manager.goTo(annotation: second, preservingMultipleSelection: true)
        #expect(manager.selectedAnnotationIDs == [first.id, second.id])

        manager.edit(annotation: first)

        #expect(manager.selectedAnnotationIDs == [first.id])
        #expect(manager.focusedAnnotation?.id == first.id)
        #expect(AnnotationPresentationPolicy.action(
            for: first,
            request: manager.annotationPresentationRequest
        ) == .editor)
    }

    @Test @MainActor
    func selectionPersistsIndependentlyOfNavigationFeedback() {
        let manager = PDFDocumentManager()
        let annotation = Annotation(
            kind: .highlight,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 30, height: 12)
        )
        let other = Annotation(
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 12, height: 12)
        )

        manager.goTo(annotation: annotation)
        #expect(manager.selectedAnnotationID == annotation.id)

        // Selecting another annotation replaces the selection.
        manager.selectAnnotation(other.id)
        #expect(manager.selectedAnnotationID == other.id)

        // Deselecting clears it without touching navigation feedback.
        manager.deselectAnnotation()
        #expect(manager.selectedAnnotationID == nil)
        #expect(manager.focusedAnnotation?.id == annotation.id)
    }

    @Test @MainActor
    func failedMoveRestoresTheOptimisticAnnotationPosition() async {
        let original = Annotation(
            sourceID: "annotation-1",
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 10, y: 20, width: 16, height: 16)
        )
        let manager = PDFDocumentManager(
            annotationParser: FixedAnnotationParser(annotations: [original]),
            annotationWriter: FailingAnnotationWriter(),
            displayDocumentPreparer: EmptyDisplayDocumentPreparer(),
            documentBuilder: EmptyDocumentBuilder()
        )
        await manager.open(url: URL(fileURLWithPath: "/tmp/test.pdf"))
        manager.goTo(annotation: original)

        let moved = await manager.move(
            original,
            to: CGRect(x: 100, y: 200, width: 16, height: 16)
        )

        #expect(!moved)
        #expect(manager.annotations.first?.bounds == original.bounds)
        #expect(manager.focusedAnnotation?.bounds == original.bounds)
    }

    @Test(.enabled(
        if: acceptanceTestsAreEnabled,
        "Requires ANNOTVIEW_TEST_PDF"
    )) @MainActor
    func opensAndRendersAcceptancePDFWhenProvided() async throws {
        let path = try #require(acceptancePDFPath)

        let manager = PDFDocumentManager()
        await manager.open(url: URL(fileURLWithPath: path))

        #expect(manager.errorMessage == nil)
        #expect(manager.pageCount > 0)
        #expect(manager.document?.page(at: 0)?.displaysAnnotations == false)
        let nativeAnnotations = (0..<manager.pageCount).flatMap {
            manager.document?.page(at: $0)?.annotations ?? []
        }
        #expect(nativeAnnotations.allSatisfy { $0.type == "Link" })
        #expect(manager.annotations.count == 33)
        #expect(manager.annotations.count(where: { $0.kind == .highlight }) == 15)
        #expect(manager.annotations.count(where: { $0.kind == .strikeout }) == 7)
        #expect(manager.annotations.count(where: { $0.kind == .note }) == 11)
        #expect(manager.annotations.allSatisfy { $0.createdDate != nil })

        let replacementEdit = try #require(manager.annotations.first {
            $0.pageIndex == 0 && $0.kind == .strikeout
        })
        #expect(replacementEdit.inReplyToSourceID == nil)
        #expect(replacementEdit.contents?.contains("classic Gaussian mechanism") == true)

        let pageThreeHighlight = try #require(manager.annotations.first {
            $0.pageIndex == 2 && $0.kind == .highlight
        })
        #expect(abs(pageThreeHighlight.quadPoints[0].x - 246.155) < 0.01)
        #expect(abs(pageThreeHighlight.quadPoints[0].y - 583.947) < 0.01)

        manager.searchController.query = "Reviewer"
        manager.performSearch()
        #expect(!manager.searchController.results.isEmpty)
        #expect(manager.searchController.currentResultIndex == 0)
        manager.selectNextSearchResult()
        #expect(manager.searchController.currentResultIndex == 1)

        let preview = try manager.renderPage(pageIndex: 0, scale: 0.2)
        #expect(preview.size.width > 0)
        #expect(preview.size.height > 0)
    }

    @Test @MainActor
    func builderStripsNonLinkAnnotationsAndPreservesLinks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnotViewBuilderTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let documentURL = temporaryDirectory.appendingPathComponent("test.pdf")
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))

        let highlight = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 50, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        let link = PDFAnnotation(
            bounds: CGRect(x: 10, y: 50, width: 50, height: 20),
            forType: .link,
            withProperties: nil
        )
        page.addAnnotation(highlight)
        page.addAnnotation(link)

        let document = PDFDocument()
        document.insert(page, at: 0)
        #expect(document.write(to: documentURL))

        let builder = PDFKitDocumentBuilder()
        let loaded = try #require(builder.build(from: documentURL))
        let loadedPage = try #require(loaded.document.page(at: 0))

        #expect(loadedPage.displaysAnnotations == false)
        #expect(loadedPage.annotations.count == 1)
        #expect(loadedPage.annotations[0].type == "Link")
    }

    @Test @MainActor
    func asyncThumbnailRendersAndCachesSmoothly() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)

        let data = try #require(document.dataRepresentation())
        let manager = PDFDocumentManager()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString).pdf")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await manager.open(url: tempURL)
        #expect(manager.document != nil)

        #expect(manager.cachedThumbnail(for: 0, scale: 0.5) == nil)
        let thumbnail = await manager.renderPageAsync(pageIndex: 0, scale: 0.5)
        #expect(thumbnail != nil)
        #expect(manager.cachedThumbnail(for: 0, scale: 0.5) != nil)
    }

    @Test @MainActor
    func asyncThumbnailCompositesAnnotations() async throws {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let page = try #require(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)

        let data = try #require(document.dataRepresentation())
        let note = Annotation(
            sourceID: "note-1",
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 50, y: 50, width: 20, height: 20),
            color: .init(red: 1, green: 0, blue: 0, alpha: 1)
        )
        let manager = PDFDocumentManager(
            annotationParser: FixedAnnotationParser(annotations: [note]),
            documentBuilder: PDFKitDocumentBuilder()
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-annot-\(UUID().uuidString).pdf")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await manager.open(url: tempURL)
        #expect(manager.annotations.count == 1)

        let initialRevision = manager.thumbnailRevision
        let thumb = await manager.renderPageAsync(pageIndex: 0, scale: 0.5)
        #expect(thumb != nil)
        #expect(manager.cachedThumbnail(for: 0, scale: 0.5) != nil)

        // Invalidation clears cache and bumps revision
        manager.invalidateThumbnailCache()
        #expect(manager.thumbnailRevision > initialRevision)
        #expect(manager.cachedThumbnail(for: 0, scale: 0.5) == nil)
    }
}

private struct FixedAnnotationParser: AnnotationParsing {
    let annotations: [Annotation]

    func annotations(in documentURL: URL) async throws -> [Annotation] {
        annotations
    }
}

private actor FailingAnnotationWriter: AnnotationWriting {
    enum Failure: Error { case writeFailed }

    func perform(_ mutations: [AnnotationMutation], in documentURL: URL) async throws {
        throw Failure.writeFailed
    }
}

private actor RecordingAnnotationStatusUpdater: AnnotationStatusUpdating {
    private var updates: [AnnotationStatusUpdate] = []

    func updateStatuses(
        in documentURL: URL,
        updates: [AnnotationStatusUpdate]
    ) async throws {
        self.updates = updates
    }

    func recordedUpdates() -> [AnnotationStatusUpdate] { updates }
}

private struct EmptyDisplayDocumentPreparer: PDFDisplayDocumentPreparing {
    func displayData(for documentURL: URL) async throws -> Data { Data() }
}

@MainActor
private struct EmptyDocumentBuilder: PDFDocumentBuilding {
    func build(from data: Data) -> LoadedPDFDocument? {
        LoadedPDFDocument(document: PDFDocument(), outlineItems: [])
    }
}

struct SwiftPDFAnnotationParserTests {
    private static func makeMinimalPDF(
        pageDictExtras: [String: PDFObject] = [:],
        annots: [(Int, [String: PDFObject])]
    ) -> Data {
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int: Int] = [:]
        func appendObj(_ num: Int, _ obj: PDFObject) {
            offsets[num] = pdf.count
            pdf.append(PDFSerializer.serializeIndirectObject(objNum: num, genNum: 0, object: obj))
        }
        appendObj(1, .dict(["Type": .name("Catalog"), "Pages": .indirectRef(objNum: 2, genNum: 0)]))
        appendObj(2, .dict([
            "Type": .name("Pages"),
            "Kids": .array([.indirectRef(objNum: 3, genNum: 0)]),
            "Count": .int(1)
        ]))
        var pageDict: [String: PDFObject] = [
            "Type": .name("Page"),
            "Parent": .indirectRef(objNum: 2, genNum: 0),
            "MediaBox": .array([.int(0), .int(0), .int(612), .int(792)]),
            "Annots": .array(annots.map { .indirectRef(objNum: $0.0, genNum: 0) })
        ]
        for (k, v) in pageDictExtras { pageDict[k] = v }
        appendObj(3, .dict(pageDict))
        for (num, dict) in annots {
            appendObj(num, .dict(dict))
        }
        let maxObj = max(3, annots.map(\.0).max() ?? 3)
        let xrefOffset = pdf.count
        pdf.append(Data("xref\n0 \(maxObj + 1)\n0000000000 65535 f \n".utf8))
        for i in 1...maxObj {
            if let off = offsets[i] {
                pdf.append(Data(String(format: "%010d 00000 n \n", off).utf8))
            } else {
                pdf.append(Data("0000000000 65535 f \n".utf8))
            }
        }
        pdf.append(Data("trailer\n<< /Size \(maxObj + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return pdf
    }

    @Test func decodesRotatedCropBoxCoordinates() throws {
        let pdfData = Self.makeMinimalPDF(
            pageDictExtras: [
                "Rotate": .int(90),
                "CropBox": .array([.int(10), .int(20), .int(500), .int(700)])
            ],
            annots: [
                (10, [
                    "Type": .name("Annot"),
                    "Subtype": .name("Highlight"),
                    "Rect": .array([.int(13), .int(22), .int(19), .int(28)]),
                    "QuadPoints": .array([
                        .int(13), .int(28), .int(19), .int(28),
                        .int(13), .int(22), .int(19), .int(22)
                    ]),
                    "C": .array([.int(1), .int(1), .int(0)]),
                    "CA": .real(0.4)
                ])
            ]
        )

        let annotation = try #require(
            try SwiftPDFAnnotationParser().annotations(in: pdfData).first
        )
        #expect(annotation.quadPoints[0] == CGPoint(x: 13, y: 28))
        #expect(annotation.quadPoints[3] == CGPoint(x: 19, y: 22))
        #expect(annotation.bounds == CGRect(x: 13, y: 22, width: 6, height: 6))
        #expect(abs(annotation.color.alpha - 0.4) < 0.001)
    }

    @Test func decodesCoordinatesColorsAndReplyRelationships() throws {
        let pdfData = Self.makeMinimalPDF(annots: [
            (10, [
                "Type": .name("Annot"),
                "Subtype": .name("Underline"),
                "Rect": .array([.int(10), .int(70), .int(30), .int(80)]),
                "QuadPoints": .array([
                    .int(10), .int(80), .int(30), .int(80),
                    .int(10), .int(70), .int(30), .int(70)
                ]),
                "T": .string(PDFTextString.encode("Reviewer")),
                "Subj": .string(PDFTextString.encode("Underline")),
                "CreationDate": .string(PDFTextString.encode("D:20260728034444Z")),
                "C": .array([.real(0.1), .real(0.2), .real(0.3)]),
                "CA": .real(0.5),
                "StateModel": .name("Review"),
                "State": .name("Accepted")
            ]),
            (20, [
                "Type": .name("Annot"),
                "Subtype": .name("Text"),
                "Rect": .array([.int(40), .int(40), .int(60), .int(60)]),
                "Contents": .string(PDFTextString.encode("Root")),
                "T": .string(PDFTextString.encode("Reviewer")),
                "C": .array([.int(1), .int(1), .int(0)])
            ]),
            (21, [
                "Type": .name("Annot"),
                "Subtype": .name("Text"),
                "IRT": .indirectRef(objNum: 20, genNum: 0),
                "Rect": .array([.int(40), .int(40), .int(60), .int(60)]),
                "Contents": .string(PDFTextString.encode("Reply")),
                "T": .string(PDFTextString.encode("Author")),
                "C": .array([.int(1), .int(1), .int(0)]),
                "StateModel": .name("Review"),
                "State": .name("Completed")
            ])
        ])

        let annotations = try SwiftPDFAnnotationParser().annotations(in: pdfData)
        let underline = try #require(annotations.first { $0.kind == .underline })
        let reply = try #require(annotations.first { $0.contents == "Reply" })

        #expect(annotations.count == 3)
        #expect(underline.quadPoints[0] == CGPoint(x: 10, y: 80))
        #expect(underline.quadPoints[2] == CGPoint(x: 10, y: 70))
        #expect(abs(underline.color.alpha - 0.5) < 0.001)
        #expect(underline.createdDate != nil)
        #expect(underline.status == .accepted)
        #expect(underline.statusTargetSourceID == "10 0 R")
        #expect(reply.inReplyToSourceID == "20 0 R")
        #expect(reply.status == .completed)
    }

    @Test func decodesStandaloneCaretAnnotations() throws {
        let pdfData = Self.makeMinimalPDF(annots: [
            (10, [
                "Type": .name("Annot"),
                "Subtype": .name("Caret"),
                "Rect": .array([.int(472), .int(722), .int(481), .int(729)]),
                "Contents": .string(PDFTextString.encode("We note that Fashion-MNIST and CIFAR-10 are two of the most popular datasets in the federated learning literature [refs].")),
                "T": .string(PDFTextString.encode("rjin")),
                "Subj": .string(PDFTextString.encode("InsertedText")),
                "C": .array([.real(0.75), .real(0.22), .real(0.77)])
            ])
        ])

        let annotation = try #require(
            try SwiftPDFAnnotationParser().annotations(in: pdfData).first
        )
        #expect(annotation.kind == .caret)
        #expect(annotation.contents?.hasPrefix("We note that Fashion-MNIST") == true)
        #expect(annotation.bounds == CGRect(x: 472, y: 722, width: 9, height: 7))
    }

    @Test func hidesCaretParentsAlreadyMergedIntoTheirStrikeOutChild() throws {
        let pdfData = Self.makeMinimalPDF(annots: [
            (10, [
                "Type": .name("Annot"),
                "Subtype": .name("Caret"),
                "Rect": .array([.int(10), .int(20), .int(20), .int(30)]),
                "Contents": .string(PDFTextString.encode("bound specified")),
                "T": .string(PDFTextString.encode("rjin")),
                "C": .array([.real(0.97), .real(0.39), .real(0.39)])
            ]),
            (11, [
                "Type": .name("Annot"),
                "Subtype": .name("StrikeOut"),
                "IRT": .indirectRef(objNum: 10, genNum: 0),
                "Rect": .array([.int(10), .int(20), .int(30), .int(30)]),
                "QuadPoints": .array([
                    .int(10), .int(30), .int(30), .int(30),
                    .int(10), .int(20), .int(30), .int(20)
                ]),
                "T": .string(PDFTextString.encode("rjin")),
                "C": .array([.real(0.9), .real(0.15), .real(0.12)])
            ])
        ])

        let annotations = try SwiftPDFAnnotationParser().annotations(in: pdfData)
        #expect(annotations.count == 1)
        let merged = try #require(annotations.first)
        #expect(merged.kind == .strikeout)
        #expect(merged.contents == "bound specified")
        #expect(merged.statusTargetSourceID == "10 0 R")
    }

    @Test func groupsTextRepliesUnderTheirParent() {
        let root = Annotation(
            sourceID: "root", kind: .note, pageIndex: 0,
            bounds: .zero, contents: "Root"
        )
        let reply = Annotation(
            sourceID: "reply", inReplyToSourceID: "root", kind: .note,
            pageIndex: 0, bounds: .zero, contents: "Reply"
        )

        let threads = AnnotationThreading.group([root, reply])

        #expect(threads.count == 1)
        #expect(threads[0].root.sourceID == "root")
        #expect(threads[0].replies.map(\.sourceID) == ["reply"])
    }

    @Test(.enabled(
        if: acceptanceTestsAreEnabled,
        "Requires ANNOTVIEW_TEST_PDF"
    ))
    func writesAcrobatStatusToACopyOfTheAcceptancePDF() async throws {
        let path = try #require(acceptancePDFPath)

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AnnotViewStatusTest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let copyURL = temporaryDirectory.appendingPathComponent("review-copy.pdf")
        try fileManager.copyItem(at: URL(fileURLWithPath: path), to: copyURL)
        let parser = SwiftPDFAnnotationParser()
        let before = try await parser.annotations(in: copyURL)
        let target = try #require(before.first { $0.kind == .strikeout })
        let targetID = try #require(target.statusTargetSourceID)

        let writer = SwiftPDFAnnotationStatusWriter()
        try await writer.updateStatus(in: copyURL, sourceID: targetID, status: .accepted)

        let after = try await parser.annotations(in: copyURL)
        let updated = try #require(after.first {
            $0.kind == target.kind && $0.contents == target.contents
        })
        #expect(updated.status == .accepted)
        #expect(updated.statusTargetSourceID == targetID)

        // A second write confirms that saving preserved PDF object identifiers.
        try await writer.updateStatus(in: copyURL, sourceID: targetID, status: .completed)
        let final = try await parser.annotations(in: copyURL)
        #expect(final.first { $0.statusTargetSourceID == targetID }?.status == .completed)
    }
}

struct AnnotationColorMemoryTests {
    @Test @MainActor
    func remembersLastUsedColorPerKind() {
        let suite = "AnnotationColorMemoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = AnnotationColorMemory(defaults: defaults)

        // Initial defaults: sticky notes purple-blue, not yellow.
        let note = memory.color(for: .note)
        #expect(abs(note.red - 0.588242) < 0.001)
        #expect(abs(note.blue - 0.988235) < 0.001)
        let caret = memory.color(for: .caret)
        #expect(abs(caret.red - 0.752945) < 0.001)

        // Remembering a color for one kind does not affect others.
        let custom = Annotation.Color(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8)
        memory.set(custom, for: .note)
        let remembered = memory.color(for: .note)
        #expect(abs(remembered.red - 0.1) < 0.001)
        #expect(abs(remembered.alpha - 0.8) < 0.001)
        #expect(abs(memory.color(for: .caret).red - 0.752945) < 0.001)
    }
}
