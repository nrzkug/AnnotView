import Foundation

/// Remembers the color last used for each annotation kind, like Acrobat's
/// per-tool "last used" color. New annotations start from the colors Acrobat
/// actually produces in the user's documents (e.g. purple-blue sticky notes,
/// purple Insert-Text carets), then adopt whatever color the user last picked.
@MainActor
final class AnnotationColorMemory {
    static let shared = AnnotationColorMemory()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func color(for kind: Annotation.Kind) -> Annotation.Color {
        guard let stored = defaults.string(forKey: key(for: kind)) else {
            return Self.initialDefault(for: kind)
        }
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return Self.initialDefault(for: kind) }
        return Annotation.Color(
            red: parts[0], green: parts[1], blue: parts[2], alpha: parts[3]
        )
    }

    func set(_ color: Annotation.Color, for kind: Annotation.Kind) {
        defaults.set(
            "\(color.red),\(color.green),\(color.blue),\(color.alpha)",
            forKey: key(for: kind)
        )
    }

    private func key(for kind: Annotation.Kind) -> String {
        "annotationColor.\(kind.rawValue)"
    }

    /// Colors Acrobat writes for fresh annotations in the user's documents:
    /// sticky notes are purple-blue, Insert-Text carets purple, strikethrough
    /// and ink use Acrobat's soft red, highlights yellow at 0.4 opacity.
    private static func initialDefault(for kind: Annotation.Kind) -> Annotation.Color {
        switch kind {
        case .highlight:
            Annotation.Color(red: 1, green: 0.819611, blue: 0, alpha: 0.4)
        case .underline:
            Annotation.Color(red: 0.243, green: 0.725, blue: 0.353, alpha: 1)
        case .strikeout, .ink:
            Annotation.Color(red: 0.972549, green: 0.392151, blue: 0.392151, alpha: 1)
        case .note:
            Annotation.Color(red: 0.588242, green: 0.262741, blue: 0.988235, alpha: 1)
        case .caret:
            Annotation.Color(red: 0.752945, green: 0.215683, blue: 0.768631, alpha: 1)
        }
    }
}
