import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class ReaderChromeState: ObservableObject {
    @Published var thumbnailSidebarIsPresented: Bool {
        didSet { defaults.set(thumbnailSidebarIsPresented, forKey: Keys.sidebarVisible) }
    }
    @Published var inspectorIsPresented: Bool {
        didSet { defaults.set(inspectorIsPresented, forKey: Keys.inspectorVisible) }
    }
    @Published var searchIsPresented = false
    @Published var annotationTool: AnnotationTool = .selection
    @Published var hasMarkupSelection = false
    @Published var titleBarHeight: CGFloat = 52

    private let defaults: UserDefaults

    private enum Keys {
        static let sidebarVisible = "readerSidebarVisible"
        static let inspectorVisible = "readerInspectorVisible"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.sidebarVisible: true,
            Keys.inspectorVisible: true,
        ])
        thumbnailSidebarIsPresented = defaults.bool(forKey: Keys.sidebarVisible)
        inspectorIsPresented = defaults.bool(forKey: Keys.inspectorVisible)
    }
}

/// Native macOS document layout: a source sidebar, PDF workspace, and inspector.
struct ContentView: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @EnvironmentObject private var chromeState: ReaderChromeState
    @EnvironmentObject private var searchController: PDFSearchController
    @State private var annotationStatusFilter: Annotation.Status?
    @FocusState private var searchFieldIsFocused: Bool

    var body: some View {
        ReaderContentSplitView(
            isSidebarVisible: $chromeState.thumbnailSidebarIsPresented,
            isInspectorVisible: $chromeState.inspectorIsPresented,
            chromeHeight: $chromeState.titleBarHeight
        ) {
            ThumbnailSidebar()
                .padding(.top, chromeState.titleBarHeight + 12)
                .scrollContentBackground(.hidden)
        } main: {
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } inspector: {
            AnnotationSidebar(statusFilter: $annotationStatusFilter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, chromeState.titleBarHeight + 12)
        } tools: {
            annotationToolControl
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: searchController.query) { _, query in
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchController.reset()
            }
        }
        .onChange(of: chromeState.searchIsPresented) { _, isPresented in
            searchFieldIsFocused = isPresented
            if !isPresented {
                searchController.query = ""
            }
        }
        .frame(minWidth: 1_000, minHeight: 620)
        .alert(
            "AnnotView",
            isPresented: Binding(
                get: { documentManager.errorMessage != nil },
                set: { if !$0 { documentManager.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentManager.errorMessage ?? "Unknown error")
        }
        .onReceive(NotificationCenter.default.publisher(for: .annotViewToolDidChange)) { notification in
            if let view = notification.object as? AnnotationPDFView,
               view.document === documentManager.document,
               let tool = notification.userInfo?["tool"] as? AnnotationTool {
                chromeState.annotationTool = tool
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .PDFViewSelectionChanged)
                .receive(on: RunLoop.main)
        ) { notification in
            if let view = notification.object as? AnnotationPDFView,
               view.document === documentManager.document {
                chromeState.hasMarkupSelection = view.markupSelection() != nil
            }
        }
        .onChange(of: documentManager.documentURL) {
            chromeState.hasMarkupSelection = false
        }
    }

    @ViewBuilder
    private var annotationToolControl: some View {
        Group {
            if #available(macOS 27.0, *) {
                annotationToolPicker
                    .pickerStyle(.tabs)
                    .labelStyle(.iconOnly)
                    .fixedSize()
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: Capsule())
            } else {
                annotationToolPicker
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .fixedSize()
            }
        }
    }

    private var annotationToolPicker: some View {
        Picker("Annotation Tool", selection: $chromeState.annotationTool) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Label {
                    Text(tool.label)
                } icon: {
                    Image(tool.iconName, bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .tag(tool)
                .help(tool.label)
            }
        }
    }

    @ViewBuilder
    private var reader: some View {
        if let document = documentManager.document {
            PDFKitPageView(
                document: document,
                topContentInset: chromeState.titleBarHeight,
                annotations: documentManager.annotations,
                focusedAnnotation: documentManager.focusedAnnotation,
                annotationNavigationID: documentManager.annotationNavigationID,
                annotationPresentationRequest: documentManager.annotationPresentationRequest,
                selectedAnnotationID: documentManager.selectedAnnotationID,
                onSelectAnnotationRequest: { id in
                    documentManager.selectAnnotation(id)
                },
                onDeselectAnnotationRequest: {
                    documentManager.deselectAnnotation()
                },
                searchResults: searchController.results,
                currentSearchResultIndex: searchController.currentResultIndex,
                searchNavigationID: searchController.navigationID,
                zoomAction: documentManager.zoomAction,
                zoomRequestID: documentManager.zoomRequestID,
                annotationTool: chromeState.annotationTool,
                onCreateMarkupRequest: { kind, selection in
                    Task { await documentManager.createMarkup(kind: kind, selection: selection) }
                },
                onCreateNoteRequest: { location in
                    Task { await documentManager.createNote(at: location) }
                },
                onCreateInsertTextRequest: { location in
                    Task { await documentManager.createCaret(at: location) }
                },
                onUpdateAnnotation: { annotation, contents in
                    await documentManager.updateAnnotation(
                        annotation,
                        contents: contents
                    )
                },
                onUpdateStatus: { annotation, status in
                    await documentManager.updateStatus(of: annotation, to: status)
                },
                onMoveAnnotationRequest: { annotation, rect in
                    Task { await documentManager.move(annotation, to: rect) }
                },
                onDeleteAnnotation: { annotation in
                    guard await AnnotationDeleteConfirmation.confirm(
                        count: 1,
                        from: NSApp.keyWindow ?? NSApp.mainWindow
                    ) else { return false }
                    return await documentManager.deleteAnnotation(annotation)
                },
                selectedPageIndex: $documentManager.selectedPageIndex
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if chromeState.searchIsPresented {
                    searchBar
                }
            }
        } else {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search PDF", text: $searchController.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFieldIsFocused)
                .onSubmit {
                    documentManager.performSearch()
                }
                .onExitCommand {
                    chromeState.searchIsPresented = false
                }
                .frame(minWidth: 180, idealWidth: 260, maxWidth: 360)

            Text(searchController.resultSummary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)

            Button {
                documentManager.selectPreviousSearchResult()
            } label: {
                Label("Previous Result", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(searchController.results.isEmpty)

            Button {
                documentManager.selectNextSearchResult()
            } label: {
                Label("Next Result", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(searchController.results.isEmpty)

            Button {
                chromeState.searchIsPresented = false
            } label: {
                Label("Close Search", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

extension AnnotationTool {
    var label: String {
        switch self {
        case .selection: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikethrough"
        case .note: "Sticky Note"
        case .insertText: "Insert Text"
        }
    }

    var iconName: String {
        switch self {
        case .selection: "mouse-pointer-2"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "message-square-text"
        case .insertText: "text-cursor-input"
        }
    }
}
