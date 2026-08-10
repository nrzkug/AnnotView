import SwiftUI

@MainActor
final class ReaderChromeState: ObservableObject {
    @Published var thumbnailSidebarIsPresented = true
    @Published var inspectorIsPresented = true
    @Published var searchIsPresented = false
}

/// Native macOS document layout: a source sidebar, PDF workspace, and inspector.
struct ContentView: View {
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @EnvironmentObject private var chromeState: ReaderChromeState
    @EnvironmentObject private var searchController: PDFSearchController
    @State private var annotationStatusFilter: Annotation.Status?
    @State private var annotationTool: AnnotationTool = .selection
    @FocusState private var searchFieldIsFocused: Bool

    private enum ColumnWidth {
        static let sidebarMin: CGFloat = 220
        static let sidebarIdeal: CGFloat = 260
        static let sidebarMax: CGFloat = 360
        static let detailMin: CGFloat = 300
        static let detailIdeal: CGFloat = 360
        static let detailMax: CGFloat = 720
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                chromeState.thumbnailSidebarIsPresented ? .all : .detailOnly
            },
            set: { visibility in
                chromeState.thumbnailSidebarIsPresented = (visibility != .detailOnly)
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebar
        } detail: {
            reader
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(documentManager.documentURL?.lastPathComponent ?? "AnnotView")
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
        .inspector(isPresented: $chromeState.inspectorIsPresented) {
            AnnotationSidebar(statusFilter: $annotationStatusFilter)
                .inspectorColumnWidth(
                    min: ColumnWidth.detailMin,
                    ideal: ColumnWidth.detailIdeal,
                    max: ColumnWidth.detailMax
                )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                annotationToolControl
            }

            if documentManager.isSavingAnnotation {
                ToolbarItem(placement: .primaryAction) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Saving annotation to the PDF")
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    chromeState.inspectorIsPresented.toggle()
                } label: {
                    Label("Annotations", systemImage: "sidebar.right")
                }
                .help("Show or hide annotations inspector")
            }
        }
        .toolbarRole(.editor)
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
    }

    @ViewBuilder
    private var annotationToolControl: some View {
        if #available(macOS 27.0, *) {
            annotationToolPicker
                .pickerStyle(.tabs)
                .labelStyle(.iconOnly)
                .fixedSize()
        } else {
            annotationToolPicker
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
        }
    }

    private var annotationToolPicker: some View {
        Picker("Annotation Tool", selection: $annotationTool) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Label(tool.label, systemImage: tool.symbolName)
                    .help(tool.label)
                    .tag(tool)
            }
        }
    }

    private var sidebar: some View {
        ThumbnailSidebar()
            .navigationSplitViewColumnWidth(
                min: ColumnWidth.sidebarMin,
                ideal: ColumnWidth.sidebarIdeal,
                max: ColumnWidth.sidebarMax
            )
    }

    @ViewBuilder
    private var reader: some View {
        if let document = documentManager.document {
            PDFKitPageView(
                document: document,
                annotations: documentManager.annotations,
                focusedAnnotation: documentManager.focusedAnnotation,
                annotationNavigationID: documentManager.annotationNavigationID,
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

    var symbolName: String {
        switch self {
        case .selection: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .note: "note.text.badge.plus"
        case .insertText: "text.cursor"
        }
    }
}
