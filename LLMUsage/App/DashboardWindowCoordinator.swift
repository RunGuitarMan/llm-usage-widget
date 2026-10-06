import AppKit
import SwiftUI

extension Notification.Name {
    static let openUsageDashboard = Notification.Name("OpenUsageDashboard")
}

/// Owns presentation of the existing SwiftUI scene, never a second window or hosting view.
@MainActor final class DashboardWindowCoordinator: ObservableObject {
    static let minimumWidth: CGFloat = 860
    static let inspectorMinimumWidth: CGFloat = 1160

    @Published private(set) var isConnected = false
    private(set) weak var window: NSWindow?
    private var closeDelegate: DashboardCloseDelegate?
    private var revealed = false
    private var revealScheduled = false
    private var hideAfterFullScreen = false
    private var fullScreenObserver: NSObjectProtocol?

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        revealed = false
        // SwiftUI installs the toolbar after attaching the root. Keep that first
        // titlebar-only layout out of the visible frame; the toolbar releases it.
        window.alphaValue = 0
        let proxy = DashboardCloseDelegate(owner: self, original: window.delegate)
        closeDelegate = proxy
        window.delegate = proxy
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hideAfterFullScreen else { return }
                self.hideAfterFullScreen = false
                self.window?.orderOut(nil)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.isConnected = true }
    }

    func show(create: () -> Void) {
        hideAfterFullScreen = false
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            create()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func hide(_ window: NSWindow) {
        // Closing this menu-bar app's dashboard should preserve the scene and its
        // toolbar. App termination still uses AppKit's normal close lifecycle.
        if window.styleMask.contains(.fullScreen) {
            if !hideAfterFullScreen {
                hideAfterFullScreen = true
                window.toggleFullScreen(nil)
            }
        } else {
            window.orderOut(nil)
        }
    }

    func toolbarDidLayout(in window: NSWindow) {
        attach(window)
        guard !revealed, !revealScheduled else { return }
        revealScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.revealScheduled = false
            guard window.toolbar != nil else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            self.revealed = true
            if ManualReviewController.active != nil { WindowChromeChecks.recordFirstPresentation(window) }
            window.alphaValue = 1
            AppLaunchReceipt.record(window)
        }
    }

    func prepareForInspector() async {
        guard !Task.isCancelled, let window else { return }
        if let content = window.contentView, content.bounds.width < Self.inspectorMinimumWidth,
           !window.styleMask.contains(.fullScreen) {
            window.setContentSize(NSSize(width: Self.inspectorMinimumWidth, height: content.bounds.height))
            content.layoutSubtreeIfNeeded()
        }
        // Commit the native resize before SwiftUI changes the inspector binding.
        // The calling view's task is cancelled if selection or its identity changes.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// Forward every other delegate method to SwiftUI, including sizing and full-screen behavior.
@MainActor private final class DashboardCloseDelegate: NSObject, NSWindowDelegate {
    weak var owner: DashboardWindowCoordinator?
    weak var original: (any NSWindowDelegate)?

    init(owner: DashboardWindowCoordinator, original: (any NSWindowDelegate)?) {
        self.owner = owner
        self.original = original
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        guard let owner else { return true }
        guard sender.attachedSheet == nil else { return false }
        owner.hide(sender)
        return false
    }
}

/// Attach only to the scene's actual content/toolbar. A toolbar layout is the
/// readiness signal for the first presentation, rather than an arbitrary delay.
struct DashboardWindowConnection: NSViewRepresentable {
    var coordinator: DashboardWindowCoordinator
    var toolbar = false

    func makeNSView(context: Context) -> ConnectionView {
        ConnectionView(coordinator: coordinator, toolbar: toolbar)
    }
    func updateNSView(_ view: ConnectionView, context: Context) { view.report() }

    final class ConnectionView: NSView {
        let coordinator: DashboardWindowCoordinator
        let toolbar: Bool
        init(coordinator: DashboardWindowCoordinator, toolbar: Bool) {
            self.coordinator = coordinator
            self.toolbar = toolbar
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        func report() {
            guard let window else { return }
            coordinator.attach(window)
            AppLaunchReceipt.record(window)
            if toolbar, bounds.width > 0, bounds.height > 0 { coordinator.toolbarDidLayout(in: window) }
        }
    }
}
