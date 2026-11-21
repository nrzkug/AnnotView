import AppKit
import SwiftUI

/// Like Kaka's main split, all three columns extend behind native window
/// chrome. Annotation tools stay beside the window's inspector toggle.
struct ReaderContentSplitView<Sidebar: View, Main: View, Inspector: View, Tools: View>: NSViewControllerRepresentable {
    @Binding var isSidebarVisible: Bool
    @Binding var isInspectorVisible: Bool
    @Binding var chromeHeight: CGFloat
    let annotationTool: AnnotationTool
    let colorRevision: Int
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let main: () -> Main
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let tools: () -> Tools

    func makeNSViewController(context: Context) -> ReaderSplitViewController<Sidebar, Main, Inspector, Tools> {
        let sidebarVisibility = $isSidebarVisible
        let inspectorVisibility = $isInspectorVisible
        let height = $chromeHeight
        return ReaderSplitViewController(
            sidebar: sidebar(), main: main(), inspector: inspector(), tools: tools(),
            sidebarVisible: isSidebarVisible, inspectorVisible: isInspectorVisible,
            annotationTool: annotationTool, colorRevision: colorRevision,
            onSidebarChange: { sidebarVisibility.wrappedValue = $0 },
            onInspectorChange: { inspectorVisibility.wrappedValue = $0 },
            onChromeHeightChange: { height.wrappedValue = $0 }
        )
    }

    func updateNSViewController(
        _ controller: ReaderSplitViewController<Sidebar, Main, Inspector, Tools>, context: Context
    ) {
        controller.update(
            sidebar: sidebar(), main: main(), inspector: inspector(), tools: tools(),
            sidebarVisible: isSidebarVisible, inspectorVisible: isInspectorVisible,
            annotationTool: annotationTool, colorRevision: colorRevision
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: ReaderSplitViewController<Sidebar, Main, Inspector, Tools>,
        context: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 1_200, height: proposal.height ?? 760)
    }
}

private enum SplitViewDefaultsKey {
    static let sidebarWidth = "readerSidebarWidth"
    static let inspectorWidth = "readerInspectorWidth"
}

private final class ReaderChromeHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ReaderPaneController<Content: View>: NSViewController {
    let host: NSHostingView<Content>

    init(rootView: Content) {
        host = ReaderChromeHostingView(rootView: rootView)
        host.safeAreaRegions = []
        host.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = host }
}

/// Keep actions off NSSplitViewController's toolbar validation path, as Kaka
/// does, so a dismissed sheet cannot leave a sidebar toggle disabled.
private final class ReaderToolbarAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

