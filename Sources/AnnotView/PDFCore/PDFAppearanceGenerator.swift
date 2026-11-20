import CoreGraphics
import Foundation

/// Generates Acrobat-, Preview-, and Chrome-compatible PDF `/AP` (`/N` Form XObject)
/// appearance streams directly in PDF user space.
enum PDFAppearanceGenerator {
    struct Color: Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let opacity: Double

        init(red: Double, green: Double, blue: Double, opacity: Double = 1.0) {
            self.red = min(max(red, 0), 1)
            self.green = min(max(green, 0), 1)
            self.blue = min(max(blue, 0), 1)
            self.opacity = min(max(opacity, 0), 1)
        }

        init(_ color: Annotation.Color) {
            self.init(
                red: Double(color.red),
                green: Double(color.green),
                blue: Double(color.blue),
                opacity: Double(color.alpha)
            )
        }
    }

    // MARK: - Highlight

    /// Generates a Highlight Form XObject stream using `/BM /Multiply` so text underneath
    /// stays crisp in Acrobat, Preview, and Chrome.
    ///
    /// - Parameters:
    ///   - quads: Quadrilaterals in PDF user space (Acrobat Z-order: TL, TR, BL, BR).
    ///   - rect: Bounding `/Rect` of the annotation in PDF user space.
    ///   - color: Fill color and opacity.
    static func highlightStream(
        quads: [PDFMarkupQuad],
        rect: CGRect,
        color: Color
    ) -> PDFObject {
        var commands: [String] = []
        commands.append("q")
        commands.append("/GS0 gs")
        commands.append("\(fmt(color.red)) \(fmt(color.green)) \(fmt(color.blue)) rg")

        for quad in quads {
            // Walk perimeter: topLeft -> topRight -> bottomRight -> bottomLeft -> close
            commands.append("\(fmt(quad.topLeft.x)) \(fmt(quad.topLeft.y)) m")
            commands.append("\(fmt(quad.topRight.x)) \(fmt(quad.topRight.y)) l")
            commands.append("\(fmt(quad.bottomRight.x)) \(fmt(quad.bottomRight.y)) l")
            commands.append("\(fmt(quad.bottomLeft.x)) \(fmt(quad.bottomLeft.y)) l")
            commands.append("h")
        }
        if !quads.isEmpty {
            commands.append("f")
        }
        commands.append("Q")

        let streamData = Data((commands.joined(separator: "\n") + "\n").utf8)
        let extGState: PDFObject = .dict([
            "Type": .name("ExtGState"),
            "BM": .name("Multiply"),
            "ca": .real(color.opacity),
            "CA": .real(color.opacity),
        ])
        let resources: PDFObject = .dict([
            "ExtGState": .dict(["GS0": extGState]),
        ])
        let dict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .int(1),
            "BBox": rectArray(rect),
            "Resources": resources,
            "Length": .int(Int64(streamData.count)),
        ]
        return .stream(dict: dict, data: streamData)
    }

    // MARK: - Underline

    /// Generates an Underline Form XObject stream stroking the bottom edge of each quad.
    static func underlineStream(
        quads: [PDFMarkupQuad],
        rect: CGRect,
        color: Color
    ) -> PDFObject {
        var commands: [String] = []
        commands.append("q")
        commands.append("/GS0 gs")
        commands.append("1 w")
        commands.append("0 J")
        commands.append("\(fmt(color.red)) \(fmt(color.green)) \(fmt(color.blue)) RG")

        for quad in quads {
            // Inset slightly upward from the bottom edge so a 1pt stroke is never clipped by BBox.
            let leftDx = quad.topLeft.x - quad.bottomLeft.x
            let leftDy = quad.topLeft.y - quad.bottomLeft.y
            let leftLen = hypot(leftDx, leftDy)
            let rightDx = quad.topRight.x - quad.bottomRight.x
            let rightDy = quad.topRight.y - quad.bottomRight.y
            let rightLen = hypot(rightDx, rightDy)

            let start: CGPoint
            let end: CGPoint
            if leftLen > 1.0 && rightLen > 1.0 {
                let inset = min(0.5, min(leftLen, rightLen) * 0.1)
                start = CGPoint(
                    x: quad.bottomLeft.x + (leftDx / leftLen) * inset,
                    y: quad.bottomLeft.y + (leftDy / leftLen) * inset
                )
                end = CGPoint(
                    x: quad.bottomRight.x + (rightDx / rightLen) * inset,
                    y: quad.bottomRight.y + (rightDy / rightLen) * inset
                )
            } else {
                start = quad.bottomLeft
                end = quad.bottomRight
            }

            commands.append("\(fmt(start.x)) \(fmt(start.y)) m")
            commands.append("\(fmt(end.x)) \(fmt(end.y)) l")
            commands.append("S")
        }
        commands.append("Q")

        let streamData = Data((commands.joined(separator: "\n") + "\n").utf8)
        let extGState: PDFObject = .dict([
            "Type": .name("ExtGState"),
            "ca": .real(color.opacity),
            "CA": .real(color.opacity),
        ])
        let resources: PDFObject = .dict([
            "ExtGState": .dict(["GS0": extGState]),
        ])
        let dict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .int(1),
            "BBox": rectArray(rect),
            "Resources": resources,
            "Length": .int(Int64(streamData.count)),
        ]
        return .stream(dict: dict, data: streamData)
    }

    // MARK: - StrikeOut

    /// Generates a StrikeOut Form XObject stream stroking along the vertical midpoint of each quad.
    static func strikeOutStream(
        quads: [PDFMarkupQuad],
        rect: CGRect,
        color: Color
    ) -> PDFObject {
        var commands: [String] = []
        commands.append("q")
        commands.append("/GS0 gs")
        commands.append("1 w")
        commands.append("0 J")
        commands.append("\(fmt(color.red)) \(fmt(color.green)) \(fmt(color.blue)) RG")

        for quad in quads {
            let start = CGPoint(
                x: (quad.bottomLeft.x + quad.topLeft.x) * 0.5,
                y: (quad.bottomLeft.y + quad.topLeft.y) * 0.5
            )
            let end = CGPoint(
                x: (quad.bottomRight.x + quad.topRight.x) * 0.5,
                y: (quad.bottomRight.y + quad.topRight.y) * 0.5
            )
            commands.append("\(fmt(start.x)) \(fmt(start.y)) m")
            commands.append("\(fmt(end.x)) \(fmt(end.y)) l")
            commands.append("S")
        }
        commands.append("Q")

        let streamData = Data((commands.joined(separator: "\n") + "\n").utf8)
        let extGState: PDFObject = .dict([
            "Type": .name("ExtGState"),
            "ca": .real(color.opacity),
            "CA": .real(color.opacity),
        ])
        let resources: PDFObject = .dict([
            "ExtGState": .dict(["GS0": extGState]),
        ])
        let dict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .int(1),
            "BBox": rectArray(rect),
            "Resources": resources,
            "Length": .int(Int64(streamData.count)),
        ]
        return .stream(dict: dict, data: streamData)
    }

    // MARK: - Text (Sticky Note)

    /// Generates a clean 20×20 sticky-note speech-bubble icon Form XObject.
    static func noteStream(color: Color) -> PDFObject {
        // Darkened border for crisp contrast on light pages.
        let strokeR = max(0, color.red * 0.45)
        let strokeG = max(0, color.green * 0.45)
        let strokeB = max(0, color.blue * 0.45)

        let commands: [String] = [
            "q",
            "/GS0 gs",
            "\(fmt(color.red)) \(fmt(color.green)) \(fmt(color.blue)) rg",
            "\(fmt(strokeR)) \(fmt(strokeG)) \(fmt(strokeB)) RG",
            "1 w",
            "1 j",
            "1 J",
            // Speech bubble body inside 20x20 box
            "3.5 18 m",
            "16.5 18 l",
            "17.88 18 19 16.88 19 15.5 c",
            "19 7.5 l",
            "19 6.12 17.88 5 16.5 5 c",
            "9 5 l",
            "4.5 1.5 l",
            "5.5 5 l",
            "3.5 5 l",
            "2.12 5 1 6.12 1 7.5 c",
            "1 15.5 l",
            "1 16.88 2.12 18 3.5 18 c",
            "h",
            "B",
            // Horizontal note lines inside the bubble
            "0.9 w",
            "4.5 13.5 m 15.5 13.5 l S",
            "4.5 10.75 m 15.5 10.75 l S",
            "4.5 8 m 11.5 8 l S",
            "Q",
        ]

        let streamData = Data((commands.joined(separator: "\n") + "\n").utf8)
        let extGState: PDFObject = .dict([
            "Type": .name("ExtGState"),
            "ca": .real(color.opacity),
            "CA": .real(color.opacity),
        ])
        let resources: PDFObject = .dict([
            "ExtGState": .dict(["GS0": extGState]),
        ])
        let dict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .int(1),
            "BBox": .array([.int(0), .int(0), .int(20), .int(20)]),
            "Resources": resources,
            "Length": .int(Int64(streamData.count)),
        ]
        return .stream(dict: dict, data: streamData)
    }

    // MARK: - Caret

    /// Generates the exact Caret Form XObject stream matching `MuPDFBridge.c:write_caret_appearance_stream`.
    static func caretStream(color: Color) -> PDFObject {
        let r = fmt(color.red)
        let g = fmt(color.green)
        let b = fmt(color.blue)
        let glyph = """
        \(r) \(g) \(b) RG
        0.6007 w
        \(r) \(g) \(b) rg
        0 0 m
        3.8227 0 3.8227 3.0035 3.8227 6.007 c
        3.8227 3.0035 3.8227 0 7.6454 0 c
        h
        f
        S
        """

        let body: String
        var dict: [String: PDFObject] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "FormType": .int(1),
            "BBox": .array([
                .real(-0.30035),
                .real(-0.30035),
                .real(7.94575),
                .real(6.30735),
            ]),
        ]

        if color.opacity < 0.999 {
            body = "q\n/GS0 gs\n\(glyph)\nQ\n"
            dict["Resources"] = .dict([
                "ExtGState": .dict([
                    "GS0": .dict([
                        "Type": .name("ExtGState"),
                        "ca": .real(color.opacity),
                        "CA": .real(color.opacity),
                    ]),
                ]),
            ])
        } else {
            body = glyph + "\n"
        }

        let streamData = Data(body.utf8)
        dict["Length"] = .int(Int64(streamData.count))
        return .stream(dict: dict, data: streamData)
    }

    // MARK: - Helpers

    /// Convenience dispatcher for markup subtypes (`Highlight`, `Underline`, `StrikeOut`).
    static func markupStream(
        subtype: String,
        quads: [PDFMarkupQuad],
        rect: CGRect,
        color: Color
    ) -> PDFObject? {
        switch subtype {
        case "Highlight":
            return highlightStream(quads: quads, rect: rect, color: color)
        case "Underline":
            return underlineStream(quads: quads, rect: rect, color: color)
        case "StrikeOut":
            return strikeOutStream(quads: quads, rect: rect, color: color)
        default:
            return nil
        }
    }

    /// Computes the axis-aligned bounding rectangle of a list of quads in PDF user space.
    static func boundingRect(for quads: [PDFMarkupQuad]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for quad in quads {
            for pt in quad.points {
                minX = min(minX, pt.x)
                minY = min(minY, pt.y)
                maxX = max(maxX, pt.x)
                maxY = max(maxY, pt.y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rectArray(_ rect: CGRect) -> PDFObject {
        .array([
            .real(Double(rect.minX)),
            .real(Double(rect.minY)),
            .real(Double(rect.maxX)),
            .real(Double(rect.maxY)),
        ])
    }

    private static func fmt(_ value: Double) -> String {
        PDFSerializer.formatNumber(value)
    }

    private static func fmt(_ value: CGFloat) -> String {
        PDFSerializer.formatNumber(Double(value))
    }
}
