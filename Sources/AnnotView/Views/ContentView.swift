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
                searchResults: searchController.results,
                currentSearchResultIndex: searchController.currentResultIndex,
                searchNavigationID: searchController.navigationID,
                zoomAction: documentManager.zoomAction,
                zoomRequestID: documentManager.zoomRequestID,
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