final class ReaderSplitViewController<Sidebar: View, Main: View, Inspector: View, Tools: View>:
    NSSplitViewController, NSToolbarDelegate {
    private let sidebarHost: ReaderPaneController<Sidebar>
    private let mainHost: ReaderPaneController<Main>
    private let inspectorHost: ReaderPaneController<Inspector>
    private var toolsHost: NSHostingView<Tools>?
    private var toolsRoot: Tools
    private let sidebarItem: NSSplitViewItem
    private let inspectorItem: NSSplitViewItem
    private let onSidebarChange: (Bool) -> Void
    private let onInspectorChange: (Bool) -> Void
    private let onChromeHeightChange: (CGFloat) -> Void
    private var observations: [NSKeyValueObservation] = []
    private var actions: [ReaderToolbarAction] = []
    private var annotationTool: AnnotationTool
    private var colorRevision: Int
    private var colorToolbarItem: NSMenuToolbarItem?
    private let colorMenuTarget = ToolbarColorMenuTarget()
    private var isSyncing = false
    private var didInstallChrome = false
    private var didSetInitialWidths = false
    private var didAutoCollapseForNarrowWidth = false
    private var reportedChromeHeight: CGFloat?

    private var toolColorID: NSToolbarItem.Identifier { .init("annotview.annotationColor") }
    private var toolsID: NSToolbarItem.Identifier { .init("annotview.annotationTools") }
    private var sidebarID: NSToolbarItem.Identifier { .init("annotview.sidebar") }
    private var inspectorID: NSToolbarItem.Identifier { .init("annotview.inspector") }

    init(
        sidebar: Sidebar, main: Main, inspector: Inspector, tools: Tools,
        sidebarVisible: Bool, inspectorVisible: Bool,
        annotationTool: AnnotationTool, colorRevision: Int,
        onSidebarChange: @escaping (Bool) -> Void,
        onInspectorChange: @escaping (Bool) -> Void,
        onChromeHeightChange: @escaping (CGFloat) -> Void
    ) {
        sidebarHost = ReaderPaneController(rootView: sidebar)
        mainHost = ReaderPaneController(rootView: main)
        inspectorHost = ReaderPaneController(rootView: inspector)
        toolsRoot = tools
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        self.annotationTool = annotationTool
        self.colorRevision = colorRevision
        self.onSidebarChange = onSidebarChange
        self.onInspectorChange = onInspectorChange
        self.onChromeHeightChange = onChromeHeightChange
        super.init(nibName: nil, bundle: nil)

        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.isCollapsed = !sidebarVisible

        let mainItem = NSSplitViewItem(viewController: mainHost)
        mainItem.minimumThickness = 360
        mainItem.allowsFullHeightLayout = true

        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 720
        inspectorItem.holdingPriority = .init(260)
        inspectorItem.isCollapsed = !inspectorVisible

        for item in [sidebarItem, mainItem, inspectorItem] {
            item.allowsFullHeightLayout = true
            item.automaticallyAdjustsSafeAreaInsets = false
            addSplitViewItem(item)
        }
        splitView.autoresizingMask = [.width, .height]

        observations = [sidebarItem, inspectorItem].map { item in
            item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isSyncing else { return }
                    self.onSidebarChange(!self.sidebarItem.isCollapsed)
                    self.onInspectorChange(!self.inspectorItem.isCollapsed)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        sidebar: Sidebar, main: Main, inspector: Inspector, tools: Tools,
        sidebarVisible: Bool, inspectorVisible: Bool,
        annotationTool: AnnotationTool, colorRevision: Int
    ) {
        if self.annotationTool != annotationTool || self.colorRevision != colorRevision {
            self.annotationTool = annotationTool
            self.colorRevision = colorRevision
            DispatchQueue.main.async { [weak self] in
                self?.refreshColorToolbarItem()
            }
        }
        isSyncing = true
        setCollapsed(!sidebarVisible, for: sidebarItem)
        setCollapsed(!inspectorVisible, for: inspectorItem)
        isSyncing = false
    }

    private func setCollapsed(_ collapsed: Bool, for item: NSSplitViewItem) {
        // SwiftUI also updates these roots for selection and document changes;
        // only start an animation when visibility actually changes.
        guard item.isCollapsed != collapsed else { return }
        guard view.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            item.isCollapsed = collapsed
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            item.animator().isCollapsed = collapsed
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        if !didInstallChrome {
            didInstallChrome = true
            let toolbar = NSToolbar(identifier: "annotview.reader")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbarStyle = .unified
            window.toolbar = toolbar
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
        if !didSetInitialWidths {
            didSetInitialWidths = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.splitView.bounds.width > 0 else { return }
                let totalWidth = self.splitView.bounds.width
                let defaults = UserDefaults.standard
                if !self.sidebarItem.isCollapsed {
                    let sidebarWidth = defaults.object(forKey: SplitViewDefaultsKey.sidebarWidth) as? CGFloat ?? 260
                    self.splitView.setPosition(min(sidebarWidth, totalWidth * 0.5), ofDividerAt: 0)
                }
                if !self.inspectorItem.isCollapsed {
                    let inspectorWidth = defaults.object(forKey: SplitViewDefaultsKey.inspectorWidth) as? CGFloat ?? 360
                    self.splitView.setPosition(max(totalWidth - inspectorWidth, totalWidth * 0.5), ofDividerAt: 1)
                }
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // SwiftUI may re-pin the representable to contentLayoutRect after a
        // toolbar change. Match Kaka: expand its host back to the full window.
        if let host = view.superview, let contentView = view.window?.contentView,
           host !== contentView, host.frame != contentView.bounds {
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            host.frame = contentView.bounds
        }
        guard let height = view.window?.contentView?.safeAreaInsets.top else { return }
        if reportedChromeHeight != height {
            reportedChromeHeight = height
            DispatchQueue.main.async { [weak self] in self?.onChromeHeightChange(height) }
        }
        let width = splitView.bounds.width
        if width > 0 && width < 860,
           !sidebarItem.isCollapsed,
           !inspectorItem.isCollapsed,
           !didAutoCollapseForNarrowWidth {
            didAutoCollapseForNarrowWidth = true
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.splitView.bounds.width < 860,
                      !self.sidebarItem.isCollapsed,
                      !self.inspectorItem.isCollapsed else { return }
                self.onSidebarChange(false)
            }
        } else if width >= 900 {
            didAutoCollapseForNarrowWidth = false
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Skip collapsed panes so their pre-collapse widths stay intact.
        guard view.window != nil, splitView.subviews.count == 3 else { return }
        let defaults = UserDefaults.standard
        if !sidebarItem.isCollapsed {
            defaults.set(Double(splitView.subviews[0].frame.width), forKey: SplitViewDefaultsKey.sidebarWidth)
        }
        if !inspectorItem.isCollapsed {
            defaults.set(Double(splitView.subviews[2].frame.width), forKey: SplitViewDefaultsKey.inspectorWidth)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarID, .sidebarTrackingSeparator, .flexibleSpace, toolColorID, toolsID, inspectorID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator || identifier == .inspectorTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier, splitView: splitView,
                dividerIndex: identifier == .sidebarTrackingSeparator ? 0 : 1
            )
        }
        if identifier == toolColorID {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.isBordered = true
            item.showsIndicator = false
            item.label = "Annotation Color"
            colorToolbarItem = item
            refreshColorToolbarItem()
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = identifier != toolsID
        if identifier == toolsID {
            let host = NSHostingView(rootView: toolsRoot)
            toolsHost = host
            item.view = host
            item.label = "Annotation Tool"
            return item
        }
        let isSidebar = identifier == sidebarID
        guard isSidebar || identifier == inspectorID else { return nil }
        let action = ReaderToolbarAction { [weak self] in
            guard let self else { return }
            if isSidebar {
                self.onSidebarChange(self.sidebarItem.isCollapsed)
            } else {
                self.onInspectorChange(self.inspectorItem.isCollapsed)
            }
        }
        actions.append(action)
        let label = isSidebar ? "Pages and Outline" : "Annotations"
        let icon = Bundle.module.image(forResource: isSidebar ? "panel-left" : "panel-right")
        icon?.size = NSSize(width: 19, height: 19)
        icon?.isTemplate = true
        item.image = icon
        item.label = label
        item.toolTip = isSidebar ? "Show or hide pages and outline" : "Show or hide annotations inspector"
        item.target = action
        item.action = #selector(ReaderToolbarAction.fire)
        item.isBordered = true
        return item
    }

    private func refreshColorToolbarItem() {
        guard let item = colorToolbarItem else { return }
        guard let kind = annotationTool.annotationKind else {
            item.isHidden = true
            return
        }
        item.isHidden = false
        let current = AnnotationColorMemory.shared.color(for: kind)
        item.image = Self.swatchImage(for: current, diameter: 14)
        item.toolTip = "Choose \(annotationTool.label.lowercased()) color"

        let menu = NSMenu()
        menu.autoenablesItems = false
        colorMenuTarget.onSelect = { presetColor in
            let alpha: CGFloat = kind == .highlight ? 0.4 : 1.0
            let next = Annotation.Color(
                red: presetColor.red,
                green: presetColor.green,
                blue: presetColor.blue,
                alpha: alpha
            )
            AnnotationColorMemory.shared.set(next, for: kind)
        }
        for preset in ToolbarColorMenuTarget.presets {
            let menuItem = NSMenuItem(
                title: preset.name,
                action: #selector(ToolbarColorMenuTarget.select(_:)),
                keyEquivalent: ""
            )
            menuItem.target = colorMenuTarget
            menuItem.representedObject = preset.color
            menuItem.image = Self.swatchImage(for: preset.color, diameter: 12)
            let matches = abs(current.red - preset.color.red) < 0.02
                && abs(current.green - preset.color.green) < 0.02
                && abs(current.blue - preset.color.blue) < 0.02
            menuItem.state = matches ? .on : .off
            menu.addItem(menuItem)
        }
        item.menu = menu
    }

    private static func swatchImage(for color: Annotation.Color, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(ovalIn: rect)
        NSColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

}

private final class ToolbarColorMenuTarget: NSObject {
    static let presets: [(name: String, color: Annotation.Color)] = [
        ("Yellow", Annotation.Color(red: 1, green: 0.819611, blue: 0, alpha: 1)),
        ("Green", Annotation.Color(red: 0.243, green: 0.725, blue: 0.353, alpha: 1)),
        ("Red", Annotation.Color(red: 0.972549, green: 0.392151, blue: 0.392151, alpha: 1)),
        ("Purple", Annotation.Color(red: 0.588242, green: 0.262741, blue: 0.988235, alpha: 1)),
        ("Blue", Annotation.Color(red: 0.0, green: 0.478, blue: 1.0, alpha: 1)),
    ]

    var onSelect: ((Annotation.Color) -> Void)?

    @objc func select(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? Annotation.Color else { return }
        onSelect?(color)
    }
}
