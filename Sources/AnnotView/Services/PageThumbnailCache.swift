import AppKit
import PDFKit

/// Background rasterizer using CoreGraphics (`CGPDFDocument` + `CGContext`) so
/// sidebar thumbnail generation and annotation compositing run completely off the main thread.
actor PDFPageRasterizer {
    struct RenderDescriptor: Sendable {
        let pageIndex: Int
        let cropBox: CGRect
        let rotation: Int
        let cropBoxTransform: CGAffineTransform
        let scale: CGFloat
        let backingScale: CGFloat
    }

    struct RenderedBitmap: @unchecked Sendable {
        let cgImage: CGImage
        let logicalSize: CGSize
        let memoryCost: Int
    }

    private var cachedDocument: (url: URL, document: CGPDFDocument)?

    func reset() {
        cachedDocument = nil
    }

    func render(
        descriptor: RenderDescriptor,
        annotations: [Annotation],
        documentURL: URL
    ) -> RenderedBitmap? {
        guard !Task.isCancelled else { return nil }
        guard let cgDoc = pdfDocument(for: documentURL),
              let cgPage = cgDoc.page(at: descriptor.pageIndex + 1) else {
            return nil
        }

        let isRotated = descriptor.rotation == 90 || descriptor.rotation == 270
        let boxWidth = isRotated ? descriptor.cropBox.height : descriptor.cropBox.width
        let boxHeight = isRotated ? descriptor.cropBox.width : descriptor.cropBox.height
        guard boxWidth > 0, boxHeight > 0 else { return nil }

        let logicalSize = CGSize(width: boxWidth * descriptor.scale, height: boxHeight * descriptor.scale)
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }

        let pixelWidth = max(1, Int(ceil(logicalSize.width * descriptor.backingScale)))
        let pixelHeight = max(1, Int(ceil(logicalSize.height * descriptor.backingScale)))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(
            x: CGFloat(pixelWidth) / boxWidth,
            y: CGFloat(pixelHeight) / boxHeight
        )
        context.concatenate(descriptor.cropBoxTransform)

        context.saveGState()
        context.clip(to: descriptor.cropBox)
        context.drawPDFPage(cgPage)
        context.restoreGState()

        if !annotations.isEmpty {
            AnnotationOverlayRenderer.draw(annotations, context: context)
        }
        context.restoreGState()

        guard !Task.isCancelled, let cgImage = context.makeImage() else { return nil }
        return RenderedBitmap(
            cgImage: cgImage,
            logicalSize: logicalSize,
            memoryCost: pixelWidth * pixelHeight * 4
        )
    }

    private func pdfDocument(for url: URL) -> CGPDFDocument? {
        let canonical = url.resolvingSymlinksInPath()
        if let cached = cachedDocument, cached.url == canonical {
            return cached.document
        }
        guard let doc = CGPDFDocument(canonical as CFURL) else {
            cachedDocument = nil
            return nil
        }
        if doc.isEncrypted && !doc.isUnlocked {
            _ = doc.unlockWithPassword("")
        }
        guard doc.isUnlocked else {
            cachedDocument = nil
            return nil
        }
        cachedDocument = (canonical, doc)
        return doc
    }
}

/// Manages cached page thumbnails, in-flight task deduplication, and per-page invalidation.
@MainActor
final class PageThumbnailCache {
    private struct RenderedPageKey {
        let pageIndex: Int
        let scale: Int

        var rawValue: String {
            "\(pageIndex):\(scale)"
        }

        var value: NSString {
            rawValue as NSString
        }

        init(pageIndex: Int, scale: CGFloat) {
            self.pageIndex = pageIndex
            self.scale = Int((scale * 1_000).rounded())
        }
    }

    private let cache = NSCache<NSString, NSImage>()
    private var cachedKeysByPage: [Int: Set<NSString>] = [:]
    private var inFlightTasks: [String: (pageIndex: Int, task: Task<NSImage?, Never>)] = [:]
    private let rasterizer = PDFPageRasterizer()
    private var generation: UInt64 = 0
    private var pageGenerations: [Int: UInt64] = [:]

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func cachedThumbnail(for pageIndex: Int, scale: CGFloat) -> NSImage? {
        let key = RenderedPageKey(pageIndex: pageIndex, scale: scale)
        return cache.object(forKey: key.value)
    }

