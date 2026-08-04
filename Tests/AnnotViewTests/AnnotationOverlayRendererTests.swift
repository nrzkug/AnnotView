import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import AnnotView

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
}

struct PDFDocumentManagerTests {
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
        // The PDF view updates the selected page after completing the single
        // annotation-centered navigation. The manager must not request a
        // separate page jump first.
        #expect(manager.selectedPageIndex == 0)

        manager.goTo(annotation: annotation)
        #expect(manager.annotationNavigationID == 2)
    }

    @Test @MainActor
    func opensAndRendersAcceptancePDFWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["ANNOTVIEW_TEST_PDF"] else {
            return
        }

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
}

struct MuPDFAnnotationParserTests {
    @Test func decodesRotatedCropBoxCoordinates() throws {
        let json = #"""
        {
          "version": 1,
          "pages": [{
            "pageIndex": 0,
            "pageTransform": [0, 1, 1, 0, 10, 20],
            "annotations": [{
              "sourceID": "rotated", "inReplyToSourceID": null,
              "type": "Highlight", "bounds": [2, 3, 8, 9],
              "quadPoints": [[2, 3, 8, 3, 2, 9, 8, 9]],
              "contents": null, "author": null, "subject": null,
              "creationDate": null, "modificationDate": null,
              "color": [1, 1, 0], "opacity": 0.4,
              "stateModel": null, "state": null
            }]
          }]
        }
        """#

        let annotation = try #require(
            MuPDFAnnotationParser.decode(Data(json.utf8)).first
        )
        #expect(annotation.quadPoints[0] == CGPoint(x: 13, y: 22))
        #expect(annotation.quadPoints[3] == CGPoint(x: 19, y: 28))
        #expect(annotation.bounds == CGRect(x: 13, y: 22, width: 6, height: 6))
    }

    @Test func decodesCoordinatesColorsAndReplyRelationships() throws {
        let json = #"""
        {
          "version": 1,
          "pages": [{
            "pageIndex": 0,
            "pageTransform": [1, 0, 0, -1, 0, 100],
            "annotations": [
              {
                "sourceID": "10", "inReplyToSourceID": null,
                "type": "Underline", "bounds": [10, 20, 30, 30],
                "quadPoints": [[10, 20, 30, 20, 10, 30, 30, 30]],
                "contents": null, "author": "Reviewer", "subject": "Underline",
                "creationDate": "2026-07-28T03:44:44.000Z", "modificationDate": null,
                "color": [0.1, 0.2, 0.3], "opacity": 0.5,
                "stateModel": "Review", "state": "Accepted"
              },
              {
                "sourceID": "20", "inReplyToSourceID": null,
                "type": "Text", "bounds": [40, 40, 60, 60], "quadPoints": [],
                "contents": "Root", "author": "Reviewer", "subject": "Note",
                "creationDate": null, "modificationDate": null,
                "color": [1, 1, 0], "opacity": 1,
                "stateModel": null, "state": null
              },
              {
                "sourceID": "21", "inReplyToSourceID": "20",
                "type": "Text", "bounds": [40, 40, 60, 60], "quadPoints": [],
                "contents": "Reply", "author": "Author", "subject": "Reply",
                "creationDate": null, "modificationDate": null,
                "color": [1, 1, 0], "opacity": 1,
                "stateModel": "Review", "state": "Completed"
              }
            ]
          }]
        }
        """#

        let annotations = try MuPDFAnnotationParser.decode(Data(json.utf8))
        let underline = try #require(annotations.first { $0.kind == .underline })
        let reply = try #require(annotations.first { $0.contents == "Reply" })

        #expect(annotations.count == 3)
        #expect(underline.quadPoints[0] == CGPoint(x: 10, y: 80))
        #expect(underline.quadPoints[2] == CGPoint(x: 10, y: 70))
        #expect(abs(underline.color.alpha - 0.5) < 0.001)
        #expect(underline.createdDate != nil)
        #expect(underline.status == .accepted)
        #expect(underline.statusTargetSourceID == "10")
        #expect(reply.inReplyToSourceID == "20")
        #expect(reply.status == .completed)
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

    @Test func writesAcrobatStatusToACopyOfTheAcceptancePDF() async throws {
        guard let path = ProcessInfo.processInfo.environment["ANNOTVIEW_TEST_PDF"] else {
            return
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AnnotViewStatusTest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let copyURL = temporaryDirectory.appendingPathComponent("review-copy.pdf")
        try fileManager.copyItem(at: URL(fileURLWithPath: path), to: copyURL)
        let parser = MuPDFAnnotationParser()
        let before = try await parser.annotations(in: copyURL)
        let target = try #require(before.first { $0.kind == .strikeout })
        let targetID = try #require(target.statusTargetSourceID)

        let writer = MuPDFAnnotationStatusWriter()
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
