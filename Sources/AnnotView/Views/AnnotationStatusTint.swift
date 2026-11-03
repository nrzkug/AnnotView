import AppKit
import SwiftUI

extension Annotation.Status {
    var tint: Color {
        switch self {
        case .none, .unmarked: .secondary
        case .accepted: .green
        case .rejected: .red
        case .cancelled: .orange
        case .completed: .blue
        case .marked: .purple
        }
    }

    /// AppKit counterpart used by the native status menus.
    var nsTint: NSColor {
        switch self {
        case .none, .unmarked: .secondaryLabelColor
        case .accepted: .systemGreen
        case .rejected: .systemRed
        case .cancelled: .systemOrange
        case .completed: .systemBlue
        case .marked: .systemPurple
        }
    }
}
