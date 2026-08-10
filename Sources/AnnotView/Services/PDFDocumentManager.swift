import AppKit
import PDFKit

@MainActor
final class PDFDocumentManager: ObservableObject {
    private struct AnnotationHistoryOperation {
        enum Mutation {
            case delete(snapshots: [Annotation], sourceIDs: [String])
            case restore(snapshots: [Annotation])
            case update(sourceID: String, value: Annotation, inverse: Annotation)
        }

        let actionName: String
        let mutation: Mutation
    }

    private enum AnnotationHistoryError: LocalizedError {
        case documentUnavailable
        case unsupportedSnapshot
        case recreatedAnnotationsMissing
        case updatedAnnotationMissing

        var errorDescription: String? {
            switch self {
            case .documentUnavailable: "The PDF is no longer available."
            case .unsupportedSnapshot: "An annotation type in the history cannot be restored."
            case .recreatedAnnotationsMissing: "The restored annotations could not be found."
            case .updatedAnnotationMissing: "The updated annotation could not be found."
            }
        }
    }

    enum ZoomAction {
        case inwards
        case outwards
        case actualSize
        case fitPage
    }

    enum DocumentError: LocalizedError {
        case cannotOpen(URL)
        case cannotPrepare(URL, String)
        case pageMissing(Int)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let url): "Could not open \(url.lastPathComponent)."
            case .cannotPrepare(let url, let reason):
                "Could not prepare \(url.lastPathComponent) for display: \(reason)"
            case .pageMissing(let index): "Page \(index + 1) is unavailable."
            }
        }
    }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentURL: URL?
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var isLoadingAnnotations = false
    @Published private(set) var focusedAnnotation: Annotation?
    @Published private(set) var annotationNavigationID = 0
    @Published private(set) var selectedAnnotationID: UUID?
    @Published private(set) var zoomRequestID = 0
    @Published private(set) var zoomAction: ZoomAction = .fitPage
    @Published private(set) var recentDocuments: [URL] = []
    @Published private(set) var outlineItems: [DocumentOutlineItem] = []
    @Published private(set) var updatingAnnotationIDs: Set<UUID> = []
    @Published private(set) var isSavingAnnotation = false
    @Published private(set) var canUndoAnnotationChange = false
    @Published private(set) var canRedoAnnotationChange = false
    @Published private(set) var undoAnnotationTitle = "Undo"
    @Published private(set) var redoAnnotationTitle = "Redo"
    @Published var selectedPageIndex = 0
    @Published var errorMessage: String?

    let searchController: PDFSearchController

    private let annotationParser: any AnnotationParsing
    private let annotationStatusUpdater: any AnnotationStatusUpdating
    private let annotationWriter: any AnnotationWriting
    private let colorMemory: AnnotationColorMemory
    private let displayDocumentPreparer: any PDFDisplayDocumentPreparing
    private let recentDocumentStore: any RecentDocumentStoring
    private let documentPicker: any PDFDocumentPicking
    private let documentBuilder: any PDFDocumentBuilding
    private var checkedCommandLineForDocument = false
    private var annotationLoadID = UUID()
    private var annotationUndoHistory: [AnnotationHistoryOperation] = []
    private var annotationRedoHistory: [AnnotationHistoryOperation] = []
    private let renderedPageCache = NSCache<NSString, NSImage>()

    init(
        annotationParser: any AnnotationParsing = MuPDFAnnotationParser(),
        annotationStatusUpdater: any AnnotationStatusUpdating = MuPDFAnnotationStatusWriter(),
        annotationWriter: any AnnotationWriting = MuPDFAnnotationWriter(),
        colorMemory: AnnotationColorMemory = .shared,
        displayDocumentPreparer: any PDFDisplayDocumentPreparing = MuPDFDisplayDocumentPreparer(),
        recentDocumentStore: any RecentDocumentStoring = UserDefaultsRecentDocumentStore(),
        documentPicker: any PDFDocumentPicking = AppKitPDFDocumentPicker(),
        documentBuilder: any PDFDocumentBuilding = PDFKitDocumentBuilder(),
        searchController: PDFSearchController = PDFSearchController()
    ) {
        self.annotationParser = annotationParser
        self.annotationStatusUpdater = annotationStatusUpdater
        self.annotationWriter = annotationWriter
        self.colorMemory = colorMemory
        self.displayDocumentPreparer = displayDocumentPreparer
        self.recentDocumentStore = recentDocumentStore
        self.documentPicker = documentPicker
        self.documentBuilder = documentBuilder
        self.searchController = searchController
        renderedPageCache.countLimit = 48
        renderedPageCache.totalCostLimit = 24 * 1_024 * 1_024
        recentDocuments = recentDocumentStore.load()
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    func requestOpenPanel() {
        Task { await presentOpenPanel() }
    }

    func cancelOpenPanel() {
        documentPicker.cancel()
    }

    func openCommandLineDocumentIfPresent() async {
        guard !checkedCommandLineForDocument else { return }
        checkedCommandLineForDocument = true
        if let path = CommandLine.arguments.dropFirst().first(where: {
            !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf")
        }) {
            await open(url: URL(fileURLWithPath: path))
        }
    }

    func presentOpenPanel() async {
        guard let url = documentPicker.pickDocument() else { return }
        await open(url: url)
    }

    func open(url: URL) async {
        documentPicker.cancel()
        let loadID = UUID()
        annotationLoadID = loadID

        let displayData: Data
        do {
            displayData = try await displayDocumentPreparer.displayData(for: url)
        } catch {
            guard annotationLoadID == loadID else { return }
            errorMessage = DocumentError.cannotPrepare(url, error.localizedDescription).localizedDescription
            return
        }

        guard annotationLoadID == loadID else { return }
        guard let loaded = documentBuilder.build(from: displayData) else {
            errorMessage = DocumentError.cannotOpen(url).localizedDescription
            return
        }

        document = loaded.document
        outlineItems = loaded.outlineItems
        documentURL = url
        annotations = []
        renderedPageCache.removeAllObjects()
        focusedAnnotation = nil
        selectedAnnotationID = nil
        clearAnnotationHistory()
        searchController.reset()
        selectedPageIndex = 0
        errorMessage = nil
        recordRecentDocument(url)
        await loadAnnotations(id: loadID, documentURL: url)
    }

    func renderPage(pageIndex: Int, scale: CGFloat) throws -> NSImage {
        let cacheKey = RenderedPageKey(pageIndex: pageIndex, scale: scale)
        if let cached = renderedPageCache.object(forKey: cacheKey.value) { return cached }
        guard let page = document?.page(at: pageIndex) else {
            throw DocumentError.pageMissing(pageIndex)
        }

        let pageBounds = page.bounds(for: .cropBox)
        let size = CGSize(width: pageBounds.width * scale, height: pageBounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        let estimatedCost = max(1, Int(size.width * size.height * 4))
        renderedPageCache.setObject(image, forKey: cacheKey.value, cost: estimatedCost)
        return image
    }

    func getAnnotations(pageIndex: Int) -> [Annotation] {
        annotations.filter { $0.pageIndex == pageIndex }
    }

    func goTo(annotation: Annotation) {
        focusedAnnotation = annotation
        selectedAnnotationID = annotation.id
        annotationNavigationID += 1
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
    }

    func deselectAnnotation() {
        selectedAnnotationID = nil
    }

    func move(_ annotation: Annotation, to bounds: CGRect) async -> Bool {
        guard let documentURL, let sourceID = annotation.sourceID, !isSavingAnnotation else {
            return false
        }
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.move(
                in: documentURL,
                sourceID: sourceID,
                rect: bounds,
                modifiedAt: Date()
            )
            try await refreshAnnotations()
            if let updated = annotations.first(where: { $0.sourceID == sourceID }) {
                if focusedAnnotation?.id == annotation.id {
                    focusedAnnotation = updated
                }
            }
            return true
        } catch {
            errorMessage = "Annotation could not be moved: \(error.localizedDescription)"
            return false
        }
    }

    func updateStatus(of annotation: Annotation, to status: Annotation.Status) async {
        guard status != annotation.status,
              let documentURL,
              let sourceID = annotation.statusTargetSourceID else { return }
        updatingAnnotationIDs.insert(annotation.id)
        defer { updatingAnnotationIDs.remove(annotation.id) }
        do {
            try await annotationStatusUpdater.updateStatus(
                in: documentURL,
                sourceID: sourceID,
                status: status
            )
            guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            annotations[index].status = status
            if focusedAnnotation?.id == annotation.id {
                focusedAnnotation = annotations[index]
            }
        } catch {
            errorMessage = "Annotation status could not be updated: \(error.localizedDescription)"
        }
    }

    func createMarkup(kind: Annotation.Kind, selection: PDFMarkupSelection) async -> Annotation? {
        guard let documentURL, !selection.isEmpty, !isSavingAnnotation else { return nil }
        let existingSourceIDs = Set(annotations.compactMap(\.sourceID))
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.createMarkup(
                in: documentURL,
                kind: kind,
                selection: selection,
                contents: "",
                author: defaultAuthor,
                color: colorMemory.color(for: kind),
                createdAt: Date()
            )
            let created = try await refreshAnnotations(excluding: existingSourceIDs)
            recordAnnotationHistory(
                AnnotationHistoryOperation(
                    actionName: created.count == 1 ? "Add Annotation" : "Add Annotations",
                    mutation: .delete(
                        snapshots: created,
                        sourceIDs: created.compactMap(\.sourceID)
                    )
                )
            )
            return created.first
        } catch {
            errorMessage = "Text markup could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    func createNote(at location: PDFPagePoint) async -> Annotation? {
        guard let documentURL, !isSavingAnnotation else { return nil }
        let existingSourceIDs = Set(annotations.compactMap(\.sourceID))
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.createNote(
                in: documentURL,
                location: location,
                contents: "",
                author: defaultAuthor,
                color: colorMemory.color(for: .note),
                createdAt: Date()
            )
            let created = try await refreshAnnotations(excluding: existingSourceIDs)
            recordAnnotationHistory(
                AnnotationHistoryOperation(
                    actionName: "Add Annotation",
                    mutation: .delete(
                        snapshots: created,
                        sourceIDs: created.compactMap(\.sourceID)
                    )
                )
            )
            return created.first
        } catch {
            errorMessage = "Sticky note could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    func createCaret(at location: PDFPagePoint) async -> Annotation? {
        guard let documentURL, !isSavingAnnotation else { return nil }
        let existingSourceIDs = Set(annotations.compactMap(\.sourceID))
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.createCaret(
                in: documentURL,
                location: location,
                contents: "",
                author: defaultAuthor,
                color: colorMemory.color(for: .caret),
                createdAt: Date()
            )
            let created = try await refreshAnnotations(excluding: existingSourceIDs)
            recordAnnotationHistory(
                AnnotationHistoryOperation(
                    actionName: "Add Annotation",
                    mutation: .delete(
                        snapshots: created,
                        sourceIDs: created.compactMap(\.sourceID)
                    )
                )
            )
            return created.first
        } catch {
            errorMessage = "Text insertion could not be created: \(error.localizedDescription)"
            return nil
        }
    }

    func updateAnnotation(
        _ annotation: Annotation,
        contents: String,
        color: Annotation.Color
    ) async -> Bool {
        guard let documentURL, let sourceID = annotation.sourceID, !isSavingAnnotation else {
            return false
        }
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.update(
                in: documentURL,
                sourceID: sourceID,
                contents: contents,
                author: annotation.author ?? defaultAuthor,
                color: color,
                modifiedAt: Date()
            )
            try await refreshAnnotations()
            if let updated = annotations.first(where: { $0.sourceID == sourceID }) {
                colorMemory.set(color, for: updated.kind)
                recordAnnotationHistory(
                    AnnotationHistoryOperation(
                        actionName: "Edit Annotation",
                        mutation: .update(
                            sourceID: sourceID,
                            value: annotation,
                            inverse: updated
                        )
                    )
                )
                focusedAnnotation = updated
            }
            return true
        } catch {
            errorMessage = "Annotation could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func deleteAnnotation(_ annotation: Annotation) async -> Bool {
        guard let sourceID = annotation.sourceID else { return false }
        return await deleteAnnotations([annotation], sourceIDs: [sourceID], recordsHistory: true)
    }

    func undoAnnotationChange() async {
        await performAnnotationHistory(isUndo: true)
    }

    func redoAnnotationChange() async {
        await performAnnotationHistory(isUndo: false)
    }

    func performSearch() {
        if let pageIndex = searchController.perform(in: document) {
            selectedPageIndex = pageIndex
        }
    }

    func selectNextSearchResult() {
        if let pageIndex = searchController.selectNext(in: document) {
            selectedPageIndex = pageIndex
        }
    }

    func selectPreviousSearchResult() {
        if let pageIndex = searchController.selectPrevious(in: document) {
            selectedPageIndex = pageIndex
        }
    }

    func requestZoom(_ action: ZoomAction) {
        zoomAction = action
        zoomRequestID += 1
    }

    func clearRecentDocuments() {
        recentDocuments = []
        recentDocumentStore.clear()
    }

    private var defaultAuthor: String {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fullName.isEmpty ? NSUserName() : fullName
    }

    @discardableResult
    private func refreshAnnotations(excluding existingSourceIDs: Set<String> = []) async throws -> [Annotation] {
        guard let documentURL else { return [] }
        let parsed = try await annotationParser.annotations(in: documentURL)
        annotations = parsed
        return parsed.filter {
            guard let sourceID = $0.sourceID else { return false }
            return !existingSourceIDs.contains(sourceID)
        }
    }

    private func deleteAnnotations(
        _ snapshots: [Annotation],
        sourceIDs: [String],
        recordsHistory: Bool
    ) async -> Bool {
        guard let documentURL, !isSavingAnnotation else { return false }
        isSavingAnnotation = true
        defer { isSavingAnnotation = false }
        do {
            try await annotationWriter.perform(
                sourceIDs.map { .delete(sourceID: $0) },
                in: documentURL
            )
            try await refreshAnnotations()
            if recordsHistory {
                recordAnnotationHistory(
                    AnnotationHistoryOperation(
                        actionName: snapshots.count == 1
                            ? "Delete Annotation"
                            : "Delete Annotations",
                        mutation: .restore(snapshots: snapshots)
                    )
                )
            }
            if snapshots.contains(where: { $0.id == focusedAnnotation?.id }) {
                focusedAnnotation = nil
            }
            if snapshots.contains(where: { $0.id == selectedAnnotationID }) {
                selectedAnnotationID = nil
            }
            return true
        } catch {
            errorMessage = "Annotation could not be deleted: \(error.localizedDescription)"
            return false
        }
    }

    private func performAnnotationHistory(isUndo: Bool) async {
        guard !isSavingAnnotation else { return }
        guard let operation = isUndo
            ? annotationUndoHistory.popLast()
            : annotationRedoHistory.popLast() else { return }

        updateAnnotationHistoryAvailability()
        isSavingAnnotation = true
        defer {
            isSavingAnnotation = false
            updateAnnotationHistoryAvailability()
        }
        do {
            let inverse = try await executeAnnotationHistory(operation)
            if isUndo {
                annotationRedoHistory.append(inverse)
            } else {
                annotationUndoHistory.append(inverse)
            }
        } catch {
            if isUndo {
                annotationUndoHistory.append(operation)
            } else {
                annotationRedoHistory.append(operation)
            }
            errorMessage = "Annotation history action failed: \(error.localizedDescription)"
        }
    }

    private func executeAnnotationHistory(
        _ operation: AnnotationHistoryOperation
    ) async throws -> AnnotationHistoryOperation {
        guard let documentURL else { throw AnnotationHistoryError.documentUnavailable }

        switch operation.mutation {
        case let .delete(snapshots, sourceIDs):
            try await annotationWriter.perform(
                sourceIDs.map { .delete(sourceID: $0) },
                in: documentURL
            )
            try await refreshAnnotations()
            if snapshots.contains(where: { $0.id == focusedAnnotation?.id }) {
                focusedAnnotation = nil
            }
            if snapshots.contains(where: { $0.id == selectedAnnotationID }) {
                selectedAnnotationID = nil
            }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .restore(snapshots: snapshots)
            )

        case let .restore(snapshots):
            let mutations = snapshots.compactMap(creationMutation)
            guard mutations.count == snapshots.count else {
                throw AnnotationHistoryError.unsupportedSnapshot
            }
            let existingSourceIDs = Set(annotations.compactMap(\.sourceID))
            try await annotationWriter.perform(mutations, in: documentURL)
            let recreated = try await refreshAnnotations(excluding: existingSourceIDs)
            let recreatedSourceIDs = recreated.compactMap(\.sourceID)
            guard recreated.count == snapshots.count,
                  recreatedSourceIDs.count == recreated.count else {
                throw AnnotationHistoryError.recreatedAnnotationsMissing
            }
            if let first = recreated.first { goTo(annotation: first) }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .delete(snapshots: recreated, sourceIDs: recreatedSourceIDs)
            )

        case let .update(sourceID, value, inverse):
            try await annotationWriter.perform(
                [.update(
                    sourceID: sourceID,
                    contents: value.contents ?? "",
                    author: value.author ?? defaultAuthor,
                    color: value.color,
                    modifiedAt: Date()
                )],
                in: documentURL
            )
            try await refreshAnnotations()
            guard let updated = annotations.first(where: { $0.sourceID == sourceID }) else {
                throw AnnotationHistoryError.updatedAnnotationMissing
            }
            if focusedAnnotation?.sourceID == sourceID { focusedAnnotation = updated }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .update(sourceID: sourceID, value: inverse, inverse: updated)
            )
        }
    }

    private func recordAnnotationHistory(_ operation: AnnotationHistoryOperation) {
        if case let .delete(_, sourceIDs) = operation.mutation, sourceIDs.isEmpty { return }
        annotationUndoHistory.append(operation)
        annotationRedoHistory.removeAll()
        updateAnnotationHistoryAvailability()
    }

    private func clearAnnotationHistory() {
        annotationUndoHistory.removeAll()
        annotationRedoHistory.removeAll()
        updateAnnotationHistoryAvailability()
    }

    private func updateAnnotationHistoryAvailability() {
        canUndoAnnotationChange = !annotationUndoHistory.isEmpty
        canRedoAnnotationChange = !annotationRedoHistory.isEmpty
        undoAnnotationTitle = annotationUndoHistory.last.map { "Undo \($0.actionName)" } ?? "Undo"
        redoAnnotationTitle = annotationRedoHistory.last.map { "Redo \($0.actionName)" } ?? "Redo"
    }

    private func markupSelection(from annotation: Annotation) -> PDFMarkupSelection? {
        let points = annotation.quadPoints
        guard points.count >= 4 else { return nil }
        let quads = stride(from: 0, through: points.count - 4, by: 4).map { index in
            PDFMarkupQuad(
                topLeft: points[index],
                topRight: points[index + 1],
                bottomLeft: points[index + 2],
                bottomRight: points[index + 3]
            )
        }
        return PDFMarkupSelection(
            pages: [PDFMarkupPageSelection(pageIndex: annotation.pageIndex, quads: quads)],
            selectedText: ""
        )
    }

    private func creationMutation(from annotation: Annotation) -> AnnotationMutation? {
        if annotation.kind == .note {
            return .createNote(
                location: PDFPagePoint(
                    pageIndex: annotation.pageIndex,
                    point: CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
                ),
                contents: annotation.contents ?? "",
                author: annotation.author ?? defaultAuthor,
                color: annotation.color,
                createdAt: annotation.createdDate ?? Date()
            )
        }
        guard let selection = markupSelection(from: annotation) else { return nil }
        return .createMarkup(
            kind: annotation.kind,
            selection: selection,
            contents: annotation.contents ?? "",
            author: annotation.author ?? defaultAuthor,
            color: annotation.color,
            createdAt: annotation.createdDate ?? Date()
        )
    }

    private struct RenderedPageKey {
        let pageIndex: Int
        let scale: Int

        var value: NSString {
            "\(pageIndex):\(scale)" as NSString
        }

        init(pageIndex: Int, scale: CGFloat) {
            self.pageIndex = pageIndex
            self.scale = Int((scale * 1_000).rounded())
        }
    }

    private func recordRecentDocument(_ url: URL) {
        recentDocuments = recentDocumentStore.record(url)
    }

    private func loadAnnotations(id: UUID, documentURL: URL) async {
        isLoadingAnnotations = true
        defer {
            if annotationLoadID == id { isLoadingAnnotations = false }
        }
        do {
            let parsed = try await annotationParser.annotations(in: documentURL)
            guard annotationLoadID == id else { return }
            annotations = parsed
        } catch {
            guard annotationLoadID == id else { return }
            errorMessage = "Annotations could not be loaded: \(error.localizedDescription)"
        }
    }
}
