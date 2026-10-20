import AppKit
import SwiftUI

/// Like Kaka's main split, all three columns extend behind native window
/// chrome. Annotation tools stay beside the window's inspector toggle.
struct ReaderContentSplitView<Sidebar: View, Main: View, Inspector: View, Tools: View>: NSViewControllerRepresentable {
    @Binding var isSidebarVisible: Bool
    @Binding var isInspectorVisible: Bool
    @Binding var chromeHeight: CGFloat
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
            sidebarVisible: isSidebarVisible, inspectorVisible: isInspectorVisible
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
    private var isSyncing = false
    private var didInstallChrome = false
    private var didSetInitialWidths = false
    private var reportedChromeHeight: CGFloat?

    private var toolsID: NSToolbarItem.Identifier { .init("annotview.annotationTools") }
    private var sidebarID: NSToolbarItem.Identifier { .init("annotview.sidebar") }
    private var inspectorID: NSToolbarItem.Identifier { .init("annotview.inspector") }

    init(
        sidebar: Sidebar, main: Main, inspector: Inspector, tools: Tools,
        sidebarVisible: Bool, inspectorVisible: Bool,
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
        self.onSidebarChange = onSidebarChange
        self.onInspectorChange = onInspectorChange
        self.onChromeHeightChange = onChromeHeightChange
        super.init(nibName: nil, bundle: nil)

        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.holdingPriority = .init(260)
        sidebarItem.isCollapsed = !sidebarVisible

        let mainItem = NSSplitViewItem(viewController: mainHost)
        mainItem.minimumThickness = 420
        mainItem.allowsFullHeightLayout = true

        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 300
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
        sidebarVisible: Bool, inspectorVisible: Bool
    ) {
        sidebarHost.host.rootView = sidebar
        mainHost.host.rootView = main
        inspectorHost.host.rootView = inspector
        toolsRoot = tools
        toolsHost?.rootView = tools
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
                self.splitView.setPosition(260, ofDividerAt: 0)
                if !self.inspectorItem.isCollapsed {
                    self.splitView.setPosition(self.splitView.bounds.width - 360, ofDividerAt: 1)
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
        guard let height = view.window?.contentView?.safeAreaInsets.top,
              reportedChromeHeight != height else { return }
        reportedChromeHeight = height
        DispatchQueue.main.async { [weak self] in self?.onChromeHeightChange(height) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarID, .sidebarTrackingSeparator, .flexibleSpace, toolsID, inspectorID]
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
        let icon = Bundle.module.image(forResource: isSidebar ? "panel-left" : "panel-right")
        icon?.size = NSSize(width: 19, height: 19)
        icon?.isTemplate = true
        item.image = icon
        item.label = isSidebar ? "Pages and Outline" : "Annotations"
        item.toolTip = isSidebar ? "Show or hide pages and outline" : "Show or hide annotations inspector"
        item.target = action
        item.action = #selector(ReaderToolbarAction.fire)
        item.isBordered = true
        return item
    }
}
