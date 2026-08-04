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
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var isLoadingAnnotations = false
    @Published private(set) var focusedAnnotation: Annotation?
    @Published private(set) var annotationNavigationID = 0
    @Published private(set) var zoomRequestID = 0
    @Published private(set) var zoomAction: ZoomAction = .fitPage
    @Published private(set) var recentDocuments: [URL] = []
    @Published private(set) var outlineItems: [DocumentOutlineItem] = []
    @Published private(set) var updatingAnnotationIDs: Set<UUID> = []
    @Published var selectedPageIndex = 0
    @Published var errorMessage: String?

    let searchController: PDFSearchController

    private let annotationParser: any AnnotationParsing
    private let annotationStatusUpdater: any AnnotationStatusUpdating
    private let displayDocumentPreparer: any PDFDisplayDocumentPreparing
    private let recentDocumentStore: any RecentDocumentStoring
    private let documentPicker: any PDFDocumentPicking
    private let documentBuilder: any PDFDocumentBuilding
    private var checkedCommandLineForDocument = false
    private var annotationLoadID = UUID()
    private let renderedPageCache = NSCache<NSString, NSImage>()

    init(
        annotationParser: any AnnotationParsing = MuPDFAnnotationParser(),
        annotationStatusUpdater: any AnnotationStatusUpdating = MuPDFAnnotationStatusWriter(),
        displayDocumentPreparer: any PDFDisplayDocumentPreparing = MuPDFDisplayDocumentPreparer(),
        recentDocumentStore: any RecentDocumentStoring = UserDefaultsRecentDocumentStore(),
        documentPicker: any PDFDocumentPicking = AppKitPDFDocumentPicker(),
        documentBuilder: any PDFDocumentBuilding = PDFKitDocumentBuilder(),
        searchController: PDFSearchController = PDFSearchController()
    ) {
        self.annotationParser = annotationParser
        self.annotationStatusUpdater = annotationStatusUpdater
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
        annotationNavigationID += 1
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
