import PDFKit
import SwiftUI

struct ThumbnailSidebar: View {
    private enum Mode: String, CaseIterable {
        case thumbnails = "Pages"
        case outline = "Outline"
    }

    @EnvironmentObject private var documentManager: PDFDocumentManager
    @State private var mode: Mode = .thumbnails

    private var hasOutline: Bool {
        !documentManager.outlineItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { option in
                    Text(option.rawValue)
                        .tag(option)
                        .disabled(option == .outline && !hasOutline)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Keep both segments in place. Removing Outline when a document has
            // none makes the remaining Pages segment expand into the centre.
            .padding(10)

            .onChange(of: hasOutline) { _, hasOutline in
                if !hasOutline {
                    mode = .thumbnails
                }
            }

            if let document = documentManager.document, mode == .thumbnails {
                List(selection: $documentManager.selectedPageIndex) {
                    ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                        VStack(spacing: 6) {
                            if let image = try? documentManager.renderPage(pageIndex: pageIndex, scale: 0.5) {
                                Image(nsImage: image)
                                    .interpolation(.high)
                                    .resizable()
                                    .scaledToFit()
                                    .shadow(radius: 1, y: 1)
                            }
                            Text("Page \(pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .tag(pageIndex)
                    }
                }
            } else if documentManager.document != nil, hasOutline {
                List(documentManager.outlineItems, children: \.childItems) { item in
                    Button {
                        if let pageIndex = item.pageIndex {
                            documentManager.selectedPageIndex = pageIndex
                        }
                    } label: {
                        Text(item.title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(item.pageIndex == nil)
                }
            } else if documentManager.document != nil {
                ContentUnavailableView("No Outline", systemImage: "list.bullet.indent")
            } else {
                ContentUnavailableView("Pages", systemImage: "rectangle.stack")
            }
        }
        .listStyle(.sidebar)
    }
}
