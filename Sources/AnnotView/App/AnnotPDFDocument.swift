import AppKit
import Combine
import SwiftUI

@MainActor
final class AnnotPDFDocument: NSDocument {
    let documentManager: PDFDocumentManager
    let chromeState: ReaderChromeState
    private var cancellables = Set<AnyCancellable>()

    override init() {
        self.documentManager = PDFDocumentManager()
        self.chromeState = ReaderChromeState()
        super.init()
    }

    override class var autosavesInPlace: Bool {
        false
    }

    override func makeWindowControllers() {
        let windowController = AnnotDocumentWindowController(document: self)
        addWindowController(windowController)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        Task { @MainActor in
            await self.documentManager.open(url: url)
        }
    }
}
