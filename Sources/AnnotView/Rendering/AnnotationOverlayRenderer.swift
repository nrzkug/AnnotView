import AppKit

enum PageOverlayGeometry {
    static func affineTransform(
        pageBounds: CGRect,
        localOrigin: CGPoint,
        localXBasis: CGPoint,
        localYBasis: CGPoint
    ) -> CGAffineTransform {
        let a = localXBasis.x - localOrigin.x
        let b = localXBasis.y - localOrigin.y
        let c = localYBasis.x - localOrigin.x
        let d = localYBasis.y - localOrigin.y
        return CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: localOrigin.x - pageBounds.minX * a - pageBounds.minY * c,
            ty: localOrigin.y - pageBounds.minX * b - pageBounds.minY * d
        )
    }
}

enum AnnotationOverlayRenderer {
    private static let noteIconSize: CGFloat = 12

    static func draw(
        _ annotations: [Annotation],
        context: CGContext
    ) {
        for annotation in annotations {
            context.saveGState()
            let color = CGColor(
                red: annotation.color.red,
                green: annotation.color.green,
                blue: annotation.color.blue,
                alpha: annotation.color.alpha
            )

            switch annotation.kind {
            case .highlight:
                // Acrobat and MuPDF composite highlight ink with multiply so
                // glyphs stay legible and the colour matches the appearance stream.
                context.setBlendMode(.multiply)
                context.setFillColor(color)
                for quad in quadrilaterals(from: annotation) {
                    context.addPath(path(for: quad))
                    context.fillPath(using: .evenOdd)
                }
            case .underline, .strikeout:
                context.setStrokeColor(color)
                context.setLineWidth(1)
                context.setLineCap(.butt)
                for quad in quadrilaterals(from: annotation) {
                    drawTextMarkupLine(
                        for: quad,
                        kind: annotation.kind,
                        context: context
                    )
                }
            case .note:
                drawNote(annotation, color: color, context: context)
            case .ink:
                break
            case .caret:
                drawCaret(annotation, color: color, context: context)
            }
            context.restoreGState()
        }
    }

