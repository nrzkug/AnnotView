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
    @ObservedObject private var colorMemory = AnnotationColorMemory.shared

    var body: some View {
        ReaderContentSplitView(
            isSidebarVisible: $chromeState.thumbnailSidebarIsPresented,
            isInspectorVisible: $chromeState.inspectorIsPresented,
            chromeHeight: $chromeState.titleBarHeight,
            annotationTool: chromeState.annotationTool,
            colorRevision: colorMemory.revision
        ) {
            SidebarPaneView()
                .environmentObject(documentManager)
                .environmentObject(chromeState)
        } main: {
            MainReaderPaneView()
                .environmentObject(documentManager)
                .environmentObject(chromeState)
                .environmentObject(searchController)
        } inspector: {
            InspectorPaneView()
                .environmentObject(documentManager)
                .environmentObject(chromeState)
        } tools: {
            AnnotationToolControlView(chromeState: chromeState)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, minHeight: 500)
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
}

private struct SidebarPaneView: View {
    @EnvironmentObject private var chromeState: ReaderChromeState

    var body: some View {
        ThumbnailSidebar()
            .padding(.top, chromeState.titleBarHeight + 14)
            .scrollContentBackground(.hidden)
    }
}

private struct InspectorPaneView: View {
    @EnvironmentObject private var chromeState: ReaderChromeState
    @State private var annotationStatusFilter: Annotation.Status?

    var body: some View {
        AnnotationSidebar(statusFilter: $annotationStatusFilter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, chromeState.titleBarHeight + 14)
    }
}

private struct MainReaderPaneView: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @EnvironmentObject private var chromeState: ReaderChromeState
    @EnvironmentObject private var searchController: PDFSearchController
    @FocusState private var searchFieldIsFocused: Bool

    var body: some View {
        reader
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
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
    }

    @ViewBuilder
    private var reader: some View {
        if let document = documentManager.document {
            PDFKitPageView(
                document: document,
                topContentInset: chromeState.titleBarHeight + (chromeState.searchIsPresented ? 40 : 0),
                annotationsByPage: documentManager.annotationsByPage,
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
                searchResultsRevision: searchController.resultsRevision,
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
            .background(Color(nsColor: .underPageBackgroundColor))
            .overlay(alignment: .top) {
                if !chromeState.searchIsPresented {
                    LinearGradient(
                        colors: [
                            Color(nsColor: .underPageBackgroundColor),
                            Color(nsColor: .underPageBackgroundColor).opacity(0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if chromeState.searchIsPresented {
                    searchBar
                        .padding(.top, chromeState.titleBarHeight)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No PDF Open", systemImage: "doc.richtext")
            } description: {
                Text("Open a PDF document to read and review annotations.")
            } actions: {
                Button("Open PDF…") {
                    documentManager.requestOpenPanel()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .ignoresSafeArea()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search PDF", text: $searchController.query)
                    .textFieldStyle(.plain)
                    .focused($searchFieldIsFocused)
                    .onSubmit {
                        if !searchController.results.isEmpty && !searchController.isSearching {
                            documentManager.selectNextSearchResult()
                        } else {
                            documentManager.performSearchAsync()
                        }
                    }
                    .onExitCommand {
                        chromeState.searchIsPresented = false
                    }

                if !searchController.query.isEmpty {
                    Button {
                        searchController.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .frame(minWidth: 180, idealWidth: 260, maxWidth: 360)

            if searchController.isSearching {
                ProgressView()
                    .controlSize(.mini)
            }

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
            .help("Previous Result (⇧⌘G)")

            Button {
                documentManager.selectNextSearchResult()
            } label: {
                Label("Next Result", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(searchController.results.isEmpty)
            .help("Next Result (⌘G)")

            Spacer(minLength: 0)

            Button {
                chromeState.searchIsPresented = false
            } label: {
                Label("Close Search", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .help("Close Search (Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .task(id: searchController.query) {
            let trimmed = searchController.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            documentManager.performSearchAsync()
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

    var opticalIconSize: CGFloat {
        switch self {
        case .selection, .underline, .strikeout: 15
        case .highlight, .note, .insertText: 16
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .selection: nil
        case .highlight: .highlight
        case .underline: .underline
        case .strikeout: .strikeout
        case .note: .note
        case .insertText: .caret
        }
    }
}

private struct AnnotationToolControlView: View {
    @ObservedObject var chromeState: ReaderChromeState

    var body: some View {
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
        Picker("Annotation Tool", selection: $chromeState.annotationTool.animation()) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                let size = tool.opticalIconSize
                Label {
                    Text(tool.label)
                } icon: {
                    Image(tool.iconName, bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size, height: size)
                }
                .tag(tool)
                .help(tool.label)
            }
        }
    }
}
