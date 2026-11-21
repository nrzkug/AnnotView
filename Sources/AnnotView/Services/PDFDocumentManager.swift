import AppKit
import PDFKit

@MainActor
final class PDFDocumentManager: ObservableObject {
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
    @Published private(set) var annotations: [Annotation] = [] {
        didSet {
            annotationsByPage = Dictionary(grouping: annotations, by: \.pageIndex)
        }
    }
    @Published private(set) var isLoadingAnnotations = false
    @Published private(set) var focusedAnnotation: Annotation?
    @Published private(set) var annotationNavigationID = 0
    @Published private(set) var annotationPresentationRequest: AnnotationPresentationRequest = .sidebarNavigation
    @Published private(set) var selectedAnnotationID: UUID?
    @Published private(set) var selectedAnnotationIDs: Set<UUID> = []
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
    @Published private(set) var thumbnailRevision = 0
    @Published private(set) var pageThumbnailRevisions: [Int: Int] = [:]

    let searchController: PDFSearchController

    private let annotationParser: any AnnotationParsing
    private let annotationStatusUpdater: any AnnotationStatusUpdating
    private let annotationWriter: any AnnotationWriting
    private let colorMemory: AnnotationColorMemory
    private let displayDocumentPreparer: any PDFDisplayDocumentPreparing
    private let recentDocumentStore: any RecentDocumentStoring
    private let documentPicker: any PDFDocumentPicking
    private let documentBuilder: any PDFDocumentBuilding
    private var annotationLoadID = UUID()
    private var historyStore = AnnotationHistoryStore()
    private let thumbnailCache = PageThumbnailCache()
    private(set) var annotationsByPage: [Int: [Annotation]] = [:]
    private var activeMutationTail: Task<Void, Never>?

    init(
        annotationParser: any AnnotationParsing = SwiftPDFAnnotationParser(),
        annotationStatusUpdater: any AnnotationStatusUpdating = SwiftPDFAnnotationStatusWriter(),
        annotationWriter: any AnnotationWriting = SwiftPDFAnnotationWriter(),
        colorMemory: AnnotationColorMemory = .shared,
        displayDocumentPreparer: any PDFDisplayDocumentPreparing = SwiftPDFDisplayDocumentPreparer(),
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
        recentDocuments = recentDocumentStore.load()
    }

    var pageCount: Int { document?.pageCount ?? 0 }

    private var isMutatingDocument: Bool {
        isSavingAnnotation || !updatingAnnotationIDs.isEmpty
    }

    private func enqueueMutation<T: Sendable>(
        for loadID: UUID,
        fallback: T,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        let previous = activeMutationTail
        let task = Task<T, Never> { @MainActor [weak self] in
            await previous?.value
            guard let self, self.annotationLoadID == loadID else { return fallback }
            return await operation()
        }
        let tailTask = Task<Void, Never> { @MainActor in
            _ = await task.value
        }
        activeMutationTail = tailTask
        let result = await task.value
        if activeMutationTail == tailTask {
            activeMutationTail = nil
        }
        return result
    }

    func requestOpenPanel() {
        Task { await presentOpenPanel() }
    }

    func presentOpenPanel() async {
        guard let url = documentPicker.pickDocument() else { return }
        await open(url: url)
    }

    func open(url: URL) async {
        documentPicker.cancel()
        let loadID = UUID()
        annotationLoadID = loadID
        activeMutationTail = nil

        let annotationsTask = Task { [annotationParser] in
            try await annotationParser.annotations(in: url)
        }

        let loadedDocument: LoadedPDFDocument?
        // Fast path: Build directly from URL with in-memory non-link annotation stripping.
        // Bypasses subprocess invocation and disk re-compression, opening PDFs in milliseconds.
        if displayDocumentPreparer is SwiftPDFDisplayDocumentPreparer,
           let direct = await documentBuilder.load(from: url) {
            loadedDocument = direct
        } else {
            let displayData: Data
            do {
                displayData = try await displayDocumentPreparer.displayData(for: url)
            } catch {
                annotationsTask.cancel()
                guard annotationLoadID == loadID else { return }
                errorMessage = DocumentError.cannotPrepare(url, error.localizedDescription).localizedDescription
                return
            }

            guard annotationLoadID == loadID else {
                annotationsTask.cancel()
                return
            }
            loadedDocument = await documentBuilder.load(from: displayData)
        }

        guard annotationLoadID == loadID else {
            annotationsTask.cancel()
            return
        }
        guard let loaded = loadedDocument else {
            annotationsTask.cancel()
            errorMessage = DocumentError.cannotOpen(url).localizedDescription
            return
        }

        document = loaded.document
        outlineItems = loaded.outlineItems
        documentURL = url
        annotations = []
        isSavingAnnotation = false
        updatingAnnotationIDs = []
        thumbnailCache.reset()
        pageThumbnailRevisions.removeAll()
        thumbnailRevision += 1
        focusedAnnotation = nil
        annotationPresentationRequest = .sidebarNavigation
        selectedAnnotationID = nil
        selectedAnnotationIDs = []
        clearAnnotationHistory()
        searchController.reset()
        selectedPageIndex = 0
        errorMessage = nil
        recordRecentDocument(url)
        await loadAnnotations(id: loadID, task: annotationsTask)
    }

