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
}

