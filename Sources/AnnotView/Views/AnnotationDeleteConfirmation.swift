import AppKit

/// Confirmation sheet before deletions that permanently rewrite the PDF.
/// Shared by the sidebar context menu and the PDF-side delete paths, which all
/// funnel through `PDFDocumentManager.deleteAnnotation(s)`.
@MainActor
enum AnnotationDeleteConfirmation {
    static func confirm(count: Int, from window: NSWindow?) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = count == 1
                ? "Delete Annotation?"
                : "Delete \(count) Annotations?"
            alert.informativeText = count == 1
                ? "This will permanently remove the annotation from the PDF."
                : "This will permanently remove the selected annotations from the PDF."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true

            guard let window else {
                continuation.resume(
                    returning: alert.runModal() == .alertFirstButtonReturn
                )
                return
            }
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }
}