    func thumbnailRevision(for pageIndex: Int) -> Int {
        thumbnailRevision + (pageThumbnailRevisions[pageIndex] ?? 0)
    }

    func cachedThumbnail(for pageIndex: Int, scale: CGFloat) -> NSImage? {
        thumbnailCache.cachedThumbnail(for: pageIndex, scale: scale)
    }

    func renderPageAsync(pageIndex: Int, scale: CGFloat) async -> NSImage? {
        await thumbnailCache.renderPageAsync(
            pageIndex: pageIndex,
            scale: scale,
            document: document,
            documentURL: documentURL,
            annotations: getAnnotations(pageIndex: pageIndex)
        )
    }

    func renderPage(pageIndex: Int, scale: CGFloat) throws -> NSImage {
        if let cached = thumbnailCache.cachedThumbnail(for: pageIndex, scale: scale) {
            return cached
        }
        guard let page = document?.page(at: pageIndex) else {
            throw DocumentError.pageMissing(pageIndex)
        }
        return thumbnailCache.renderPageSync(
            pageIndex: pageIndex,
            scale: scale,
            page: page,
            annotations: getAnnotations(pageIndex: pageIndex)
        )
    }

    func invalidateThumbnailCache() {
        thumbnailCache.invalidateAll()
        pageThumbnailRevisions.removeAll()
        thumbnailRevision += 1
    }

    private func invalidateThumbnails(for pages: Set<Int>) {
        guard !pages.isEmpty else { return }
        thumbnailCache.invalidate(pages: pages)
        for page in pages {
            pageThumbnailRevisions[page, default: 0] += 1
        }
    }

    func getAnnotations(pageIndex: Int) -> [Annotation] {
        annotationsByPage[pageIndex] ?? []
    }

    func goTo(annotation: Annotation, preservingMultipleSelection: Bool = false) {
        focusedAnnotation = annotation
        annotationPresentationRequest = .sidebarNavigation
        selectedAnnotationID = annotation.id
        if preservingMultipleSelection {
            selectedAnnotationIDs.insert(annotation.id)
        } else {
            selectedAnnotationIDs = [annotation.id]
        }
        annotationNavigationID += 1
    }

    func selectAnnotation(_ id: UUID?) {
        selectedAnnotationID = id
        selectedAnnotationIDs = id.map { Set([$0]) } ?? []
    }

    func selectAnnotations(_ ids: Set<UUID>) {
        let availableIDs = Set(annotations.map(\.id))
        let selection = ids.intersection(availableIDs)
        let previousSelection = selectedAnnotationIDs
        selectedAnnotationIDs = selection

        guard !selection.isEmpty else {
            selectedAnnotationID = nil
            return
        }

        let newlySelected = selection.subtracting(previousSelection)
        let nextID = annotations.first(where: { newlySelected.contains($0.id) })?.id
            ?? selectedAnnotationID.flatMap { selection.contains($0) ? $0 : nil }
            ?? annotations.first(where: { selection.contains($0.id) })?.id
        guard let nextID,
              let annotation = annotations.first(where: { $0.id == nextID }) else { return }
        focusedAnnotation = annotation
        annotationPresentationRequest = .sidebarNavigation
        selectedAnnotationID = nextID
        annotationNavigationID += 1
    }

    func edit(annotation: Annotation) {
        focusedAnnotation = annotation
        annotationPresentationRequest = .explicitEdit
        selectedAnnotationID = annotation.id
        selectedAnnotationIDs = [annotation.id]
        annotationNavigationID += 1
    }

