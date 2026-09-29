import AppKit

/// Keep the running application's Dock / application-switcher icon in step with macOS.
/// Drawing the shared vector paths also works in local builds without an asset compiler.
@MainActor
final class AppIconAppearance: NSObject {
    private var observation: NSKeyValueObservation?
    private var menuObservation: NSObjectProtocol?
    private var currentAppearance: BrandGeometry.Appearance?

    func start(application: NSApplication) {
        guard observation == nil else { return }
        update(application)
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            Task { @MainActor [weak self] in self?.update(application) }
        }
        // SwiftUI may recreate the standard AppKit app menu after launch.
        menuObservation = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configureAboutMenu(application.mainMenu) }
        }
        configureAboutMenu(application.mainMenu)
    }

    deinit {
        if let menuObservation { NotificationCenter.default.removeObserver(menuObservation) }
    }

    private func configureAboutMenu(_ menu: NSMenu?) {
        for item in menu?.items ?? [] {
            if item.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) {
                item.target = self
                item.action = #selector(showAboutPanel(_:))
            }
            configureAboutMenu(item.submenu)
        }
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        Self.showAbout(application: .shared)
    }

    private func update(_ application: NSApplication) {
        let appearance = Self.appearance(for: application)
        guard appearance != currentAppearance else { return }
        currentAppearance = appearance
        application.applicationIconImage = Self.image(for: appearance)
    }

    private static func appearance(for application: NSApplication) -> BrandGeometry.Appearance {
        application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    static func showAbout(application: NSApplication) {
        // The standard panel otherwise reads the bundle's static Finder fallback.
        application.orderFrontStandardAboutPanel(options: [
            .applicationIcon: image(for: appearance(for: application))
        ])
    }

    static func image(for appearance: BrandGeometry.Appearance) -> NSImage {
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            BrandGeometry.draw(in: bounds, context: context, appearance: appearance)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "LLM Usage"
        return image
    }
}
