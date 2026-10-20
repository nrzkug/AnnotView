import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReaderChromeState: ObservableObject {
    @Published var thumbnailSidebarIsPresented = true
    @Published var inspectorIsPresented = true
    @Published var searchIsPresented = false
    @Published var titleBarHeight: CGFloat = 52
}

/// Native macOS document layout: a source sidebar, PDF workspace, and inspector.
struct ContentView: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @EnvironmentObject private var chromeState: ReaderChromeState
    @EnvironmentObject private var searchController: PDFSearchController
    @State private var annotationStatusFilter: Annotation.Status?
    @State private var annotationTool: AnnotationTool = .selection
    @FocusState private var searchFieldIsFocused: Bool

    var body: some View {
        ReaderContentSplitView(
            isSidebarVisible: $chromeState.thumbnailSidebarIsPresented,
            isInspectorVisible: $chromeState.inspectorIsPresented,
            chromeHeight: $chromeState.titleBarHeight
        ) {
            ThumbnailSidebar()
                .padding(.top, chromeState.titleBarHeight)
                .scrollContentBackground(.hidden)
        } main: {
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } inspector: {
            AnnotationSidebar(statusFilter: $annotationStatusFilter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, chromeState.titleBarHeight)
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
            if let tool = notification.userInfo?["tool"] as? AnnotationTool {
                annotationTool = tool
            }
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
        Picker("Annotation Tool", selection: $annotationTool) {
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
                annotationTool: annotationTool,
                onCreateMarkupRequest: { kind, selection in
                    Task { await documentManager.createMarkup(kind: kind, selection: selection) }
                },
                onCreateNoteRequest: { location in
                    Task { await documentManager.createNote(at: location) }
                },
                onCreateInsertTextRequest: { location in
                    Task { await documentManager.createCaret(at: location) }
                },
                onUpdateAnnotation: { annotation, contents, color in
                    await documentManager.updateAnnotation(
                        annotation,
                        contents: contents,
                        color: color
                    )
                },
                onMoveAnnotationRequest: { annotation, rect in
                    Task { await documentManager.move(annotation, to: rect) }
                },
                onDeleteAnnotation: { annotation in
                    await documentManager.deleteAnnotation(annotation)
                },
                selectedPageIndex: $documentManager.selectedPageIndex
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .safeAreaInset(edge: .top, spacing: 0) {
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
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private extension AnnotationTool {
    var label: String {
        switch self {
        case .selection: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeout: "Strikeout"
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
        case .note: "sticky-note"
        case .insertText: "text-cursor-input"
        }
    }
}
