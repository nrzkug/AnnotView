import AppKit
import PDFKit
import Testing
@testable import AnnotView

@MainActor
struct AnnotationInteractionControllerTests {
    private static let page: PDFPage = {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return PDFPage(image: image)!
    }()

    private func note(id: UUID = UUID()) -> Annotation {
        Annotation(
            id: id,
            kind: .note,
            pageIndex: 0,
            bounds: CGRect(x: 100, y: 100, width: 20, height: 20),
            contents: "Test comment"
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func hoverSchedulesPresentationAfterDelay() async throws {
        let controller = AnnotationInteractionController(
            onHoveredAnnotationChanged: { _ in },
            onTransientAnnotationChanged: { _ in }
        )
        let note = note()
        let recorder = PresentationRecorder()
        controller.updateHover(
            annotation: note,
            page: Self.page,
            presentationContext: .none,
            presentedAnnotationID: nil,
            present: recorder.record
        )
        try await waitUntil { recorder.calls == 1 }
        #expect(recorder.lastID == note.id)
    }

    @Test func hoverWhilePresentedDoesNotReschedule() async throws {
        let controller = AnnotationInteractionController(
            onHoveredAnnotationChanged: { _ in },
            onTransientAnnotationChanged: { _ in }
        )
        let note = note()
        let recorder = PresentationRecorder()
        controller.updateHover(
            annotation: note,
            page: Self.page,
            presentationContext: .transientPreview,
            presentedAnnotationID: note.id,
            present: recorder.record
        )
        // Give a scheduling bug time to surface; nothing should have fired.
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.calls == 0)
    }

    @Test func hoverAfterPresentationGoneReschedules() async throws {
        let controller = AnnotationInteractionController(
            onHoveredAnnotationChanged: { _ in },
            onTransientAnnotationChanged: { _ in }
        )
        let note = note()
        let recorder = PresentationRecorder()
        // First hover: nothing presented, so a preview is scheduled and shown.
        controller.updateHover(
            annotation: note,
            page: Self.page,
            presentationContext: .none,
            presentedAnnotationID: nil,
            present: recorder.record
        )
        try await waitUntil { recorder.calls == 1 }
        // The preview was dismissed (drag/click-away) but the mouse stayed on
        // the same annotation: the stale hover id must not suppress a retry.
        controller.updateHover(
            annotation: note,
            page: Self.page,
            presentationContext: .none,
            presentedAnnotationID: nil,
            present: recorder.record
        )
        try await waitUntil { recorder.calls == 2 }
    }

    @Test func hoverNilClearsPendingPresentation() async throws {
        let controller = AnnotationInteractionController(
            onHoveredAnnotationChanged: { _ in },
            onTransientAnnotationChanged: { _ in }
        )
        let note = note()
        let recorder = PresentationRecorder()
        controller.updateHover(
            annotation: note,
            page: Self.page,
            presentationContext: .none,
            presentedAnnotationID: nil,
            present: recorder.record
        )
        // Mouse leaves before the delay elapses.
        controller.updateHover(
            annotation: nil,
            page: nil,
            presentationContext: .none,
            presentedAnnotationID: nil,
            present: recorder.record
        )
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.calls == 0)
    }
}

@MainActor
private final class PresentationRecorder {
    private(set) var calls = 0
    private(set) var lastID: UUID?

    func record(_ annotation: Annotation, _ page: PDFPage) {
        calls += 1
        lastID = annotation.id
    }
}