    func renderPageAsync(
        pageIndex: Int,
        scale: CGFloat,
        document: PDFDocument?,
        documentURL: URL?,
        annotations: [Annotation]
    ) async -> NSImage? {
        let cacheKey = RenderedPageKey(pageIndex: pageIndex, scale: scale)
        if let cached = cache.object(forKey: cacheKey.value) {
            return cached
        }
        guard let page = document?.page(at: pageIndex) else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        let isRotated = page.rotation == 90 || page.rotation == 270
        let boxWidth = isRotated ? pageBounds.height : pageBounds.width
        let boxHeight = isRotated ? pageBounds.width : pageBounds.height
        let logicalSize = CGSize(width: boxWidth * scale, height: boxHeight * scale)
        guard boxWidth > 0, boxHeight > 0, logicalSize.width > 0, logicalSize.height > 0 else {
            return nil
        }

        let currentGeneration = generation
        let currentPageGeneration = pageGenerations[pageIndex] ?? 0
        let taskKey = "\(cacheKey.rawValue):\(currentGeneration):\(currentPageGeneration)"

        if let existing = inFlightTasks[taskKey] {
            return await existing.task.value
        }

        let descriptor = PDFPageRasterizer.RenderDescriptor(
            pageIndex: pageIndex,
            cropBox: pageBounds,
            rotation: page.rotation,
            cropBoxTransform: page.transform(for: .cropBox),
            scale: scale,
            backingScale: max(1.0, NSScreen.main?.backingScaleFactor ?? 2.0)
        )

        let task = Task<NSImage?, Never> { [weak self] in
            defer {
                self?.inFlightTasks.removeValue(forKey: taskKey)
            }
            if let documentURL,
               let bitmap = await self?.rasterizer.render(
                   descriptor: descriptor,
                   annotations: annotations,
                   documentURL: documentURL
               ) {
                guard !Task.isCancelled,
                      let self,
                      self.generation == currentGeneration,
                      (self.pageGenerations[pageIndex] ?? 0) == currentPageGeneration else {
                    return nil
                }
                let image = NSImage(cgImage: bitmap.cgImage, size: bitmap.logicalSize)
                self.storeImage(image, key: cacheKey, cost: bitmap.memoryCost)
                return image
            }

            await Task.yield()
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration,
                  (self.pageGenerations[pageIndex] ?? 0) == currentPageGeneration else {
                return nil
            }
            let baseImage = page.thumbnail(of: logicalSize, for: .cropBox)
            let image = annotations.isEmpty
                ? baseImage
                : Self.compositeAnnotations(annotations, on: baseImage, page: page)
            let estimatedCost = max(1, Int(image.size.width * image.size.height * 4))
            self.storeImage(image, key: cacheKey, cost: estimatedCost)
            return image
        }

        inFlightTasks[taskKey] = (pageIndex: pageIndex, task: task)
        return await task.value
    }

    func renderPageSync(
        pageIndex: Int,
        scale: CGFloat,
        page: PDFPage,
        annotations: [Annotation]
    ) -> NSImage {
        let cacheKey = RenderedPageKey(pageIndex: pageIndex, scale: scale)
        if let cached = cache.object(forKey: cacheKey.value) { return cached }

        let pageBounds = page.bounds(for: .cropBox)
        let isRotated = page.rotation == 90 || page.rotation == 270
        let boxWidth = isRotated ? pageBounds.height : pageBounds.width
        let boxHeight = isRotated ? pageBounds.width : pageBounds.height
        let size = CGSize(width: boxWidth * scale, height: boxHeight * scale)
        let baseImage = page.thumbnail(of: size, for: .cropBox)
        let image = annotations.isEmpty
            ? baseImage
            : Self.compositeAnnotations(annotations, on: baseImage, page: page)

        let estimatedCost = max(1, Int(image.size.width * image.size.height * 4))
        storeImage(image, key: cacheKey, cost: estimatedCost)
        return image
    }

    func invalidateAll() {
        generation &+= 1
        pageGenerations.removeAll()
        for entry in inFlightTasks.values {
            entry.task.cancel()
        }
        inFlightTasks.removeAll()
        cache.removeAllObjects()
        cachedKeysByPage.removeAll()
    }

    func invalidate(pages: Set<Int>) {
        guard !pages.isEmpty else { return }
        for pageIndex in pages {
            pageGenerations[pageIndex, default: 0] &+= 1
            if let keys = cachedKeysByPage.removeValue(forKey: pageIndex) {
                for key in keys {
                    cache.removeObject(forKey: key)
                }
            }
        }
        for (taskKey, entry) in inFlightTasks where pages.contains(entry.pageIndex) {
            entry.task.cancel()
            inFlightTasks.removeValue(forKey: taskKey)
        }
    }

    func reset() {
        invalidateAll()
        Task {
            await rasterizer.reset()
        }
    }

    private func storeImage(_ image: NSImage, key: RenderedPageKey, cost: Int) {
        let nsKey = key.value
        cache.setObject(image, forKey: nsKey, cost: cost)
        cachedKeysByPage[key.pageIndex, default: []].insert(nsKey)
    }

    private static func compositeAnnotations(
        _ pageAnnotations: [Annotation],
        on baseImage: NSImage,
        page: PDFPage
    ) -> NSImage {
        let size = baseImage.size
        guard size.width > 0, size.height > 0 else { return baseImage }
        let backingScale = max(1.0, NSScreen.main?.backingScaleFactor ?? 2.0)
        let pixelWidth = max(1, Int(ceil(size.width * backingScale)))
        let pixelHeight = max(1, Int(ceil(size.height * backingScale)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return baseImage
        }

        var rect = CGRect(origin: .zero, size: size)
        if let baseCG = baseImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            context.draw(baseCG, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        } else {
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            context.saveGState()
            context.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(pixelHeight) / size.height)
            baseImage.draw(in: CGRect(origin: .zero, size: size))
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }

        let pageBounds = page.bounds(for: .cropBox)
        let isRotated = page.rotation == 90 || page.rotation == 270
        let boxWidth = isRotated ? pageBounds.height : pageBounds.width
        let boxHeight = isRotated ? pageBounds.width : pageBounds.height
        if boxWidth > 0, boxHeight > 0 {
            context.saveGState()
            context.scaleBy(
                x: CGFloat(pixelWidth) / boxWidth,
                y: CGFloat(pixelHeight) / boxHeight
            )
            context.concatenate(page.transform(for: .cropBox))
            AnnotationOverlayRenderer.draw(pageAnnotations, context: context)
            context.restoreGState()
        }

        guard let cgImage = context.makeImage() else { return baseImage }
        return NSImage(cgImage: cgImage, size: size)
    }
}