    static func drawHover(for annotation: Annotation, context: CGContext) {
        context.saveGState()
        let accent = NSColor.controlAccentColor
        context.setStrokeColor(accent.withAlphaComponent(0.8).cgColor)
        context.setFillColor(accent.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(0.8)
        context.setLineJoin(.round)

        if annotation.kind == .note {
            let outline = noteIconRect(for: annotation).insetBy(dx: -1.5, dy: -1.5)
            context.addPath(
                CGPath(roundedRect: outline, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            )
            context.strokePath()
        } else if annotation.kind == .caret {
            let outline = caretMarkerRect(for: annotation).insetBy(dx: -2, dy: -2)
            context.addPath(
                CGPath(roundedRect: outline, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            )
            context.strokePath()
        } else {
            for quad in quadrilaterals(from: annotation) {
                let quadPath = path(for: quad)
                context.addPath(quadPath)
                context.drawPath(using: .fillStroke)
            }
        }
        context.restoreGState()
    }

    /// Persistent emphasis for the annotation selected from the sidebar or by
    /// clicking it in the document. Stronger than hover so it reads as a
    /// selection rather than a transient highlight.
    static func drawSelection(for annotation: Annotation, context: CGContext) {
        context.saveGState()
        let accent = NSColor.controlAccentColor
        context.setStrokeColor(accent.withAlphaComponent(1).cgColor)
        context.setFillColor(accent.withAlphaComponent(0.16).cgColor)
        context.setLineWidth(1.2)
        context.setLineJoin(.round)

        if annotation.kind == .note {
            let outline = noteIconRect(for: annotation).insetBy(dx: -2, dy: -2)
            context.addPath(
                CGPath(roundedRect: outline, cornerWidth: 3, cornerHeight: 3, transform: nil)
            )
            context.drawPath(using: .fillStroke)
        } else if annotation.kind == .caret {
            let outline = caretMarkerRect(for: annotation).insetBy(dx: -2.5, dy: -2.5)
            context.addPath(
                CGPath(roundedRect: outline, cornerWidth: 3, cornerHeight: 3, transform: nil)
            )
            context.drawPath(using: .fillStroke)
        } else {
            for quad in quadrilaterals(from: annotation) {
                let quadPath = path(for: quad)
                context.addPath(quadPath)
                context.drawPath(using: .fillStroke)
            }
        }
        context.restoreGState()
    }

    /// Acrobat QuadPoints are grouped as four points per marked text segment.
    static func quadrilaterals(from annotation: Annotation) -> [[CGPoint]] {
        let points = annotation.quadPoints
        guard points.count >= 4 else {
            // Text markup lines must never guess their position from Rect.
            guard annotation.kind == .highlight else { return [] }
            let rect = annotation.bounds
            return [[
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY)
            ]]
        }
        return stride(from: 0, through: points.count - 4, by: 4).map {
            Array(points[$0..<($0 + 4)])
        }
    }

    /// Acrobat uses Z-order: top-left, top-right, bottom-left, bottom-right.
    /// A Core Graphics polygon must instead walk around the perimeter.
    static func path(for quad: [CGPoint]) -> CGPath {
        let ordered = [quad[0], quad[1], quad[3], quad[2]]
        let path = CGMutablePath()
        path.move(to: ordered[0])
        for point in ordered.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    static func textMarkupLine(
        for quad: [CGPoint],
        kind: Annotation.Kind
    ) -> (start: CGPoint, end: CGPoint)? {
        guard quad.count == 4 else { return nil }
        if kind == .underline {
            return (quad[2], quad[3])
        }
        guard kind == .strikeout else { return nil }

        // Acrobat places its strike at 3/7 of the quad height above the
        // lower edge (its generated appearance streams use this consistently).
        return (
            interpolate(from: quad[2], to: quad[0], fraction: 3.0 / 7.0),
            interpolate(from: quad[3], to: quad[1], fraction: 3.0 / 7.0)
        )
    }

    static func noteIconRect(for annotation: Annotation) -> CGRect {
        let center = CGPoint(x: annotation.bounds.midX, y: annotation.bounds.midY)
        return CGRect(
            x: center.x - noteIconSize / 2,
            y: center.y - noteIconSize / 2,
            width: noteIconSize,
            height: noteIconSize
        )
    }

    static func anchorBounds(for annotation: Annotation) -> CGRect {
        if annotation.kind == .note { return noteIconRect(for: annotation) }
        let quadBounds = quadrilaterals(from: annotation).map { path(for: $0).boundingBox }
        return quadBounds.dropFirst().reduce(quadBounds.first ?? annotation.bounds) { $0.union($1) }
    }

    static func contains(_ point: CGPoint, in annotation: Annotation) -> Bool {
        if annotation.kind == .note {
            return noteIconRect(for: annotation).insetBy(dx: -3, dy: -3).contains(point)
        }
        if annotation.kind == .caret {
            return caretMarkerRect(for: annotation).insetBy(dx: -3, dy: -3).contains(point)
        }
        return quadrilaterals(from: annotation).contains { quad in
            path(for: quad).boundingBox.insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    private static func drawTextMarkupLine(
        for quad: [CGPoint],
        kind: Annotation.Kind,
        context: CGContext
    ) {
        guard let line = textMarkupLine(for: quad, kind: kind) else { return }
        context.move(to: line.start)
        context.addLine(to: line.end)
        context.strokePath()
    }

    private static func drawNote(
        _ annotation: Annotation,
        color: CGColor,
        context: CGContext
    ) {
        let iconRect = noteIconRect(for: annotation)
        let radius = iconRect.width * 0.16
        context.setFillColor(color.copy(alpha: 1) ?? color)
        context.addPath(
            CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        )
        context.fillPath()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(0.7)
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()

        let fold = iconRect.width * 0.3
        let foldPath = CGMutablePath()
        foldPath.move(to: CGPoint(x: iconRect.maxX - fold, y: iconRect.maxY))
        foldPath.addLine(to: CGPoint(x: iconRect.maxX - fold, y: iconRect.maxY - fold))
        foldPath.addLine(to: CGPoint(x: iconRect.maxX, y: iconRect.maxY - fold))
        context.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.addPath(foldPath)
        context.fillPath()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(0.8)
        for fraction in [CGFloat(0.38), CGFloat(0.62)] {
            let y = iconRect.minY + iconRect.height * fraction
            context.move(to: CGPoint(x: iconRect.minX + 2.2, y: y))
            context.addLine(to: CGPoint(x: iconRect.maxX - 2.2, y: y))
        }
        context.strokePath()
    }

    /// Acrobat's caret glyph: a leaf drawn with two cubic Beziers, 7.6454 wide
    /// by 6.007 tall, its base 0.6pt above the rect's bottom edge, centered
    /// horizontally. The same path Acrobat writes into the /AP appearance.
    static func caretMarkerRect(for annotation: Annotation) -> CGRect {
        let width: CGFloat = 7.6454
        let height: CGFloat = 6.007
        return CGRect(
            x: annotation.bounds.midX - width / 2,
            y: annotation.bounds.minY + 0.600708,
            width: width,
            height: height
        )
    }

    private static func drawCaret(
        _ annotation: Annotation,
        color: CGColor,
        context: CGContext
    ) {
        let rect = caretMarkerRect(for: annotation)
        let ink = color.copy(alpha: 1) ?? color
        let midX = rect.midX
        let base = rect.minY
        let apex = rect.maxY
        let shoulderY = base + 3.0035

        let leaf = CGMutablePath()
        leaf.move(to: CGPoint(x: rect.minX, y: base))
        leaf.addCurve(
            to: CGPoint(x: midX, y: apex),
            control1: CGPoint(x: midX, y: base),
            control2: CGPoint(x: midX, y: shoulderY)
        )
        leaf.addCurve(
            to: CGPoint(x: rect.maxX, y: base),
            control1: CGPoint(x: midX, y: shoulderY),
            control2: CGPoint(x: midX, y: base)
        )
        leaf.closeSubpath()

        context.setFillColor(ink)
        context.addPath(leaf)
        context.fillPath()
        context.setStrokeColor(ink)
        context.setLineWidth(0.6007)
        context.addPath(leaf)
        context.strokePath()
    }

    private static func interpolate(
        from start: CGPoint,
        to end: CGPoint,
        fraction: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }
}
