import Foundation

struct DocumentOutlineItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let pageIndex: Int?
    let children: [DocumentOutlineItem]

    var childItems: [DocumentOutlineItem]? {
        children.isEmpty ? nil : children
    }
}
