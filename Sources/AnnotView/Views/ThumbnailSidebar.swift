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
            .controlSize(.small)
            // Keep the intrinsic-width control centered as the sidebar resizes.
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            // Keep both segments in place when the document has no outline.
            .padding(.horizontal, 10)
            .onChange(of: hasOutline) { _, hasOutline in
                if !hasOutline {
                    mode = .thumbnails
                }
            }

            Divider()

            if let document = documentManager.document, mode == .thumbnails {
                List(selection: $documentManager.selectedPageIndex) {
                    ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                        PageThumbnailItem(pageIndex: pageIndex)
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
                ContentUnavailableView("No Document", systemImage: "doc", description: Text("Open a PDF to view pages or outline"))
            }
        }
        .listStyle(.sidebar)
    }
}

private struct PageThumbnailItem: View {
    let pageIndex: Int
    @EnvironmentObject private var documentManager: PDFDocumentManager
    @State private var thumbnail: NSImage?

    // Fixed-height media box so the row keeps a constant height whether the
    // thumbnail is still loading or has arrived. Variable-height rows make the
    // hosting view resize during NSTableCellView layout, which intermittently
    // throws an AppKit constraint exception on document open (macOS 26).
    private static let mediaHeight: CGFloat = 132

    private var pendingCount: Int {
        (documentManager.annotationsByPage[pageIndex] ?? [])
            .reduce(0) { $0 + ($1.status == .none ? 1 : 0) }
    }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = thumbnail ?? documentManager.cachedThumbnail(for: pageIndex, scale: 0.5) {
                    Image(nsImage: image)
                        .interpolation(.high)
                        .resizable()
                        .scaledToFit()
                        .shadow(radius: 1, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.15))
                        .aspectRatio(0.77, contentMode: .fit)
                        .overlay {
                            ProgressView()
                                .controlSize(.mini)
                        }
                }
            }
            .frame(height: Self.mediaHeight)
            .frame(maxWidth: .infinity)
            HStack(spacing: 5) {
                Text("Page \(pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16)
                        .frame(height: 15)
                        .background(Color.orange, in: Capsule())
                        .accessibilityLabel("\(pendingCount) pending annotations")
                }
            }
        }
        .padding(.vertical, 6)
        .tag(pageIndex)
        .task(id: "\(pageIndex)-\(documentManager.thumbnailRevision(for: pageIndex))") {
            thumbnail = await documentManager.renderPageAsync(pageIndex: pageIndex, scale: 0.5)
        }
    }
}