    func retainSelectedAnnotations(_ ids: Set<UUID>) {
        let retained = selectedAnnotationIDs.intersection(ids)
        guard retained != selectedAnnotationIDs else { return }
        selectedAnnotationIDs = retained
        if let selectedAnnotationID, !retained.contains(selectedAnnotationID) {
            self.selectedAnnotationID = annotations.first(where: { retained.contains($0.id) })?.id
        }
    }

    func deselectAnnotation() {
        selectedAnnotationID = nil
        selectedAnnotationIDs = []
    }

    func move(_ annotation: Annotation, to bounds: CGRect) async -> Bool {
        guard let targetURL = documentURL, let sourceID = annotation.sourceID else {
            return false
        }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: false) { [self] in
            guard self.documentURL == targetURL else { return false }
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID { self.isSavingAnnotation = false }
            }
            // Optimistically move the in-memory annotation so the overlay does not
            // snap back to the old position while the PDF is being rewritten.
            let originalAnnotation = self.annotations.first(where: { $0.id == annotation.id })
                ?? self.annotations.first(where: { $0.sourceID == sourceID })
            if let index = self.annotations.firstIndex(where: { $0.id == annotation.id }) {
                var moved = self.annotations[index]
                moved.bounds = bounds
                self.annotations[index] = moved
                if self.focusedAnnotation?.id == annotation.id {
                    self.focusedAnnotation = moved
                }
            }
            do {
                try await self.annotationWriter.move(
                    in: targetURL,
                    sourceID: sourceID,
                    rect: bounds,
                    modifiedAt: Date()
                )
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return false }
                try await self.refreshAnnotations(for: loadID, targetURL: targetURL)
                if let updated = self.annotations.first(where: { $0.sourceID == sourceID }) {
                    if self.focusedAnnotation?.id == annotation.id {
                        self.focusedAnnotation = updated
                    }
                }
                if let previousBounds = originalAnnotation?.bounds, previousBounds != bounds {
                    self.recordAnnotationHistory(
                        AnnotationHistoryOperation(
                            actionName: "Move Annotation",
                            mutation: .move(
                                sourceID: sourceID,
                                rect: previousBounds,
                                inverseRect: bounds
                            )
                        )
                    )
                }
                return true
            } catch {
                guard self.annotationLoadID == loadID else { return false }
                // The write did not reach disk. Restore the optimistic state so the
                // overlay continues to reflect the document the user actually has.
                if let originalAnnotation,
                   let index = self.annotations.firstIndex(where: { $0.id == annotation.id }) {
                    self.annotations[index] = originalAnnotation
                    if self.focusedAnnotation?.id == annotation.id {
                        self.focusedAnnotation = originalAnnotation
                    }
                }
                self.errorMessage = "Annotation could not be moved: \(error.localizedDescription)"
                return false
            }
        }
    }

    @discardableResult
    func updateStatus(of annotation: Annotation, to status: Annotation.Status) async -> Bool {
        await updateStatus(of: [annotation], to: status)
    }

    @discardableResult
    func updateStatus(of selectedAnnotations: [Annotation], to status: Annotation.Status) async -> Bool {
        guard let targetURL = documentURL else { return false }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: false) { [self] in
            guard self.documentURL == targetURL else { return false }
            let liveCandidates = selectedAnnotations.map { candidate in
                self.annotations.first(where: { $0.id == candidate.id })
                    ?? candidate.sourceID.flatMap { id in self.annotations.first(where: { $0.sourceID == id }) }
                    ?? candidate
            }
            let candidates = liveCandidates.filter {
                $0.status != status
                    && $0.statusTargetSourceID != nil
                    && !self.updatingAnnotationIDs.contains($0.id)
            }
            guard !candidates.isEmpty else {
                return !liveCandidates.isEmpty && liveCandidates.allSatisfy {
                    $0.status == status && $0.statusTargetSourceID != nil
                }
            }

            let candidateIDs = Set(candidates.map(\.id))
            self.updatingAnnotationIDs.formUnion(candidateIDs)
            defer {
                if self.annotationLoadID == loadID {
                    self.updatingAnnotationIDs.subtract(candidateIDs)
                }
            }

            var seenSourceIDs = Set<String>()
            let updates = candidates.compactMap { annotation -> AnnotationStatusUpdate? in
                guard let sourceID = annotation.statusTargetSourceID,
                      seenSourceIDs.insert(sourceID).inserted else { return nil }
                return AnnotationStatusUpdate(sourceID: sourceID, status: status)
            }
            do {
                try await self.annotationStatusUpdater.updateStatuses(
                    in: targetURL,
                    updates: updates
                )
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return false }
                for index in self.annotations.indices where candidateIDs.contains(self.annotations[index].id) {
                    self.annotations[index].status = status
                    if self.focusedAnnotation?.id == self.annotations[index].id {
                        self.focusedAnnotation = self.annotations[index]
                    }
                }
                self.invalidateThumbnails(for: Set(candidates.map(\.pageIndex)))
                return true
            } catch {
                guard self.annotationLoadID == loadID else { return false }
                self.errorMessage = candidates.count == 1
                    ? "Annotation status could not be updated: \(error.localizedDescription)"
                    : "Annotation statuses could not be updated: \(error.localizedDescription)"
                return false
            }
        }
    }

    func createMarkup(kind: Annotation.Kind, selection: PDFMarkupSelection) async -> Annotation? {
        guard let targetURL = documentURL, !selection.isEmpty else { return nil }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: nil) { [self] in
            guard self.documentURL == targetURL else { return nil }
            let existingSourceIDs = Set(self.annotations.compactMap(\.sourceID))
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID { self.isSavingAnnotation = false }
            }
            do {
                try await self.annotationWriter.createMarkup(
                    in: targetURL,
                    kind: kind,
                    selection: selection,
                    contents: "",
                    author: self.defaultAuthor,
                    color: self.colorMemory.color(for: kind),
                    createdAt: Date()
                )
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return nil }
                let created = try await self.refreshAnnotations(excluding: existingSourceIDs, for: loadID, targetURL: targetURL)
                guard !created.isEmpty else { return nil }
                self.recordAnnotationHistory(
                    AnnotationHistoryOperation(
                        actionName: created.count == 1 ? "Add Annotation" : "Add Annotations",
                        mutation: .delete(
                            snapshots: created,
                            sourceIDs: self.deletionSourceIDs(for: created)
                        )
                    )
                )
                return created.first
            } catch {
                guard self.annotationLoadID == loadID else { return nil }
                self.errorMessage = "Text markup could not be created: \(error.localizedDescription)"
                return nil
            }
        }
    }

    func createNote(at location: PDFPagePoint) async -> Annotation? {
        guard let targetURL = documentURL else { return nil }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: nil) { [self] in
            guard self.documentURL == targetURL else { return nil }
            let existingSourceIDs = Set(self.annotations.compactMap(\.sourceID))
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID { self.isSavingAnnotation = false }
            }
            do {
                try await self.annotationWriter.createNote(
                    in: targetURL,
                    location: location,
                    contents: "",
                    author: self.defaultAuthor,
                    color: self.colorMemory.color(for: .note),
                    createdAt: Date()
                )
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return nil }
                let created = try await self.refreshAnnotations(excluding: existingSourceIDs, for: loadID, targetURL: targetURL)
                guard !created.isEmpty else { return nil }
                self.recordAnnotationHistory(
                    AnnotationHistoryOperation(
                        actionName: "Add Annotation",
                        mutation: .delete(
                            snapshots: created,
                            sourceIDs: self.deletionSourceIDs(for: created)
                        )
                    )
                )
                return created.first
            } catch {
                guard self.annotationLoadID == loadID else { return nil }
                self.errorMessage = "Sticky note could not be created: \(error.localizedDescription)"
                return nil
            }
        }
    }

    func createCaret(at location: PDFPagePoint) async -> Annotation? {
        guard let targetURL = documentURL else { return nil }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: nil) { [self] in
            guard self.documentURL == targetURL else { return nil }
            let existingSourceIDs = Set(self.annotations.compactMap(\.sourceID))
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID { self.isSavingAnnotation = false }
            }
            do {
                try await self.annotationWriter.createCaret(
                    in: targetURL,
                    location: location,
                    contents: "",
                    author: self.defaultAuthor,
                    color: self.colorMemory.color(for: .caret),
                    createdAt: Date()
                )
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return nil }
                let created = try await self.refreshAnnotations(excluding: existingSourceIDs, for: loadID, targetURL: targetURL)
                guard !created.isEmpty else { return nil }
                self.recordAnnotationHistory(
                    AnnotationHistoryOperation(
                        actionName: "Add Annotation",
                        mutation: .delete(
                            snapshots: created,
                            sourceIDs: self.deletionSourceIDs(for: created)
                        )
                    )
                )
                return created.first
            } catch {
                guard self.annotationLoadID == loadID else { return nil }
                self.errorMessage = "Text insertion could not be created: \(error.localizedDescription)"
                return nil
            }
        }
    }

    func updateAnnotation(
        _ annotation: Annotation,
        contents: String
    ) async -> Bool {
        guard let targetURL = documentURL, let sourceID = annotation.sourceID else {
            return false
        }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: false) { [self] in
            guard self.documentURL == targetURL else { return false }
            let current = self.annotations.first(where: { $0.sourceID == sourceID }) ?? annotation
            let modifiedAt = Date()
            var mutations: [AnnotationMutation] = [
                .update(
                    sourceID: sourceID,
                    contents: contents,
                    author: current.author ?? self.defaultAuthor,
                    color: current.color,
                    modifiedAt: modifiedAt
                )
            ]
            if let companionID = current.statusTargetSourceID, companionID != sourceID {
                mutations.append(
                    .update(
                        sourceID: companionID,
                        contents: contents,
                        author: current.author ?? self.defaultAuthor,
                        color: nil,
                        modifiedAt: modifiedAt
                    )
                )
            }
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID { self.isSavingAnnotation = false }
            }
            do {
                try await self.annotationWriter.perform(mutations, in: targetURL)
                guard self.annotationLoadID == loadID, self.documentURL == targetURL else { return false }
                try await self.refreshAnnotations(for: loadID, targetURL: targetURL)
                if let updated = self.annotations.first(where: { $0.sourceID == sourceID }) {
                    self.recordAnnotationHistory(
                        AnnotationHistoryOperation(
                            actionName: "Edit Annotation",
                            mutation: .update(
                                sourceID: sourceID,
                                value: current,
                                inverse: updated
                            )
                        )
                    )
                    self.focusedAnnotation = updated
                }
                return true
            } catch {
                guard self.annotationLoadID == loadID else { return false }
                self.errorMessage = "Annotation could not be saved: \(error.localizedDescription)"
                return false
            }
        }
    }

    @discardableResult
    func deleteAnnotation(_ annotation: Annotation) async -> Bool {
        await deleteAnnotations([annotation])
    }

    @discardableResult
    func deleteAnnotations(_ selectedAnnotations: [Annotation]) async -> Bool {
        guard let targetURL = documentURL else { return false }
        let loadID = annotationLoadID
        return await enqueueMutation(for: loadID, fallback: false) { [self] in
            guard self.documentURL == targetURL else { return false }
            var seenSourceIDs = Set<String>()
            let deletable = selectedAnnotations.compactMap { candidate -> Annotation? in
                let live = self.annotations.first(where: { $0.id == candidate.id }) ?? candidate
                guard let sourceID = live.sourceID,
                      seenSourceIDs.insert(sourceID).inserted else { return nil }
                return live
            }
            let sourceIDs = self.deletionSourceIDs(for: deletable)
            guard !sourceIDs.isEmpty else { return false }
            return await self.performDeleteAnnotations(
                deletable,
                sourceIDs: sourceIDs,
                recordsHistory: deletable.allSatisfy { self.creationMutation(from: $0) != nil },
                for: loadID,
                targetURL: targetURL
            )
        }
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

    func performSearchAsync() {
        searchController.performAsync(in: document) { [weak self] pageIndex in
            self?.selectedPageIndex = pageIndex
        }
    }

    func close() {
        annotationLoadID = UUID()
        activeMutationTail = nil
        searchController.reset()
        thumbnailCache.reset()
        clearAnnotationHistory()
        document = nil
        documentURL = nil
        annotations = []
        outlineItems = []
        focusedAnnotation = nil
        selectedAnnotationID = nil
        selectedAnnotationIDs = []
        updatingAnnotationIDs = []
        isSavingAnnotation = false
        isLoadingAnnotations = false
        pageThumbnailRevisions.removeAll()
        errorMessage = nil
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
        if let custom = UserDefaults.standard.string(forKey: "defaultAuthorName")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return fullName.isEmpty ? NSUserName() : fullName
    }

    private func deletionSourceIDs(for items: [Annotation]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for item in items {
            if let sourceID = item.sourceID, seen.insert(sourceID).inserted {
                ids.append(sourceID)
            }
            if let companionID = item.statusTargetSourceID,
               companionID != item.sourceID,
               seen.insert(companionID).inserted {
                ids.append(companionID)
            }
        }
        return ids
    }

    @discardableResult
    private func refreshAnnotations(
        excluding existingSourceIDs: Set<String> = [],
        for loadID: UUID,
        targetURL: URL
    ) async throws -> [Annotation] {
        let parsed = try await annotationParser.annotations(in: targetURL)
        guard annotationLoadID == loadID, self.documentURL == targetURL else { return [] }
        replaceAnnotationsPreservingSelection(with: parsed)
        return parsed.filter {
            guard let sourceID = $0.sourceID else { return false }
            return !existingSourceIDs.contains(sourceID)
        }
    }

    private func performDeleteAnnotations(
        _ snapshots: [Annotation],
        sourceIDs: [String],
        recordsHistory: Bool,
        for loadID: UUID,
        targetURL: URL
    ) async -> Bool {
        isSavingAnnotation = true
        defer {
            if annotationLoadID == loadID { isSavingAnnotation = false }
        }
        do {
            try await annotationWriter.perform(
                sourceIDs.map { .delete(sourceID: $0) },
                in: targetURL
            )
            guard annotationLoadID == loadID, self.documentURL == targetURL else { return false }
            try await refreshAnnotations(for: loadID, targetURL: targetURL)
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
            guard annotationLoadID == loadID else { return false }
            errorMessage = "Annotation could not be deleted: \(error.localizedDescription)"
            return false
        }
    }

    private func performAnnotationHistory(isUndo: Bool) async {
        let loadID = annotationLoadID
        await enqueueMutation(for: loadID, fallback: ()) { [self] in
            guard let operation = isUndo
                ? self.historyStore.popUndo()
                : self.historyStore.popRedo() else { return }

            self.updateAnnotationHistoryAvailability()
            self.isSavingAnnotation = true
            defer {
                if self.annotationLoadID == loadID {
                    self.isSavingAnnotation = false
                    self.updateAnnotationHistoryAvailability()
                }
            }
            do {
                let inverse = try await self.executeAnnotationHistory(operation, for: loadID)
                guard self.annotationLoadID == loadID else { return }
                if isUndo {
                    self.historyStore.pushRedo(inverse)
                } else {
                    self.historyStore.pushUndo(inverse)
                }
            } catch {
                guard self.annotationLoadID == loadID else { return }
                if isUndo {
                    self.historyStore.pushUndo(operation)
                } else {
                    self.historyStore.pushRedo(operation)
                }
                self.errorMessage = "Annotation history action failed: \(error.localizedDescription)"
            }
        }
    }

    private func executeAnnotationHistory(
        _ operation: AnnotationHistoryOperation,
        for loadID: UUID
    ) async throws -> AnnotationHistoryOperation {
        guard let targetURL = documentURL, annotationLoadID == loadID else {
            throw AnnotationHistoryError.documentUnavailable
        }

        switch operation.mutation {
        case let .delete(snapshots, sourceIDs):
            try await annotationWriter.perform(
                sourceIDs.map { .delete(sourceID: $0) },
                in: targetURL
            )
            guard annotationLoadID == loadID, self.documentURL == targetURL else {
                throw AnnotationHistoryError.documentUnavailable
            }
            try await refreshAnnotations(for: loadID, targetURL: targetURL)
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

        case let .restore(unorderedSnapshots):
            // Recreated annotations come back from the parser in document order
            // (page by page, then append order within a page). Issue the
            // creations in that same order so `zip(snapshots, recreated)` pairs
            // each snapshot with its own recreated annotation.
            let snapshots = unorderedSnapshots.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.pageIndex != rhs.element.pageIndex
                        ? lhs.element.pageIndex < rhs.element.pageIndex
                        : lhs.offset < rhs.offset
                }
                .map(\.element)
            let mutations = snapshots.compactMap(creationMutation)
            guard mutations.count == snapshots.count else {
                throw AnnotationHistoryError.unsupportedSnapshot
            }
            let existingSourceIDs = Set(annotations.compactMap(\.sourceID))
            try await annotationWriter.perform(mutations, in: targetURL)
            guard annotationLoadID == loadID, self.documentURL == targetURL else {
                throw AnnotationHistoryError.documentUnavailable
            }
            var recreated = try await refreshAnnotations(
                excluding: existingSourceIDs,
                for: loadID,
                targetURL: targetURL
            )
            let recreatedSourceIDs = recreated.compactMap(\.sourceID)
            guard recreated.count == snapshots.count,
                  recreatedSourceIDs.count == recreated.count else {
                throw AnnotationHistoryError.recreatedAnnotationsMissing
            }

            let statusUpdates: [AnnotationStatusUpdate] = zip(snapshots, recreated).compactMap { snapshot, created in
                guard snapshot.status != .none,
                      let targetID = created.statusTargetSourceID else { return nil }
                return AnnotationStatusUpdate(sourceID: targetID, status: snapshot.status)
            }
            if !statusUpdates.isEmpty {
                try await annotationStatusUpdater.updateStatuses(in: targetURL, updates: statusUpdates)
                guard annotationLoadID == loadID, self.documentURL == targetURL else {
                    throw AnnotationHistoryError.documentUnavailable
                }
                try await refreshAnnotations(for: loadID, targetURL: targetURL)
                recreated = recreatedSourceIDs.compactMap { id in
                    annotations.first(where: { $0.sourceID == id })
                }
            }

            var sourceIDMap: [String: String] = [:]
            for (oldSnapshot, newAnnotation) in zip(snapshots, recreated) {
                if let oldID = oldSnapshot.sourceID, let newID = newAnnotation.sourceID {
                    sourceIDMap[oldID] = newID
                }
                // The deleted companion (e.g. an Acrobat Caret parent) is not
                // recreated as-is; point stale references at the new status target.
                if let oldCompanion = oldSnapshot.statusTargetSourceID,
                   oldCompanion != oldSnapshot.sourceID,
                   let newCompanion = newAnnotation.statusTargetSourceID ?? newAnnotation.sourceID {
                    sourceIDMap[oldCompanion] = newCompanion
                }
            }
            if !sourceIDMap.isEmpty {
                historyStore.remapSourceIDs(sourceIDMap)
            }

            if let first = recreated.first { goTo(annotation: first) }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .delete(
                    snapshots: recreated,
                    sourceIDs: deletionSourceIDs(for: recreated)
                )
            )

        case let .update(sourceID, value, inverse):
            var mutations: [AnnotationMutation] = [
                .update(
                    sourceID: sourceID,
                    contents: value.contents ?? "",
                    author: value.author ?? defaultAuthor,
                    color: value.color,
                    modifiedAt: Date()
                )
            ]
            if let companionID = value.statusTargetSourceID, companionID != sourceID {
                mutations.append(
                    .update(
                        sourceID: companionID,
                        contents: value.contents ?? "",
                        author: value.author ?? defaultAuthor,
                        color: nil,
                        modifiedAt: Date()
                    )
                )
            }
            try await annotationWriter.perform(mutations, in: targetURL)
            guard annotationLoadID == loadID, self.documentURL == targetURL else {
                throw AnnotationHistoryError.documentUnavailable
            }
            try await refreshAnnotations(for: loadID, targetURL: targetURL)
            guard let updated = annotations.first(where: { $0.sourceID == sourceID }) else {
                throw AnnotationHistoryError.updatedAnnotationMissing
            }
            if focusedAnnotation?.sourceID == sourceID { focusedAnnotation = updated }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .update(sourceID: sourceID, value: inverse, inverse: updated)
            )

        case let .move(sourceID, rect, inverseRect):
            try await annotationWriter.move(
                in: targetURL,
                sourceID: sourceID,
                rect: rect,
                modifiedAt: Date()
            )
            guard annotationLoadID == loadID, self.documentURL == targetURL else {
                throw AnnotationHistoryError.documentUnavailable
            }
            try await refreshAnnotations(for: loadID, targetURL: targetURL)
            guard let updated = annotations.first(where: { $0.sourceID == sourceID }) else {
                throw AnnotationHistoryError.updatedAnnotationMissing
            }
            if focusedAnnotation?.sourceID == sourceID { focusedAnnotation = updated }
            return AnnotationHistoryOperation(
                actionName: operation.actionName,
                mutation: .move(sourceID: sourceID, rect: inverseRect, inverseRect: updated.bounds)
            )
        }
    }

    private struct MarkedTextCacheKey: Hashable {
        let sourceID: String
        let pageIndex: Int
        let quadCoords: [CGFloat]
    }

    private struct CachedMarkedText {
        let value: String?
    }

    private func recordAnnotationHistory(_ operation: AnnotationHistoryOperation) {
        historyStore.record(operation)
        updateAnnotationHistoryAvailability()
    }

    private func replaceAnnotationsPreservingSelection(with replacements: [Annotation]) {
        let oldByPage = annotationsByPage
        let selectedSourceIDs = Set(annotations.lazy
            .filter { self.selectedAnnotationIDs.contains($0.id) }
            .compactMap(\.sourceID))
        let primarySourceID = annotations.first(where: { $0.id == selectedAnnotationID })?.sourceID
        let focusedSourceID = focusedAnnotation?.sourceID

        var cachedMarkedText: [MarkedTextCacheKey: CachedMarkedText] = [:]
        cachedMarkedText.reserveCapacity(annotations.count)
        for annotation in annotations {
            guard let sourceID = annotation.sourceID else { continue }
            let key = MarkedTextCacheKey(
                sourceID: sourceID,
                pageIndex: annotation.pageIndex,
                quadCoords: annotation.quadPoints.flatMap { [$0.x, $0.y] }
            )
            cachedMarkedText[key] = CachedMarkedText(value: annotation.markedText)
        }

        // Re-parsing mints a fresh id for every annotation; carry each
        // refreshed annotation's predecessor id over by sourceID. Otherwise
        // every id-keyed interaction — the open popover, hover state, the
        // selection — reads the refreshed annotation as a different one, and
        // the popover coordinator dismisses a preview that is still valid
        // (e.g. right after a comment save).
        var remapped = replacements
        var preservedIDs: [String: UUID] = [:]
        for annotation in annotations {
            if let sourceID = annotation.sourceID {
                preservedIDs[sourceID] = annotation.id
            }
        }
        for index in remapped.indices {
            guard let sourceID = remapped[index].sourceID,
                  let preservedID = preservedIDs[sourceID] else { continue }
            remapped[index].id = preservedID
        }
        for index in remapped.indices {
            if let sourceID = remapped[index].sourceID {
                let key = MarkedTextCacheKey(
                    sourceID: sourceID,
                    pageIndex: remapped[index].pageIndex,
                    quadCoords: remapped[index].quadPoints.flatMap { [$0.x, $0.y] }
                )
                if let cached = cachedMarkedText[key] {
                    remapped[index].markedText = cached.value
                    continue
                }
            }
            remapped[index].markedText = markedText(for: remapped[index])
        }

        annotations = remapped
        selectedAnnotationIDs = Set(remapped.lazy
            .filter { annotation in
                annotation.sourceID.map(selectedSourceIDs.contains) == true
            }
            .map(\.id))
        selectedAnnotationID = primarySourceID.flatMap { sourceID in
            remapped.first(where: { $0.sourceID == sourceID })?.id
        } ?? remapped.first(where: { selectedAnnotationIDs.contains($0.id) })?.id
        if let focusedSourceID {
            focusedAnnotation = remapped.first(where: { $0.sourceID == focusedSourceID })
        }

        let newByPage = annotationsByPage
        let allPages = Set(oldByPage.keys).union(newByPage.keys)
        let changedPages = Set(allPages.filter { oldByPage[$0] != newByPage[$0] })
        invalidateThumbnails(for: changedPages)
    }

    private func clearAnnotationHistory() {
        historyStore.clear()
        updateAnnotationHistoryAvailability()
    }

    private func updateAnnotationHistoryAvailability() {
        canUndoAnnotationChange = historyStore.canUndo
        canRedoAnnotationChange = historyStore.canRedo
        undoAnnotationTitle = historyStore.undoTitle
        redoAnnotationTitle = historyStore.redoTitle
    }

    /// Extracts the page text covered by the annotation's quads so the
    /// sidebar can show which passage a comment refers to.
    private func markedText(for annotation: Annotation) -> String? {
        let points = annotation.quadPoints
        guard points.count >= 4,
              let page = document?.page(at: annotation.pageIndex) else { return nil }
        var parts: [String] = []
        for index in stride(from: 0, through: points.count - 4, by: 4) {
            let quad = points[index...index + 3]
            let xs = quad.map(\.x)
            let ys = quad.map(\.y)
            let rect = CGRect(
                x: xs.min() ?? 0,
                y: ys.min() ?? 0,
                width: (xs.max() ?? 0) - (xs.min() ?? 0),
                height: (ys.max() ?? 0) - (ys.min() ?? 0)
            )
            guard let text = page.selection(for: rect)?.string else { continue }
            parts.append(text)
        }
        let joined = parts.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
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
        if annotation.kind == .caret {
            return .createCaret(
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

    private func recordRecentDocument(_ url: URL) {
        recentDocuments = recentDocumentStore.record(url)
    }

    private func loadAnnotations(
        id: UUID,
        task: Task<[Annotation], Error>
    ) async {
        isLoadingAnnotations = true
        defer {
            if annotationLoadID == id { isLoadingAnnotations = false }
        }
        do {
            let parsed = try await task.value
            guard annotationLoadID == id else { return }
            replaceAnnotationsPreservingSelection(with: parsed)
        } catch {
            guard annotationLoadID == id else { return }
            errorMessage = "Annotations could not be loaded: \(error.localizedDescription)"
        }
    }
}
