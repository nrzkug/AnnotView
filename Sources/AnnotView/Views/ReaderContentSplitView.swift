import AppKit
import SwiftUI

/// A Finder-style content split. The source sidebar remains owned by the outer
/// NavigationSplitView, while these two ordinary content panes start below the
/// shared window toolbar.
struct ReaderContentSplitView<Main: View, Detail: View>: NSViewRepresentable {
    @Binding var isDetailVisible: Bool
    let mainMinimumWidth: CGFloat
    let detailMinimumWidth: CGFloat
    let detailIdealWidth: CGFloat
    let detailMaximumWidth: CGFloat
    @ViewBuilder let main: () -> Main
    @ViewBuilder let detail: () -> Detail

    func makeNSView(context: Context) -> ReaderContentSplitNSView<Main, Detail> {
        let visibility = $isDetailVisible
        return ReaderContentSplitNSView(
            main: main(),
            detail: detail(),
            isDetailVisible: isDetailVisible,
            mainMinimumWidth: mainMinimumWidth,
            detailMinimumWidth: detailMinimumWidth,
            detailIdealWidth: detailIdealWidth,
            detailMaximumWidth: detailMaximumWidth,
            onRequestCollapse: { visibility.wrappedValue = false }
        )
    }

    func updateNSView(_ view: ReaderContentSplitNSView<Main, Detail>, context: Context) {
        view.update(main: main(), detail: detail(), isDetailVisible: isDetailVisible)
    }
}

final class ReaderContentSplitNSView<Main: View, Detail: View>: NSView {
    private let mainHost: NSHostingView<Main>
    private let detailHost: NSHostingView<Detail>
    private let resizeHandle = ReaderSplitResizeHandle(frame: .zero)
    private let mainMinimumWidth: CGFloat
    private let detailMinimumWidth: CGFloat
    private let detailMaximumWidth: CGFloat
    private let onRequestCollapse: () -> Void
    private var retainedDetailWidth: CGFloat
    private var dragStartDetailWidth: CGFloat?
    private var isPreviewingCollapse = false
    private var detailIsVisible: Bool

    init(
        main: Main,
        detail: Detail,
        isDetailVisible: Bool,
        mainMinimumWidth: CGFloat,
        detailMinimumWidth: CGFloat,
        detailIdealWidth: CGFloat,
        detailMaximumWidth: CGFloat,
        onRequestCollapse: @escaping () -> Void
    ) {
        mainHost = NSHostingView(rootView: main)
        detailHost = NSHostingView(rootView: detail)
        self.mainMinimumWidth = mainMinimumWidth
        self.detailMinimumWidth = detailMinimumWidth
        self.detailMaximumWidth = detailMaximumWidth
        self.onRequestCollapse = onRequestCollapse
        retainedDetailWidth = detailIdealWidth
        detailIsVisible = isDetailVisible
        super.init(frame: .zero)

        addSubview(mainHost)
        addSubview(resizeHandle)
        addSubview(detailHost)
        detailHost.isHidden = !isDetailVisible
        resizeHandle.isHidden = !isDetailVisible
        resizeHandle.onDragBegan = { [weak self] in
            guard let self else { return }
            dragStartDetailWidth = effectiveDetailWidth
            isPreviewingCollapse = false
        }
        resizeHandle.onDrag = { [weak self] translation in
            guard let self, let dragStartDetailWidth else { return }
            let proposedWidth = dragStartDetailWidth - translation
            isPreviewingCollapse = proposedWidth < detailMinimumWidth / 2
            detailHost.isHidden = isPreviewingCollapse
            if !isPreviewingCollapse { retainedDetailWidth = clampedDetailWidth(proposedWidth) }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        resizeHandle.onDragEnded = { [weak self] in
            guard let self else { return }
            dragStartDetailWidth = nil
            if isPreviewingCollapse {
                isPreviewingCollapse = false
                onRequestCollapse()
            } else {
                detailHost.isHidden = false
                needsLayout = true
            }
        }
        resizeHandle.onDoubleClick = { [weak self] in self?.onRequestCollapse() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard detailIsVisible else {
            mainHost.frame = bounds
            return
        }
        let dividerWidth = resizeHandle.intrinsicContentSize.width
        if isPreviewingCollapse {
            mainHost.frame = bounds
            resizeHandle.frame = NSRect(
                x: max(0, bounds.width - dividerWidth), y: 0,
                width: dividerWidth, height: bounds.height
            )
            return
        }
        let detailWidth = effectiveDetailWidth
        let mainWidth = max(0, bounds.width - dividerWidth - detailWidth)
        mainHost.frame = NSRect(x: 0, y: 0, width: mainWidth, height: bounds.height)
        resizeHandle.frame = NSRect(x: mainWidth, y: 0, width: dividerWidth, height: bounds.height)
        detailHost.frame = NSRect(
            x: mainWidth + dividerWidth, y: 0,
            width: detailWidth, height: bounds.height
        )
    }

    func update(main: Main, detail: Detail, isDetailVisible: Bool) {
        mainHost.rootView = main
        detailHost.rootView = detail
        guard isDetailVisible != detailIsVisible else { return }
        if isDetailVisible {
            detailIsVisible = true
            detailHost.isHidden = false
            resizeHandle.isHidden = false
        } else {
            retainedDetailWidth = detailHost.frame.width
            detailIsVisible = false
            detailHost.isHidden = true
            resizeHandle.isHidden = true
        }
        isPreviewingCollapse = false
        needsLayout = true
    }

    private var effectiveDetailWidth: CGFloat { clampedDetailWidth(retainedDetailWidth) }

    private func clampedDetailWidth(_ proposedWidth: CGFloat) -> CGFloat {
        let available = max(0, bounds.width - mainMinimumWidth - resizeHandle.intrinsicContentSize.width)
        let maximum = min(detailMaximumWidth, available)
        let minimum = min(detailMinimumWidth, maximum)
        return min(max(proposedWidth, minimum), maximum)
    }
}

/// The separator stays one system-drawn point wide while its seven-point view
/// provides a stable resize cursor and drag target.
final class ReaderSplitResizeHandle: NSView {
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        separator.boxType = .separator
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 7, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: floor((bounds.width - 1) / 2), y: 0, width: 1, height: bounds.height)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        let originX = event.locationInWindow.x
        onDragBegan?()
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseDragged {
                onDrag?(next.locationInWindow.x - originX)
            } else if next.type == .leftMouseUp {
                onDragEnded?()
                return
            }
        }
        onDragEnded?()
    }
}
